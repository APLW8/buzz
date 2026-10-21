//! Short-lived shared artifact manifests for signed POST /query requests.
use crate::state::AppState;
use axum::{http::StatusCode, Json};
use buzz_core::{artifact::ArtifactView, TenantContext};
use buzz_db::artifact_snapshot::{BodyRecord, Manifest, MAX_BYTES, MAX_ROWS};
use deadpool_redis::redis;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{sync::Arc, time::Duration};
use uuid::Uuid;

const LIFETIME: u64 = 300;
const PAGE_ROWS: usize = 1000;
const PAGE_BYTES: usize = 262_144;
const BODY_ROWS: usize = 100;
const BODY_BYTES: usize = 8_388_608;
const GLOBAL_BYTES: usize = 64 * 1024 * 1024;
const GLOBAL_COUNT: usize = 32;
const STORE_KEY: &str = buzz_deletion::ARTIFACT_SNAPSHOT_STORE;
static WORK: tokio::sync::Semaphore = tokio::sync::Semaphore::const_new(4);
type Response = Result<Json<Value>, (StatusCode, Json<Value>)>;

#[derive(Deserialize)]
#[serde(tag = "action", deny_unknown_fields)]
enum Request {
    #[serde(rename = "start")]
    Start { artifact: String, query: Value },
    #[serde(rename = "page")]
    Page {
        artifact: String,
        token: String,
        cursor: String,
    },
    #[serde(rename = "bodies", rename_all = "camelCase")]
    Bodies {
        artifact: String,
        token: String,
        revision_ids: Vec<String>,
    },
    #[serde(rename = "complete")]
    Complete { artifact: String, token: String },
}
#[derive(Serialize, Deserialize)]
struct Snapshot {
    manifest: Manifest,
    // Retain the exact scope and generation with the captured identities.
    query: Value,
    generation: String,
    expires_at: u64,
    cursors: Vec<String>,
}

fn error(status: StatusCode, code: &str) -> (StatusCode, Json<Value>) {
    (status, Json(json!({"error":code,"code":code})))
}
fn reset() -> (StatusCode, Json<Value>) {
    error(StatusCode::CONFLICT, "snapshot_reset")
}
fn invalid() -> (StatusCode, Json<Value>) {
    error(StatusCode::BAD_REQUEST, "snapshot_invalid")
}
fn unavailable() -> (StatusCode, Json<Value>) {
    error(StatusCode::SERVICE_UNAVAILABLE, "snapshot_unavailable")
}
fn limit() -> (StatusCode, Json<Value>) {
    error(StatusCode::PAYLOAD_TOO_LARGE, "snapshot_limit")
}
fn db_error(
    e: buzz_db::DbError,
    tenant: &TenantContext,
    reader: &nostr::PublicKey,
) -> (StatusCode, Json<Value>) {
    match e {
        buzz_db::DbError::ArtifactSnapshotReset => reset(),
        buzz_db::DbError::ArtifactSnapshotLimit => limit(),
        buzz_db::DbError::ArtifactSnapshotUnsupportedScope => error(
            StatusCode::UNPROCESSABLE_ENTITY,
            "snapshot_unsupported_scope",
        ),
        error => {
            tracing::warn!(community = %tenant.community().as_uuid(), reader = %reader, %error, "artifact snapshot database operation failed");
            unavailable()
        }
    }
}

/// Resource contract advertised through NIP-11.
pub(crate) fn capability() -> Value {
    json!({"version":1,"maxRows":MAX_ROWS,"pageRows":PAGE_ROWS,"pageBytes":PAGE_BYTES,
        "bodyRows":BODY_ROWS,"bodyBytes":BODY_BYTES,"lifetimeSeconds":LIFETIME,"permanentChannelsOnly":true})
}

fn key(tenant: &TenantContext, reader: &nostr::PublicKey, token: &str) -> String {
    format!(
        "buzz:{{artifact-snapshots-v1}}:{}:{}:{}",
        tenant.community().as_uuid(),
        reader.to_hex(),
        token
    )
}
fn valid_token(token: &str) -> bool {
    token.len() == 32
        && token
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

fn page(snapshot: &Snapshot, token: &str, index: usize) -> Response {
    let start = index * PAGE_ROWS;
    let end = (start + PAGE_ROWS).min(snapshot.manifest.entries.len());
    let value = json!({"version":1,"token":token,"expiresAt":snapshot.expires_at,
        "entries":&snapshot.manifest.entries[start..end],"nextToken":snapshot.cursors.get(index)});
    if serde_json::to_vec(&value).map_err(|_| unavailable())?.len() > PAGE_BYTES {
        return Err(limit());
    }
    Ok(Json(value))
}

/// Run one snapshot operation with bounded concurrency and elapsed work.
pub(super) async fn query(
    state: &Arc<AppState>,
    tenant: &TenantContext,
    reader: &nostr::PublicKey,
    filter: &Value,
) -> Response {
    let _permit = WORK.try_acquire().map_err(|_| unavailable())?;
    tokio::time::timeout(
        Duration::from_secs(8),
        execute(state, tenant, reader, filter),
    )
    .await
    .map_err(|_| unavailable())?
}

async fn execute(
    state: &Arc<AppState>,
    tenant: &TenantContext,
    reader: &nostr::PublicKey,
    filter: &Value,
) -> Response {
    let request: Request = serde_json::from_value(filter.clone()).map_err(|_| invalid())?;
    let mut conn = state.redis_pool.get().await.map_err(|_| unavailable())?;
    let (now, _): (u64, u64) = redis::cmd("TIME")
        .query_async(&mut *conn)
        .await
        .map_err(|_| unavailable())?;
    if let Request::Start { artifact, query } = request {
        let serving_write = buzz_deletion::acquire_serving_write(
            &state.db,
            tenant.community(),
            "artifact_snapshot",
        )
        .await
        .map_err(|_| unavailable())?;
        if artifact != "snapshot" || query.get("limit").is_some() || query.get("offset").is_some() {
            return Err(invalid());
        }
        let parsed = buzz_core::artifact::parse_query(&query).map_err(|_| invalid())?;
        if parsed.view != ArtifactView::Current {
            return Err(invalid());
        }
        let manifest = state
            .db
            .capture_artifact_manifest(tenant.community(), reader.as_bytes(), &parsed)
            .await
            .map_err(|e| db_error(e, tenant, reader))?;
        let token = Uuid::new_v4().simple().to_string();
        let pages = manifest.entries.len().div_ceil(PAGE_ROWS).max(1);
        let expires_at = now + LIFETIME;
        let snapshot = Snapshot {
            manifest,
            query,
            generation: token.clone(),
            expires_at,
            cursors: (1..pages)
                .map(|_| Uuid::new_v4().simple().to_string())
                .collect(),
        };
        let data = serde_json::to_vec(&snapshot).map_err(|_| unavailable())?;
        if data.len() > MAX_BYTES {
            return Err(limit());
        }
        let response = page(&snapshot, &token, 0)?;
        let snapshot_key = key(tenant, reader, &token);
        let principal_key = key(tenant, reader, "active");
        let (metadata, records) = snapshot
            .manifest
            .body_records()
            .map_err(|e| db_error(e, tenant, reader))?;
        let metadata = serde_json::to_vec(&Snapshot {
            manifest: metadata,
            query: Value::Null,
            generation: token.clone(),
            expires_at,
            cursors: vec![],
        })
        .map_err(|_| unavailable())?;
        let rows = records
            .iter()
            .zip(&snapshot.manifest.entries)
            .map(|(record, entry)| {
                Ok((
                    entry.revision_id.clone(),
                    serde_json::to_string(record).map_err(|_| unavailable())?,
                ))
            })
            .collect::<Result<Vec<_>, _>>()?;
        let rows = serde_json::to_vec(&rows).map_err(|_| unavailable())?;
        // Charge duplicate records, field names, and Redis object overhead.
        let stored_bytes = data.len() + metadata.len() + rows.len() + records.len() * 512;
        let registration = async {
            redis::Script::new(REGISTER)
                .key(STORE_KEY)
                .arg(expires_at)
                .arg(stored_bytes)
                .arg(GLOBAL_BYTES)
                .arg(GLOBAL_COUNT)
                .arg(data)
                .arg(&snapshot_key)
                .arg(principal_key)
                .arg(metadata)
                .arg(rows)
                .invoke_async::<i64>(&mut *conn)
                .await
        };
        let stored = serving_write
            .protect(registration)
            .await
            .map_err(|_| unavailable())?
            .map_err(|_| unavailable())?;
        serving_write.finish().await.map_err(|_| unavailable())?;
        if stored == 0 {
            return Err(limit());
        }
        return Ok(response);
    }
    let (artifact, token) = match &request {
        Request::Page {
            artifact, token, ..
        }
        | Request::Bodies {
            artifact, token, ..
        }
        | Request::Complete { artifact, token } => (artifact, token),
        Request::Start { .. } => return Err(invalid()),
    };
    if artifact != "snapshot" || !valid_token(token) {
        return Err(invalid());
    }
    let snapshot_key = key(tenant, reader, token);
    let body_ids = match &request {
        Request::Bodies { revision_ids, .. } => {
            if revision_ids.is_empty() {
                return Err(invalid());
            }
            if revision_ids.len() > BODY_ROWS {
                return Err(limit());
            }
            let mut seen = std::collections::HashSet::new();
            if revision_ids
                .iter()
                .any(|id| buzz_core::artifact::event_id(id).is_err() || !seen.insert(id))
            {
                return Err(invalid());
            }
            Some(revision_ids)
        }
        _ => None,
    };
    let (data, body_rows) = if let Some(ids) = body_ids {
        let mut fields = vec![format!("meta:{snapshot_key}")];
        fields.extend(ids.iter().map(|id| format!("body:{snapshot_key}:{id}")));
        let mut rows: Vec<Option<Vec<u8>>> = redis::cmd("HMGET")
            .arg(STORE_KEY)
            .arg(fields)
            .query_async(&mut *conn)
            .await
            .map_err(|_| unavailable())?;
        let data = rows.remove(0);
        (data, rows)
    } else {
        let data: Option<Vec<u8>> = redis::cmd("HGET")
            .arg(STORE_KEY)
            .arg(format!("data:{snapshot_key}"))
            .query_async(&mut *conn)
            .await
            .map_err(|_| unavailable())?;
        (data, vec![])
    };
    let data = data.ok_or_else(reset)?;
    if data.len() > MAX_BYTES {
        return Err(unavailable());
    }
    let mut snapshot: Snapshot = serde_json::from_slice(&data).map_err(|_| unavailable())?;
    if snapshot.generation != *token || now >= snapshot.expires_at {
        return Err(reset());
    }
    if body_ids.is_some() {
        let records = body_rows
            .into_iter()
            .map(|row| {
                serde_json::from_slice::<BodyRecord>(&row.ok_or_else(invalid)?)
                    .map_err(|_| unavailable())
            })
            .collect::<Result<Vec<_>, _>>()?;
        snapshot.manifest = snapshot.manifest.with_body_records(records);
    }
    let requested = match &request {
        Request::Bodies { revision_ids, .. } => {
            if revision_ids.is_empty() {
                return Err(invalid());
            }
            if revision_ids.len() > BODY_ROWS {
                return Err(limit());
            }
            let mut seen = std::collections::HashSet::new();
            for id in revision_ids {
                if buzz_core::artifact::event_id(id).is_err()
                    || !seen.insert(id)
                    || !snapshot
                        .manifest
                        .entries
                        .iter()
                        .any(|e| &e.revision_id == id)
                {
                    return Err(invalid());
                }
            }
            revision_ids.as_slice()
        }
        _ => &[],
    };
    let events = state
        .db
        .read_artifact_manifest(
            tenant.community(),
            reader.as_bytes(),
            &snapshot.manifest,
            requested,
            BODY_BYTES,
        )
        .await
        .map_err(|e| db_error(e, tenant, reader))?;
    let pages = snapshot.cursors.len() + 1;
    match &request {
        Request::Page { cursor, .. } => {
            let index = snapshot
                .cursors
                .iter()
                .position(|c| c == cursor)
                .ok_or_else(invalid)?
                + 1;
            let result = page(&snapshot, token, index)?;
            let advanced: i64 = redis::Script::new(ADVANCE)
                .key(STORE_KEY)
                .arg(&snapshot_key)
                .arg(index)
                .arg(index + 1)
                .invoke_async(&mut *conn)
                .await
                .map_err(|_| unavailable())?;
            if advanced == -1 {
                return Err(reset());
            }
            if advanced == 0 {
                return Err(invalid());
            }
            Ok(result)
        }
        Request::Bodies { .. } => {
            if events.len() != requested.len() {
                return Err(reset());
            }
            let events = events.into_iter().map(|e| e.event).collect::<Vec<_>>();
            let result = json!({"version":1,"token":token,"events":events});
            if serde_json::to_vec(&result)
                .map_err(|_| unavailable())?
                .len()
                > BODY_BYTES
            {
                return Err(limit());
            }
            Ok(Json(result))
        }
        Request::Complete { .. } => {
            let valid: i64 = redis::Script::new(COMPLETE)
                .key(STORE_KEY)
                .arg(&snapshot_key)
                .arg(pages)
                .invoke_async(&mut *conn)
                .await
                .map_err(|_| unavailable())?;
            match valid {
                -1 => Err(reset()),
                1 => Ok(Json(json!({"version":1,"token":token,"complete":true}))),
                _ => Err(invalid()),
            }
        }
        Request::Start { .. } => Err(invalid()),
    }
}

// One hash keeps data and accounting in the same eviction unit.
const REGISTER: &str = r#"
local now = tonumber(redis.call('TIME')[1])
local count, principal, latest = 0, 0, tonumber(ARGV[1])
local ids = cjson.decode(redis.call('HGET', KEYS[1], 'ids') or '[]')
local retained = {}
for _, id in ipairs(ids) do
        local field = 'expiry:' .. id
        local expiry = tonumber(redis.call('HGET', KEYS[1], field))
        if expiry <= now then
            local size = tonumber(redis.call('HGET', KEYS[1], 'size:' .. id))
            redis.call('HINCRBY', KEYS[1], 'total', -size)
            local rows = cjson.decode(redis.call('HGET', KEYS[1], 'rows:' .. id) or '[]')
            for _, revision in ipairs(rows) do redis.call('HDEL', KEYS[1], 'body:' .. id .. ':' .. revision) end
            redis.call('HDEL', KEYS[1], field, 'size:' .. id, 'owner:' .. id, 'data:' .. id, 'progress:' .. id, 'meta:' .. id, 'rows:' .. id)
        else
            table.insert(retained, id)
            count = count + 1
            latest = math.max(latest, expiry)
            if redis.call('HGET', KEYS[1], 'owner:' .. id) == ARGV[7] then principal = principal + 1 end
        end
end
redis.call('HSET', KEYS[1], 'ids', cjson.encode(retained))
if tonumber(ARGV[1]) <= now or count >= tonumber(ARGV[4]) or principal >= 2
    or tonumber(redis.call('HGET', KEYS[1], 'total') or '0') + tonumber(ARGV[2]) > tonumber(ARGV[3]) then return 0 end
redis.call('HSET', KEYS[1], 'data:' .. ARGV[6], ARGV[5], 'progress:' .. ARGV[6], 1,
    'expiry:' .. ARGV[6], ARGV[1], 'size:' .. ARGV[6], ARGV[2], 'owner:' .. ARGV[6], ARGV[7])
local rows = cjson.decode(ARGV[9] or '[]')
local revisions = {}
for _, row in ipairs(rows) do
    redis.call('HSET', KEYS[1], 'body:' .. ARGV[6] .. ':' .. row[1], row[2])
    table.insert(revisions, row[1])
end
redis.call('HSET', KEYS[1], 'meta:' .. ARGV[6], ARGV[8] or '', 'rows:' .. ARGV[6], cjson.encode(revisions))
table.insert(retained, ARGV[6])
redis.call('HSET', KEYS[1], 'ids', cjson.encode(retained))
redis.call('HINCRBY', KEYS[1], 'total', ARGV[2])
redis.call('EXPIREAT', KEYS[1], latest)
return 1
"#;
const ADVANCE: &str = r#"
local expiry = tonumber(redis.call('HGET', KEYS[1], 'expiry:' .. ARGV[1]))
if not expiry or expiry <= tonumber(redis.call('TIME')[1]) then return -1 end
local progress = tonumber(redis.call('HGET', KEYS[1], 'progress:' .. ARGV[1]))
if tonumber(ARGV[2]) > progress then return 0 end
if tonumber(ARGV[3]) > progress then redis.call('HSET', KEYS[1], 'progress:' .. ARGV[1], ARGV[3]) end
return 1
"#;
const COMPLETE: &str = r#"
local expiry = tonumber(redis.call('HGET', KEYS[1], 'expiry:' .. ARGV[1]))
if not expiry or expiry <= tonumber(redis.call('TIME')[1]) then return -1 end
if tonumber(redis.call('HGET', KEYS[1], 'progress:' .. ARGV[1])) ~= tonumber(ARGV[2]) then return 0 end
return 1
"#;

#[cfg(test)]
#[path = "artifact_snapshot_postgres_tests.rs"]
mod postgres_tests;
