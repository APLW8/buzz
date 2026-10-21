//! Redis cleanup includes shared artifact snapshots.
use super::*;

/// Shared eviction unit for bounded, short-lived artifact snapshots.
pub const ARTIFACT_SNAPSHOT_STORE: &str = "buzz:{artifact-snapshots-v1}:store";

/// Remove one community's snapshots and their quota charges atomically.
pub async fn purge_artifact_snapshots(
    pool: &deadpool_redis::Pool,
    community: buzz_core::CommunityId,
) -> Result<u64> {
    let mut connection = pool.get().await?;
    snapshot_namespace(&mut connection, community, true).await
}

async fn snapshot_namespace(
    connection: &mut deadpool_redis::Connection,
    community: buzz_core::CommunityId,
    remove: bool,
) -> Result<u64> {
    Ok(redis::Script::new(r#"
local stored = redis.call('HGET', KEYS[1], 'ids')
if not stored then return 0 end
local ids = cjson.decode(stored)
local retained, count = {}, 0
for _, id in ipairs(ids) do
    if string.sub(id, 1, string.len(ARGV[1])) == ARGV[1] then
        count = count + 1
        if ARGV[2] == '1' then
            local rows = cjson.decode(redis.call('HGET', KEYS[1], 'rows:' .. id) or '[]')
            for _, revision in ipairs(rows) do redis.call('HDEL', KEYS[1], 'body:' .. id .. ':' .. revision) end
            local size = tonumber(redis.call('HGET', KEYS[1], 'size:' .. id))
            redis.call('HINCRBY', KEYS[1], 'total', -size)
            redis.call('HDEL', KEYS[1], 'expiry:' .. id, 'size:' .. id, 'owner:' .. id,
                'data:' .. id, 'progress:' .. id, 'meta:' .. id, 'rows:' .. id)
        end
    else
        table.insert(retained, id)
    end
end
if ARGV[2] == '1' then redis.call('HSET', KEYS[1], 'ids', cjson.encode(retained)) end
return count
"#).key(ARTIFACT_SNAPSHOT_STORE)
        .arg(format!("buzz:{{artifact-snapshots-v1}}:{}:", community.as_uuid()))
        .arg(if remove { "1" } else { "0" })
        .invoke_async(&mut **connection).await?)
}

pub(super) async fn purge_redis_namespace(
    pool: &deadpool_redis::Pool,
    community: buzz_core::CommunityId,
) -> Result<u64> {
    let mut connection = pool.get().await?;
    let pattern = format!("buzz:{community}:*");
    let mut cursor = 0u64;
    let mut deleted = snapshot_namespace(&mut connection, community, true).await?;
    loop {
        let (next, keys): (u64, Vec<String>) = redis::cmd("SCAN")
            .arg(cursor)
            .arg("MATCH")
            .arg(&pattern)
            .arg("COUNT")
            .arg(1000)
            .query_async(&mut *connection)
            .await?;
        if !keys.is_empty() {
            let count: u64 = redis::cmd("UNLINK")
                .arg(&keys)
                .query_async(&mut *connection)
                .await?;
            deleted = deleted.saturating_add(count);
        }
        if next == 0 {
            break;
        }
        cursor = next;
    }
    Ok(deleted)
}

pub(super) fn scan_proves_absence(pages: &[(u64, Vec<String>)]) -> bool {
    pages.last().is_some_and(|(cursor, _)| *cursor == 0)
        && pages.iter().all(|(_, keys)| keys.is_empty())
}

async fn scan_redis_namespace(
    connection: &mut deadpool_redis::Connection,
    pattern: &str,
) -> Result<Vec<(u64, Vec<String>)>> {
    let mut cursor = 0u64;
    let mut pages = Vec::new();
    loop {
        let page: (u64, Vec<String>) = redis::cmd("SCAN")
            .arg(cursor)
            .arg("MATCH")
            .arg(pattern)
            .arg("COUNT")
            .arg(1000)
            .query_async(&mut **connection)
            .await?;
        cursor = page.0;
        pages.push(page);
        if cursor == 0 {
            return Ok(pages);
        }
    }
}

pub(super) async fn verify_redis_absence(
    pool: &deadpool_redis::Pool,
    community: buzz_core::CommunityId,
) -> Result<()> {
    let mut connection = pool.get().await?;
    let pattern = format!("buzz:{community}:*");
    // SCAN is weakly consistent. Two complete empty passes ensure a cursor
    // rollover or concurrent expiry cannot make one sparse pass look absent.
    let first = scan_redis_namespace(&mut connection, &pattern).await?;
    let second = scan_redis_namespace(&mut connection, &pattern).await?;
    let snapshots = snapshot_namespace(&mut connection, community, false).await?;
    if scan_proves_absence(&first) && scan_proves_absence(&second) && snapshots == 0 {
        Ok(())
    } else {
        Err(transient(
            "logical verification found a Redis namespace key",
        ))
    }
}

#[cfg(test)]
mod postgres_tests {
    use super::*;

    #[tokio::test]
    #[ignore = "requires Postgres"]
    async fn artifact_snapshot_community_purge_checks_shared_storage() {
        let pool = deadpool_redis::Config::from_url(
            std::env::var("REDIS_URL").unwrap_or_else(|_| "redis://127.0.0.1:6379".into()),
        )
        .create_pool(Some(deadpool_redis::Runtime::Tokio1))
        .unwrap();
        let community = buzz_core::CommunityId::from_uuid(Uuid::new_v4());
        let id = format!(
            "buzz:{{artifact-snapshots-v1}}:{}:fixture",
            community.as_uuid()
        );
        let mut conn = pool.get().await.unwrap();
        let _: i64 = redis::Script::new(
            r#"
local ids = cjson.decode(redis.call('HGET', KEYS[1], 'ids') or '[]')
table.insert(ids, ARGV[1])
redis.call('HSET', KEYS[1], 'ids', cjson.encode(ids), 'size:' .. ARGV[1], 10,
    'rows:' .. ARGV[1], '["revision"]', 'body:' .. ARGV[1] .. ':revision', 'body')
redis.call('HINCRBY', KEYS[1], 'total', 10)
return 1
"#,
        )
        .key(ARTIFACT_SNAPSHOT_STORE)
        .arg(&id)
        .invoke_async(&mut *conn)
        .await
        .unwrap();
        assert!(verify_redis_absence(&pool, community).await.is_err());
        assert_eq!(purge_redis_namespace(&pool, community).await.unwrap(), 1);
        verify_redis_absence(&pool, community).await.unwrap();
        let body: Option<String> = redis::cmd("HGET")
            .arg(ARTIFACT_SNAPSHOT_STORE)
            .arg(format!("body:{id}:revision"))
            .query_async(&mut *conn)
            .await
            .unwrap();
        assert_eq!(body, None);
    }
}
