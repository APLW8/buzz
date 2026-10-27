use super::*;
use crate::user::summary::summarize_request;
use buzz_db::entity_deletion::{inventory_digest, NewEntityStage, NextStage, StageTransition};
use buzz_db::Db;
use buzz_media::{MediaConfig, MediaStorage, S3AddressingStyle};
use sqlx::PgPool;
use std::sync::Arc;
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use uuid::Uuid;

struct Fixture {
    db: Db,
    store: EntityDeletionStore,
    lease: EntityLease,
    row: EntityStage,
    community: CommunityId,
}

async fn fixture() -> Fixture {
    let url = std::env::var("BUZZ_TEST_DATABASE_URL")
        .or_else(|_| std::env::var("DATABASE_URL"))
        .unwrap();
    let db = Db::from_pool(PgPool::connect(&url).await.unwrap());
    let community = db
        .ensure_configured_community("owned.example")
        .await
        .unwrap()
        .id;
    let store = db.entity_deletion_store();
    // Owned intake/routing intentionally remain disabled. Seed that future
    // approved input, then use the real claim, stage and handler operations.
    let target = "11".repeat(32);
    let item = json!({"community_id": community.as_uuid(), "relationship": "owner", "label": "owned.example"});
    let inventory = json!({"communities": [item, {
        "community_id": Uuid::new_v4(), "relationship": "participant", "label": "not-reached"
    }]});
    let digest = inventory_digest(&inventory).unwrap();
    let id: Uuid = sqlx::query_scalar(
        "INSERT INTO entity_deletion_requests (target, requested_by, status, inventory_manifest, inventory_digest)
         VALUES ($1, 'submitter', 'inventoried', $2, $3) RETURNING id",
    ).bind(&target).bind(&inventory).bind(&digest).fetch_one(db.pool()).await.unwrap();
    store.approve(id, "approver", &digest).await.unwrap();
    let lease = store
        .claim(id, "worker", Duration::from_secs(60))
        .await
        .unwrap()
        .unwrap();
    let next = store
        .transition_stage(&lease, None, |_, _| {
            Ok(StageTransition::Initialize(NewEntityStage {
                stage: "delete_owned_community".into(),
                community: Some(*community.as_uuid()),
                inputs: json!({"target": target, "community": item}),
            }))
        })
        .await
        .unwrap();
    let NextStage::Stage(row) = next else {
        panic!("expected stage")
    };
    Fixture {
        db,
        store,
        lease,
        row,
        community,
    }
}

fn media(endpoint: String) -> Arc<MediaStorage> {
    Arc::new(
        MediaStorage::new(&MediaConfig {
            s3_endpoint: endpoint,
            s3_access_key: "test".into(),
            s3_secret_key: "test".into(),
            s3_bucket: "test".into(),
            s3_region: "us-east-1".into(),
            s3_addressing_style: S3AddressingStyle::Path,
            max_image_bytes: 1,
            max_gif_bytes: 1,
            max_video_bytes: 1,
            max_file_bytes: 1,
            public_base_url: "http://localhost/media".into(),
            upload_records_enabled: false,
            upload_ip_header: None,
            upload_port_header: None,
        })
        .unwrap(),
    )
}

fn lookup_only_api(f: &Fixture) -> CommunityDeletionApi {
    // Any accidental attempt to inventory an existing child fails immediately.
    CommunityDeletionApi::new(f.db.deletion_store(), media("http://127.0.0.1:1".into()))
}

async fn submission_api(f: &Fixture) -> (CommunityDeletionApi, tokio::task::JoinHandle<()>) {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let endpoint = format!("http://{}", listener.local_addr().unwrap());
    let server = tokio::spawn(async move {
        // Exercise the real S3 adapter and inventory builder, with one empty
        // version listing per tenant prefix. No external storage is needed.
        for _ in 0..3 {
            let (mut socket, _) = tokio::time::timeout(Duration::from_secs(10), listener.accept())
                .await
                .unwrap()
                .unwrap();
            let mut headers = [0; 8192];
            let size = tokio::time::timeout(Duration::from_secs(10), socket.read(&mut headers))
                .await
                .unwrap()
                .unwrap();
            assert!(std::str::from_utf8(&headers[..size])
                .unwrap()
                .starts_with("GET "));
            let body = "<ListVersionsResult><Name>test</Name><IsTruncated>false</IsTruncated></ListVersionsResult>";
            let response = format!("HTTP/1.1 200 OK\r\nContent-Type: application/xml\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len());
            socket.write_all(response.as_bytes()).await.unwrap();
        }
    });
    (
        CommunityDeletionApi::new(f.db.deletion_store(), media(endpoint)),
        server,
    )
}

async fn child(f: &Fixture) -> DeletionRequest {
    f.db.deletion_store()
        .find_for_community(f.community)
        .await
        .unwrap()
        .unwrap()
}

#[tokio::test]
#[ignore = "requires Postgres"]
async fn submit_wait_approve_observe_and_complete_without_advancing_parent() {
    let f = fixture().await;
    let (api, server) = submission_api(&f).await;
    assert_eq!(
        handle(&f.store, &f.lease, &f.row, &api).await.unwrap(),
        OwnedCommunityOutcome::Waiting
    );
    server.await.unwrap();
    let c = child(&f).await;
    assert_eq!(c.stage, DeletionStage::Inventoried);
    assert_eq!(c.requested_by, "submitter");
    let summary = summarize_request(&f.store, f.row.request_id).await.unwrap();
    let wait = &summary.unfinished_stages[0];
    assert_eq!(wait.state, "waiting_external");
    let observation = wait.external_observation.as_ref().unwrap();
    assert_eq!(observation["child_request_id"], c.id.to_string());
    assert_eq!(observation["reason"], "approval_required");
    assert!(observation["observed_at"].is_string());
    assert!(observation["commands"].as_array().unwrap().len() >= 2);
    assert!(!summary.complete);
    assert_eq!(summary.communities_not_reached.len(), 1);
    assert_eq!(summary.saved.execution.retry_count, 0);
    assert_eq!(summary.saved.request.status, "running");
    assert_eq!(summary.saved.stage_history.len(), 1);
    assert!(f
        .db
        .deletion_store()
        .inspect(c.id)
        .await
        .unwrap()
        .approval
        .is_none());
    let api = lookup_only_api(&f);
    assert_eq!(
        handle(&f.store, &f.lease, &f.row, &api).await.unwrap(),
        OwnedCommunityOutcome::Waiting
    );
    assert_eq!(child(&f).await, c); // Read-only repeat: no child writes.
    f.db.deletion_store()
        .approve(c.id, "community-approver", None)
        .await
        .unwrap();
    // Summary never refreshes child state, even though the DB now says approved.
    let summary = summarize_request(&f.store, f.row.request_id).await.unwrap();
    assert_eq!(
        summary.unfinished_stages[0]
            .external_observation
            .as_ref()
            .unwrap()["child_stage"],
        "inventoried"
    );
    handle(&f.store, &f.lease, &f.row, &api).await.unwrap();
    let summary = summarize_request(&f.store, f.row.request_id).await.unwrap();
    assert_eq!(
        summary.unfinished_stages[0]
            .external_observation
            .as_ref()
            .unwrap()["child_stage"],
        "approved"
    );
    // Fixture the independent community worker's terminal result; this test
    // does not execute destructive community deletion.
    sqlx::query("UPDATE community_deletion_requests SET stage = 'retention_pending', completed_at = now() WHERE id = $1")
        .bind(c.id).execute(f.db.pool()).await.unwrap();
    assert_eq!(
        handle(&f.store, &f.lease, &f.row, &api).await.unwrap(),
        OwnedCommunityOutcome::Completed
    );
    let summary = summarize_request(&f.store, f.row.request_id).await.unwrap();
    assert_eq!(summary.completed_stages, 1);
    assert!(summary.unfinished_stages.is_empty());
    assert!(!summary.complete); // Only routing may finish the parent.
    let row = &summary.saved.stage_history[0];
    assert!(row.is_current);
    assert!(row.metadata_json.get("waiting").is_none());
    assert_eq!(row.metadata_json["result"]["retention_pending"], true);
}

#[tokio::test]
#[ignore = "requires Postgres"]
async fn preparation_failure_is_recoverable_and_does_not_duplicate_child() {
    let f = fixture().await;
    let api = lookup_only_api(&f);
    assert!(handle(&f.store, &f.lease, &f.row, &api).await.is_err());
    let c = child(&f).await;
    assert_eq!(c.stage, DeletionStage::Submitted);
    let before = f.store.inspect(f.row.request_id).await.unwrap();
    assert_eq!(before.request.status, "retry_wait");
    assert_eq!(before.execution.retry_count, 1);
    assert!(before.stage_history[0].last_error.is_some());
    sqlx::query("UPDATE entity_deletion_requests SET next_attempt_at = now() - interval '1 second' WHERE id = $1")
        .bind(f.row.request_id).execute(f.db.pool()).await.unwrap();
    assert_eq!(
        handle(&f.store, &f.lease, &f.row, &api).await.unwrap(),
        OwnedCommunityOutcome::Waiting
    );
    assert_eq!(child(&f).await, c);
    let summary = summarize_request(&f.store, f.row.request_id).await.unwrap();
    assert_eq!(
        summary.unfinished_stages[0]
            .external_observation
            .as_ref()
            .unwrap()["reason"],
        "preparation_required"
    );
    assert_eq!(summary.saved.execution.retry_count, 1);
    assert!(summary.saved.execution.last_error.is_none());
}

#[tokio::test]
#[ignore = "requires Postgres"]
async fn concurrent_submission_reuses_request_and_preserves_terminal_states() {
    let f = fixture().await;
    let store = f.db.deletion_store();
    let (a, b) = tokio::join!(
        store.submit_for_community(f.community, "operator-a", Some("a")),
        store.submit_for_community(f.community, "operator-b", Some("b"))
    );
    let (a, created_a) = a.unwrap();
    let (b, created_b) = b.unwrap();
    assert_ne!(created_a, created_b);
    assert_eq!(a, b);
    let api = lookup_only_api(&f);
    assert_eq!(api.submit(f.community, "another", None).await.unwrap(), a);
    store.abort(a.id, "operator", "cancelled").await.unwrap();
    let aborted = child(&f).await;
    assert_eq!(aborted.stage, DeletionStage::Aborted);
    assert_eq!(
        api.submit(f.community, "another", None).await.unwrap(),
        aborted
    );
    assert_eq!(
        handle(&f.store, &f.lease, &f.row, &api).await.unwrap(),
        OwnedCommunityOutcome::Waiting
    );
    let summary = summarize_request(&f.store, f.row.request_id).await.unwrap();
    assert_eq!(
        summary.unfinished_stages[0]
            .external_observation
            .as_ref()
            .unwrap()["reason"],
        "operator_intervention"
    );
}

#[tokio::test]
#[ignore = "requires Postgres"]
async fn stale_generation_cannot_save_wait_or_execute_handler() {
    let f = fixture().await;
    f.store.start_stage(&f.lease, f.row.id).await.unwrap();
    sqlx::query("UPDATE entity_deletion_requests SET lease_expires_at = now() - interval '1 second' WHERE id = $1")
        .bind(f.row.request_id).execute(f.db.pool()).await.unwrap();
    let new = f
        .store
        .claim(f.row.request_id, &f.lease.owner, Duration::from_secs(60))
        .await
        .unwrap()
        .unwrap();
    assert_eq!(new.generation, f.lease.generation + 1);
    let before = serde_json::to_value(f.store.inspect(f.row.request_id).await.unwrap()).unwrap();
    let error = f
        .store
        .save_stage_waiting(&f.lease, f.row.id, json!({"kind": "test"}))
        .await
        .unwrap_err();
    assert!(buzz_db::deletion::is_stale_deletion_lease(&error));
    assert!(handle(&f.store, &f.lease, &f.row, &lookup_only_api(&f))
        .await
        .is_err());
    assert!(f
        .db
        .deletion_store()
        .find_for_community(f.community)
        .await
        .unwrap()
        .is_none());
    assert_eq!(
        serde_json::to_value(f.store.inspect(f.row.request_id).await.unwrap()).unwrap(),
        before
    );
    f.store
        .save_stage_waiting(
            &new,
            f.row.id,
            json!({"kind": "other_external_system", "operator_action": "wait for export"}),
        )
        .await
        .unwrap();
    let summary = summarize_request(&f.store, f.row.request_id).await.unwrap();
    assert_eq!(summary.unfinished_stages[0].state, "waiting_external");
    assert_eq!(
        summary.unfinished_stages[0]
            .external_observation
            .as_ref()
            .unwrap()["kind"],
        "other_external_system"
    );
}

#[tokio::test]
#[ignore = "requires Postgres"]
async fn wrong_community_or_inputs_cannot_submit_a_child() {
    let f = fixture().await;
    sqlx::query("UPDATE entity_deletion_stage_history SET metadata_json = jsonb_set(metadata_json, '{inputs,target}', '\"different-user\"') WHERE id = $1")
        .bind(f.row.id).execute(f.db.pool()).await.unwrap();
    // The caller's original row is stale; validation must reload persisted inputs.
    assert!(handle(&f.store, &f.lease, &f.row, &lookup_only_api(&f))
        .await
        .is_err());
    assert!(f
        .db
        .deletion_store()
        .find_for_community(f.community)
        .await
        .unwrap()
        .is_none());
}
