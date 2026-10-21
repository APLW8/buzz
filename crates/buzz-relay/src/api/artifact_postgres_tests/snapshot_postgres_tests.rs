//! Snapshot protocol journeys through the production HTTP router.
use super::*;
use axum::http::StatusCode;
use base64::Engine;
use deadpool_redis::redis;
use sha2::Digest;

#[tokio::test]
#[ignore = "requires Postgres"]
async fn artifact_snapshot_traverses_ten_thousand_tasks_with_archives_and_exact_bodies() {
    let _ = tracing_subscriber::fmt()
        .with_max_level(tracing::Level::WARN)
        .try_init();
    let f = Fixture::new().await;
    let started = std::time::Instant::now();
    let mut events = Vec::new();
    let homes = (0..10_050)
        .map(|n| if n == 0 { f.home } else { Uuid::new_v4() })
        .collect::<Vec<_>>();
    for chunk in homes[1..].chunks(500) {
        sqlx::query(
            "INSERT INTO channels(community_id,id,name,visibility,channel_type,created_by) \
            SELECT $1,id,id::text,'private','stream',$2 FROM unnest($3::uuid[]) id",
        )
        .bind(f.community.as_uuid())
        .bind(f.owner.public_key().as_bytes().as_slice())
        .bind(chunk)
        .execute(&f.pool)
        .await
        .unwrap();
        sqlx::query("INSERT INTO channel_members(community_id,channel_id,pubkey,role) SELECT $1,id,$2,'owner' FROM unnest($3::uuid[]) id")
            .bind(f.community.as_uuid()).bind(f.owner.public_key().as_bytes().as_slice()).bind(chunk)
            .execute(&f.pool).await.unwrap();
    }
    for (n, home) in homes.iter().enumerate() {
        let id = Uuid::new_v4();
        let mut event = f.revision_as(&f.owner, *home, id, "create", None);
        let content = json!({"status": if n >= 10_000 { "archived" } else { "open" }, "notes":"x".repeat(4400)}).to_string();
        event = EventBuilder::new(Kind::Custom(45010), content)
            .tags(event.tags.clone())
            .sign_with_keys(&f.owner)
            .unwrap();
        events.push(event);
    }
    // Bulk setup avoids measuring one HTTP write per task in the read journey.
    for chunk in events.chunks(500) {
        let values = chunk.iter().map(|event| json!({"id":event.id.to_hex(),"tags":event.tags,
            "content":event.content,"sig":event.sig.to_string(),"created_at":event.created_at.as_secs(),"channel_id":event.tags.iter().find(|t| t.as_slice()[0]=="h").unwrap().as_slice()[1]})).collect::<Vec<_>>();
        sqlx::query("INSERT INTO events(community_id,id,pubkey,created_at,kind,tags,content,sig,channel_id) \
            SELECT $1,decode(x.id,'hex'),$2,to_timestamp(x.created_at),45010,x.tags,x.content,decode(x.sig,'hex'),x.channel_id \
            FROM jsonb_to_recordset($3) x(id text,tags jsonb,content text,sig text,created_at bigint,channel_id uuid)")
            .bind(f.community.as_uuid()).bind(f.owner.public_key().as_bytes().as_slice())
            .bind(json!(values))
            .execute(&f.pool).await.unwrap();
    }
    sqlx::query("INSERT INTO artifact_heads(community_id,artifact_id,event_id,channel_id,artifact_type) \
        SELECT community_id,(tags->1->>1)::uuid,id,channel_id,'buzz.task' FROM events WHERE community_id=$1 AND kind=45010")
        .bind(f.community.as_uuid()).execute(&f.pool).await.unwrap();
    sqlx::query("INSERT INTO artifact_revisions(community_id,event_id,artifact_id) SELECT community_id,event_id,artifact_id FROM artifact_heads WHERE community_id=$1")
        .bind(f.community.as_uuid()).execute(&f.pool).await.unwrap();
    let (status, first) = f
        .request(
            "/query",
            json!([{"artifact":"snapshot","action":"start",
        "query":{"artifact":"current","#type":["buzz.task"]}}]),
        )
        .await;
    assert!(status.is_success(), "{status}: {first}");
    let token = first["token"].as_str().unwrap();
    assert_eq!(first["entries"].as_array().unwrap().len(), 1000);
    let (status, result) = f
        .request(
            "/query",
            json!([{"artifact":"snapshot","action":"complete","token":token}]),
        )
        .await;
    assert_eq!(status, StatusCode::BAD_REQUEST, "{result}");
    let (status, result) = f
        .request_as(
            &f.peer,
            "/query",
            json!([{"artifact":"snapshot","action":"complete","token":token}]),
        )
        .await;
    assert_eq!(status, StatusCode::CONFLICT, "{result}");
    assert_eq!(result["code"], "snapshot_reset");

    let mut conn = f.state.redis_pool.get().await.unwrap();
    let snapshot_key = format!(
        "buzz:{{artifact-snapshots-v1}}:{}:{}:{}",
        f.community.as_uuid(),
        f.owner.public_key().to_hex(),
        token
    );
    let internal: Vec<u8> = redis::cmd("HGET")
        .arg("buzz:{artifact-snapshots-v1}:store")
        .arg(format!("data:{snapshot_key}"))
        .query_async(&mut *conn)
        .await
        .unwrap();
    let internal: Value = serde_json::from_slice(&internal).unwrap();
    let (status, result) = f.request("/query", json!([{"artifact":"snapshot","action":"page","token":token,"cursor":internal["cursors"][2]}])).await;
    assert_eq!(status, StatusCode::BAD_REQUEST, "{result}");
    drop(conn);
    let fresh = f.revision(Uuid::new_v4(), "create", None);
    f.publish(&fresh).await;
    let updated = f.revision(
        events[0]
            .tags
            .iter()
            .find(|t| t.as_slice()[0] == "d")
            .unwrap()
            .as_slice()[1]
            .parse()
            .unwrap(),
        "update",
        Some(&events[0]),
    );
    f.publish(&updated).await;
    let mut entries = first["entries"].as_array().unwrap().clone();
    let mut next = first["nextToken"].clone();
    while let Some(cursor) = next.as_str() {
        let request =
            json!([{"artifact":"snapshot","action":"page","token":token,"cursor":cursor}]);
        let (status, result) = f.request("/query", request.clone()).await;
        assert!(status.is_success(), "{status}: {result}");
        let (status, retry) = f.request("/query", request).await;
        assert!(status.is_success(), "{status}: {retry}");
        assert_eq!(result, retry);
        assert!(serde_json::to_vec(&result).unwrap().len() <= 262_144);
        entries.extend(result["entries"].as_array().unwrap().clone());
        next = result["nextToken"].clone();
    }
    assert_eq!(entries.len(), 10_050);
    let identities = entries
        .iter()
        .map(|e| e["artifactId"].as_str().unwrap())
        .collect::<std::collections::HashSet<_>>();
    assert_eq!(identities.len(), entries.len());
    assert!(!entries.iter().any(|e| e["revisionId"] == fresh.id.to_hex()));
    assert!(entries
        .iter()
        .any(|e| e["revisionId"] == events[0].id.to_hex()));
    // A second relay state serves real signed HTTP requests with the same
    // shared manifest. It holds no local copy of the capture.
    let mut other = bridge_handler_test_state().await.unwrap();
    Arc::make_mut(&mut Arc::get_mut(&mut other).unwrap().config).require_auth_token = true;
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}/query", listener.local_addr().unwrap());
    let router = crate::router::build_router(other);
    let server = tokio::spawn(async move { axum::serve(listener, router).await.unwrap() });
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(10))
        .build()
        .unwrap();
    let mut body_count = 0;
    for chunk in entries.chunks(100) {
        let ids = chunk
            .iter()
            .map(|e| e["revisionId"].clone())
            .collect::<Vec<_>>();
        let (status, result) = signed_query(
            &f,
            &client,
            &url,
            json!([{"artifact":"snapshot","action":"bodies","token":token,"revisionIds":ids}]),
        )
        .await;
        assert!(status.is_success(), "{status}: {result}");
        assert_eq!(result["events"].as_array().unwrap().len(), chunk.len());
        for value in result["events"].as_array().unwrap() {
            let event: Event = serde_json::from_value(value.clone()).unwrap();
            event.verify().unwrap();
        }
        body_count += chunk.len();
    }
    assert_eq!(body_count, 10_050);
    let (status, complete) = signed_query(
        &f,
        &client,
        &url,
        json!([{"artifact":"snapshot","action":"complete","token":token}]),
    )
    .await;
    server.abort();
    assert!(status.is_success(), "{status}: {complete}");
    assert_eq!(complete, json!({"version":1,"token":token,"complete":true}));
    assert!(started.elapsed().as_secs() < 300);
    eprintln!(
        "10,050 records, {} bytes per typical signed event, 101 body batches and completion: {:?}",
        serde_json::to_vec(&events[0]).unwrap().len(),
        started.elapsed()
    );

    let (status, result) = f.request("/query", json!([{"artifact":"snapshot","action":"bodies","token":token,"revisionIds":[fresh.id.to_hex()]}])).await;
    assert_eq!(status, StatusCode::BAD_REQUEST, "{result}");
    sqlx::query("UPDATE channel_members SET removed_at=now() WHERE community_id=$1 AND channel_id=$2 AND pubkey=$3")
        .bind(f.community.as_uuid()).bind(homes[1]).bind(f.owner.public_key().as_bytes().as_slice()).execute(&f.pool).await.unwrap();
    let (status, result) = f.request("/query", json!([{"artifact":"snapshot","action":"page","token":token,"cursor":first["nextToken"]}])).await;
    assert_eq!(status, StatusCode::CONFLICT, "{result}");
    assert!(result.get("entries").is_none());
    let mut conn = f.state.redis_pool.get().await.unwrap();
    let key = format!(
        "buzz:{{artifact-snapshots-v1}}:{}:{}:{}",
        f.community.as_uuid(),
        f.owner.public_key().to_hex(),
        token
    );
    let _: i64 = redis::cmd("HDEL")
        .arg("buzz:{artifact-snapshots-v1}:store")
        .arg(format!("data:{key}"))
        .query_async(&mut *conn)
        .await
        .unwrap();
    let (status, result) = f
        .request(
            "/query",
            json!([{"artifact":"snapshot","action":"complete","token":token}]),
        )
        .await;
    assert_eq!(status, StatusCode::CONFLICT, "{result}");
    assert_eq!(result["code"], "snapshot_reset");
    cleanup(&f).await;
}

async fn signed_query(
    f: &Fixture,
    client: &reqwest::Client,
    url: &str,
    body: Value,
) -> (StatusCode, Value) {
    let bytes = serde_json::to_vec(&body).unwrap();
    let auth = EventBuilder::new(Kind::Custom(27235), "")
        .tags([
            Tag::parse(["u", &format!("https://{}/query", f.host)]).unwrap(),
            Tag::parse(["method", "POST"]).unwrap(),
            Tag::parse(["payload", &hex::encode(sha2::Sha256::digest(&bytes))]).unwrap(),
            Tag::parse(["nonce", &Uuid::new_v4().to_string()]).unwrap(),
        ])
        .sign_with_keys(&f.owner)
        .unwrap();
    let authorization = format!(
        "Nostr {}",
        base64::engine::general_purpose::STANDARD.encode(serde_json::to_vec(&auth).unwrap())
    );
    let response = client
        .post(url)
        .header("host", &f.host)
        .header("content-type", "application/json")
        .header("authorization", authorization)
        .body(bytes)
        .send()
        .await
        .unwrap();
    let status = StatusCode::from_u16(response.status().as_u16()).unwrap();
    let body = serde_json::from_slice(&response.bytes().await.unwrap()).unwrap();
    (status, body)
}

#[tokio::test]
#[ignore = "requires Postgres"]
async fn artifact_snapshot_rechecks_access_and_exact_query_scope() {
    for scenario in ["revoke", "regrant", "recreate", "redact", "predicate"] {
        let f = Fixture::new().await;
        let id = Uuid::new_v4();
        let event = f.revision_as(&f.owner, f.private, id, "create", None);
        f.publish(&event).await;
        let (status, capture) = f
            .request(
                "/query",
                json!([{"artifact":"snapshot","action":"start",
            "query":{"artifact":"current","#title":["Review task"]}}]),
            )
            .await;
        assert!(status.is_success(), "{scenario}: {capture}");
        let token = capture["token"].as_str().unwrap();
        match scenario {
            "revoke" | "regrant" => {
                sqlx::query("UPDATE channel_members SET removed_at=now() WHERE community_id=$1 AND channel_id=$2 AND pubkey=$3")
                    .bind(f.community.as_uuid()).bind(f.private).bind(f.owner.public_key().as_bytes().as_slice()).execute(&f.pool).await.unwrap();
                if scenario == "regrant" {
                    sqlx::query("UPDATE channel_members SET removed_at=NULL WHERE community_id=$1 AND channel_id=$2 AND pubkey=$3")
                        .bind(f.community.as_uuid()).bind(f.private).bind(f.owner.public_key().as_bytes().as_slice()).execute(&f.pool).await.unwrap();
                }
            }
            "recreate" => {
                sqlx::query("DELETE FROM channel_members WHERE community_id=$1 AND channel_id=$2 AND pubkey=$3")
                    .bind(f.community.as_uuid()).bind(f.private).bind(f.owner.public_key().as_bytes().as_slice()).execute(&f.pool).await.unwrap();
                sqlx::query("INSERT INTO channel_members(community_id,channel_id,pubkey,role) VALUES($1,$2,$3,'owner')")
                    .bind(f.community.as_uuid()).bind(f.private).bind(f.owner.public_key().as_bytes().as_slice()).execute(&f.pool).await.unwrap();
            }
            "redact" => {
                sqlx::query("UPDATE events SET deleted_at=now() WHERE community_id=$1 AND id=$2")
                    .bind(f.community.as_uuid())
                    .bind(event.id.as_bytes().as_slice())
                    .execute(&f.pool)
                    .await
                    .unwrap();
            }
            "predicate" => {
                let update = f.revision_as(&f.owner, f.private, id, "update", Some(&event));
                let tags = update
                    .tags
                    .iter()
                    .map(|tag| {
                        if tag.as_slice()[0] == "title" {
                            Tag::parse(["title", "Changed task"]).unwrap()
                        } else {
                            tag.clone()
                        }
                    })
                    .collect::<Vec<_>>();
                let update = EventBuilder::new(Kind::Custom(45010), &update.content)
                    .tags(tags)
                    .sign_with_keys(&f.owner)
                    .unwrap();
                f.publish(&update).await;
            }
            _ => unreachable!(),
        }
        for action in ["bodies", "complete"] {
            let mut filter = json!({"artifact":"snapshot","action":action,"token":token});
            if action == "bodies" {
                filter["revisionIds"] = json!([event.id.to_hex()]);
            }
            let (status, result) = f.request("/query", json!([filter])).await;
            if scenario == "predicate" && action == "bodies" {
                assert!(status.is_success(), "{scenario}: {result}");
                assert_eq!(result["events"][0]["id"], event.id.to_hex());
            } else {
                assert_eq!(status, StatusCode::CONFLICT, "{scenario}: {result}");
                assert_eq!(result["code"], "snapshot_reset");
                assert!(result.get("events").is_none());
            }
        }
        cleanup(&f).await;
    }
    let f = Fixture::new().await;
    let public = f.revision(Uuid::new_v4(), "create", None);
    let private = f.revision_as(&f.owner, f.private, Uuid::new_v4(), "create", None);
    f.publish(&public).await;
    f.publish(&private).await;
    let (_, capture) = f
        .request_as(
            &f.peer,
            "/query",
            json!([{"artifact":"snapshot","action":"start",
        "query":{"artifact":"current","#type":["buzz.task"]}}]),
        )
        .await;
    assert_eq!(capture["entries"].as_array().unwrap().len(), 1);
    sqlx::query("INSERT INTO channel_members(community_id,channel_id,pubkey,role) VALUES($1,$2,$3,'member')")
        .bind(f.community.as_uuid()).bind(f.private).bind(f.peer.public_key().as_bytes().as_slice()).execute(&f.pool).await.unwrap();
    let (status, result) = f
        .request_as(
            &f.peer,
            "/query",
            json!([{"artifact":"snapshot","action":"complete","token":capture["token"]}]),
        )
        .await;
    assert_eq!(status, StatusCode::CONFLICT, "{result}");
    let (_, owner_capture) = f
        .request(
            "/query",
            json!([{"artifact":"snapshot","action":"start",
        "query":{"artifact":"current","#type":["buzz.task"]}}]),
        )
        .await;
    sqlx::query("UPDATE channel_members SET removed_at=now() WHERE community_id=$1 AND channel_id=$2 AND pubkey=$3")
        .bind(f.community.as_uuid()).bind(f.private).bind(f.owner.public_key().as_bytes().as_slice()).execute(&f.pool).await.unwrap();
    let (status, result) = f
        .request(
            "/query",
            json!([{"artifact":"snapshot","action":"bodies",
        "token":owner_capture["token"],"revisionIds":[public.id.to_hex()]}]),
        )
        .await;
    assert!(status.is_success(), "{result}");
    let (status, result) = f
        .request(
            "/query",
            json!([{"artifact":"snapshot","action":"complete","token":owner_capture["token"]}]),
        )
        .await;
    assert_eq!(status, StatusCode::CONFLICT, "{result}");
    cleanup(&f).await;
}

#[tokio::test]
#[ignore = "requires Postgres"]
async fn artifact_snapshot_rejects_matching_ttl_and_accepts_permanent_channel_defaults() {
    let f = Fixture::new().await;
    let home = Uuid::new_v4();
    let create = EventBuilder::new(Kind::Custom(9007), "")
        .tags([
            Tag::parse(["h", &home.to_string()]).unwrap(),
            Tag::parse(["name", "Permanent task"]).unwrap(),
            Tag::parse(["visibility", "private"]).unwrap(),
        ])
        .sign_with_keys(&f.owner)
        .unwrap();
    f.publish(&create).await;
    let ttl: Option<i32> =
        sqlx::query_scalar("SELECT ttl_seconds FROM channels WHERE community_id=$1 AND id=$2")
            .bind(f.community.as_uuid())
            .bind(home)
            .fetch_one(&f.pool)
            .await
            .unwrap();
    assert_eq!(ttl, None);
    let event = f.revision_as(&f.owner, home, Uuid::new_v4(), "create", None);
    f.publish(&event).await;
    sqlx::query("UPDATE channels SET ttl_seconds=60 WHERE community_id=$1 AND id=$2")
        .bind(f.community.as_uuid())
        .bind(f.private)
        .execute(&f.pool)
        .await
        .unwrap();
    let (_, permanent) = f
        .request(
            "/query",
            json!([{"artifact":"snapshot","action":"start",
        "query":{"artifact":"current","#type":["buzz.task"]}}]),
        )
        .await;
    assert_eq!(permanent["entries"].as_array().unwrap().len(), 1);
    let (_, empty) = f
        .request(
            "/query",
            json!([{"artifact":"snapshot","action":"start",
        "query":{"artifact":"current","#type":["buzz.absent"]}}]),
        )
        .await;
    assert_eq!(empty["entries"], json!([]));
    let event = f.revision_as(&f.owner, f.private, Uuid::new_v4(), "create", None);
    f.publish(&event).await;
    let (status, result) = f
        .request(
            "/query",
            json!([{"artifact":"snapshot","action":"start",
        "query":{"artifact":"current","#type":["buzz.task"]}}]),
        )
        .await;
    assert_eq!(status, StatusCode::UNPROCESSABLE_ENTITY, "{result}");
    assert_eq!(result["code"], "snapshot_unsupported_scope");
    assert!(result.get("token").is_none());
    let (status, result) = f
        .request(
            "/query",
            json!([{"artifact":"snapshot","action":"complete","token":permanent["token"]}]),
        )
        .await;
    assert_eq!(status, StatusCode::CONFLICT, "{result}");
    cleanup(&f).await;
}

#[tokio::test]
#[ignore = "requires Postgres"]
async fn artifact_snapshot_limits_lock_wait_and_keeps_the_capture_retryable() {
    let f = Fixture::new().await;
    f.publish(&f.revision(Uuid::new_v4(), "create", None)).await;
    let (_, capture) = f
        .request(
            "/query",
            json!([{"artifact":"snapshot","action":"start",
        "query":{"artifact":"current"}}]),
        )
        .await;
    let mut lock = f.pool.begin().await.unwrap();
    sqlx::query("LOCK TABLE events IN ACCESS EXCLUSIVE MODE")
        .execute(&mut *lock)
        .await
        .unwrap();
    let started = std::time::Instant::now();
    let (status, result) = f
        .request(
            "/query",
            json!([{"artifact":"snapshot","action":"complete","token":capture["token"]}]),
        )
        .await;
    assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE, "{result}");
    assert!(started.elapsed().as_secs() < 8);
    lock.rollback().await.unwrap();
    let (status, result) = f
        .request(
            "/query",
            json!([{"artifact":"snapshot","action":"complete","token":capture["token"]}]),
        )
        .await;
    assert!(status.is_success(), "{result}");
    cleanup(&f).await;
}

#[tokio::test]
#[ignore = "requires Postgres"]
async fn artifact_snapshot_tokens_expiry_and_allocation_are_bounded() {
    let f = Fixture::new().await;
    f.publish(&f.revision(Uuid::new_v4(), "create", None)).await;
    let start = json!([{"artifact":"snapshot","action":"start","query":{"artifact":"current"}}]);
    let (_, first) = f.request("/query", start.clone()).await;
    let (status, second) = f.request("/query", start.clone()).await;
    assert!(status.is_success(), "{second}");
    let (status, result) = f.request("/query", start.clone()).await;
    assert_eq!(status, StatusCode::PAYLOAD_TOO_LARGE, "{result}");
    let other = Fixture::new().await;
    let (status, result) = other
        .request_as(
            &f.owner,
            "/query",
            json!([{"artifact":"snapshot","action":"complete","token":first["token"]}]),
        )
        .await;
    assert_eq!(status, StatusCode::CONFLICT, "{result}");
    let (status, result) = f.request("/query", json!([{"artifact":"snapshot","action":"page","token":first["token"],"cursor":"a".repeat(32),"query":{"artifact":"current"}}])).await;
    assert_eq!(status, StatusCode::BAD_REQUEST, "{result}");
    let token = first["token"].as_str().unwrap();
    let key = format!(
        "buzz:{{artifact-snapshots-v1}}:{}:{}:{}",
        f.community.as_uuid(),
        f.owner.public_key().to_hex(),
        token
    );
    let mut conn = f.state.redis_pool.get().await.unwrap();
    let data: Vec<u8> = redis::cmd("HGET")
        .arg("buzz:{artifact-snapshots-v1}:store")
        .arg(format!("data:{key}"))
        .query_async(&mut *conn)
        .await
        .unwrap();
    let mut data: Value = serde_json::from_slice(&data).unwrap();
    data["expires_at"] = json!(0);
    let _: i64 = redis::cmd("HSET")
        .arg("buzz:{artifact-snapshots-v1}:store")
        .arg(format!("data:{key}"))
        .arg(serde_json::to_vec(&data).unwrap())
        .arg(format!("expiry:{key}"))
        .arg(0)
        .query_async(&mut *conn)
        .await
        .unwrap();
    let (status, result) = f
        .request(
            "/query",
            json!([{"artifact":"snapshot","action":"complete","token":token}]),
        )
        .await;
    assert_eq!(status, StatusCode::CONFLICT, "{result}");
    let (status, result) = f.request("/query", start).await;
    assert!(status.is_success(), "{result}");
    cleanup(&f).await;
    f.state.redis_pool.close();
    let (status, result) = f
        .request(
            "/query",
            json!([{"artifact":"snapshot","action":"complete","token":second["token"]}]),
        )
        .await;
    assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE, "{result}");
}

async fn cleanup(f: &Fixture) {
    let mut conn = f.state.redis_pool.get().await.unwrap();
    let prefix = format!("buzz:{{artifact-snapshots-v1}}:{}:", f.community.as_uuid());
    let _: i64 = redis::Script::new(r#"
        for _, field in ipairs(redis.call('HKEYS', KEYS[1])) do
            if string.sub(field,1,7) == 'expiry:' then
                local id = string.sub(field,8)
                if string.sub(id,1,string.len(ARGV[1])) == ARGV[1] then
                    local size = tonumber(redis.call('HGET',KEYS[1],'size:' .. id))
                    redis.call('HINCRBY',KEYS[1],'total',-size)
                    redis.call('HDEL',KEYS[1],field,'size:' .. id,'owner:' .. id,'data:' .. id,'progress:' .. id)
                end
            end
        end
        return 1
    "#).key("buzz:{artifact-snapshots-v1}:store").arg(prefix).invoke_async(&mut *conn).await.unwrap();
}

#[tokio::test]
#[ignore = "requires Postgres"]
async fn artifact_snapshot_new_matching_home_resets_then_a_fresh_capture_completes() {
    let f = Fixture::new().await;
    f.publish(&f.revision(Uuid::new_v4(), "create", None)).await;
    let start = json!([{"artifact":"snapshot","action":"start","query":{"artifact":"current","#type":["buzz.task"]}}]);
    let (_, capture) = f.request("/query", start.clone()).await;
    let home = Uuid::new_v4();
    let create = EventBuilder::new(Kind::Custom(9007), "")
        .tags([
            Tag::parse(["h", &home.to_string()]).unwrap(),
            Tag::parse(["name", "New task"]).unwrap(),
            Tag::parse(["visibility", "private"]).unwrap(),
        ])
        .sign_with_keys(&f.owner)
        .unwrap();
    f.publish(&create).await;
    f.publish(&f.revision_as(&f.owner, home, Uuid::new_v4(), "create", None))
        .await;
    let (status, result) = f
        .request(
            "/query",
            json!([{"artifact":"snapshot","action":"complete","token":capture["token"]}]),
        )
        .await;
    assert_eq!(status, StatusCode::CONFLICT, "{result}");
    let (status, fresh) = f.request("/query", start).await;
    assert!(status.is_success(), "{fresh}");
    assert_eq!(fresh["entries"].as_array().unwrap().len(), 2);
    let (status, result) = f
        .request(
            "/query",
            json!([{"artifact":"snapshot","action":"complete","token":fresh["token"]}]),
        )
        .await;
    assert!(status.is_success(), "{result}");
    cleanup(&f).await;
}
