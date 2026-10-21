//! Atomic quotas and cleanup use the production Redis scripts.
use super::*;

#[tokio::test]
#[ignore = "requires Postgres"]
async fn artifact_snapshot_shared_byte_and_count_quotas_survive_cleanup() {
    let url = std::env::var("REDIS_URL").unwrap_or_else(|_| "redis://127.0.0.1:6379".into());
    let pool = deadpool_redis::Config::from_url(url)
        .create_pool(Some(deadpool_redis::Runtime::Tokio1))
        .unwrap();
    let mut conn = pool.get().await.unwrap();
    let store = format!("buzz:{{artifact-snapshots-v1}}:test:{}", Uuid::new_v4());
    let (now, _): (u64, u64) = redis::cmd("TIME").query_async(&mut *conn).await.unwrap();
    for (id, owner, data, expected) in [
        ("a", "one", "123456", 1),
        ("b", "two", "12345", 0),
        ("b", "two", "1234", 1),
        ("c", "three", "1", 0),
    ] {
        let result: i64 = redis::Script::new(REGISTER)
            .key(&store)
            .arg(now + 300)
            .arg(data.len())
            .arg(10)
            .arg(2)
            .arg(data)
            .arg(id)
            .arg(owner)
            .invoke_async(&mut *conn)
            .await
            .unwrap();
        assert_eq!(result, expected);
    }
    let _: i64 = redis::cmd("HSET")
        .arg(&store)
        .arg("expiry:a")
        .arg(0)
        .query_async(&mut *conn)
        .await
        .unwrap();
    let result: i64 = redis::Script::new(REGISTER)
        .key(&store)
        .arg(now + 300)
        .arg(6)
        .arg(10)
        .arg(2)
        .arg("123456")
        .arg("c")
        .arg("three")
        .invoke_async(&mut *conn)
        .await
        .unwrap();
    assert_eq!(result, 1);
    let bytes: usize = redis::cmd("HGET")
        .arg(&store)
        .arg("total")
        .query_async(&mut *conn)
        .await
        .unwrap();
    assert_eq!(bytes, 10);
    let removed: Option<String> = redis::cmd("HGET")
        .arg(&store)
        .arg("data:a")
        .query_async(&mut *conn)
        .await
        .unwrap();
    assert_eq!(removed, None);
    let _: i64 = redis::cmd("DEL")
        .arg(store)
        .query_async(&mut *conn)
        .await
        .unwrap();
}
