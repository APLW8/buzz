//! Stable manifests hold revision identities. Each read uses current authority.
use crate::{Db, DbError, Result};
use buzz_core::{
    artifact::{ArtifactQuery, ArtifactView},
    CommunityId, StoredEvent,
};
use serde::{Deserialize, Serialize};
use sqlx::{PgConnection, QueryBuilder, Row};
use uuid::Uuid;

/// Maximum identities in a complete manifest.
pub const MAX_ROWS: usize = 50_000;
/// Maximum serialized internal manifest size.
pub const MAX_BYTES: usize = 16 * 1024 * 1024;

/// One captured current revision.
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Entry {
    /// Stable artifact identity.
    pub artifact_id: Uuid,
    /// Exact signed event identity.
    pub revision_id: String,
    /// Home at capture.
    pub channel_id: Uuid,
}

/// Internal snapshot state. This is never sent to the reader.
#[derive(Clone, Deserialize, Serialize)]
pub struct Manifest {
    /// Public manifest entries.
    pub entries: Vec<Entry>,
    // Row versions detect redaction followed by recovery, and access revoke/regrant.
    revisions: Vec<String>,
    policy: Vec<(Uuid, String, Option<String>)>,
    predicates: Vec<(String, Vec<String>)>,
    // PostgreSQL snapshot bounds include writes in progress during capture.
    xmax: String,
    active: Vec<String>,
}

async fn begin(db: &Db) -> Result<sqlx::Transaction<'static, sqlx::Postgres>> {
    let connection = crate::observability::acquire_writer(
        &db.pool,
        crate::observability::WriterOperation::SubscriptionHistory,
    )
    .await?;
    let mut tx = sqlx::Transaction::begin(connection, None).await?;
    sqlx::query("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY")
        .execute(&mut *tx)
        .await?;
    sqlx::query("SET LOCAL statement_timeout='2s'")
        .execute(&mut *tx)
        .await?;
    Ok(tx)
}

async fn policy(
    conn: &mut PgConnection,
    community: CommunityId,
    reader: &[u8],
    query: &ArtifactQuery,
) -> Result<Vec<(Uuid, String, Option<String>)>> {
    // Resolve membership once. OR permission predicates over a join can select
    // repeated scans for a community whose statistics are still sparse.
    let members = sqlx::query("SELECT channel_id,xmin::text AS version FROM channel_members WHERE community_id=$1 AND pubkey=$2 AND removed_at IS NULL LIMIT 50001")
        .bind(community.as_uuid()).bind(reader).fetch_all(&mut *conn).await?;
    if members.len() > MAX_ROWS {
        return Err(DbError::ArtifactSnapshotLimit);
    }
    let members = members
        .into_iter()
        .map(|r| {
            Ok((
                r.try_get::<Uuid, _>("channel_id")?,
                r.try_get::<String, _>("version")?,
            ))
        })
        .collect::<Result<std::collections::HashMap<_, _>>>()?;
    let mut qb = QueryBuilder::<sqlx::Postgres>::new(
        "SELECT c.id,c.xmin::text AS version,c.ttl_seconds FROM channels c WHERE c.community_id=",
    );
    qb.push_bind(community.as_uuid())
        .push(" AND c.deleted_at IS NULL AND (")
        .push(super::channel::legacy_channel_type_sql("c.channel_type"))
        .push(" OR c.id=ANY(")
        .push_bind(
            query
                .tags
                .iter()
                .filter(|(n, _)| n == "h")
                .flat_map(|(_, v)| v.iter().filter_map(|s| s.parse::<Uuid>().ok()))
                .collect::<Vec<_>>(),
        )
        .push(")) AND (c.visibility='open' OR c.id=ANY(")
        .push_bind(members.keys().copied().collect::<Vec<_>>())
        .push(")) ORDER BY c.id LIMIT ")
        .push_bind((MAX_ROWS + 1) as i64);
    let rows = qb.build().fetch_all(&mut *conn).await?;
    if rows.len() > MAX_ROWS {
        return Err(DbError::ArtifactSnapshotLimit);
    }
    let channels = rows
        .iter()
        .map(|r| r.get::<Uuid, _>("id"))
        .collect::<Vec<_>>();
    let homes = current_rows(conn, community, channels, query)
        .await?
        .into_iter()
        .map(|(e, _)| e.channel_id)
        .collect::<std::collections::HashSet<_>>();
    let rows = rows
        .into_iter()
        .filter(|r| homes.contains(&r.get::<Uuid, _>("id")))
        .collect::<Vec<_>>();
    if rows
        .iter()
        .any(|r| r.get::<Option<i32>, _>("ttl_seconds").is_some())
    {
        return Err(DbError::ArtifactSnapshotUnsupportedScope);
    }
    rows.into_iter()
        .map(|r| {
            Ok((
                r.try_get("id")?,
                r.try_get("version")?,
                members.get(&r.try_get::<Uuid, _>("id")?).cloned(),
            ))
        })
        .collect()
}

async fn body_policy(
    conn: &mut PgConnection,
    community: CommunityId,
    reader: &[u8],
    channels: Vec<Uuid>,
) -> Result<Vec<(Uuid, String, Option<String>)>> {
    let members = sqlx::query("SELECT channel_id,xmin::text AS version FROM channel_members WHERE community_id=$1 AND pubkey=$2 AND channel_id=ANY($3) AND removed_at IS NULL")
        .bind(community.as_uuid()).bind(reader).bind(&channels).fetch_all(&mut *conn).await?;
    let members = members
        .into_iter()
        .map(|r| {
            Ok((
                r.try_get::<Uuid, _>("channel_id")?,
                r.try_get::<String, _>("version")?,
            ))
        })
        .collect::<Result<std::collections::HashMap<_, _>>>()?;
    let rows = sqlx::query("SELECT id,xmin::text AS version,visibility::text,ttl_seconds FROM channels WHERE community_id=$1 AND id=ANY($2) AND deleted_at IS NULL ORDER BY id")
        .bind(community.as_uuid()).bind(channels).fetch_all(&mut *conn).await?;
    let mut result = vec![];
    for row in rows {
        let id = row.try_get::<Uuid, _>("id")?;
        if row.try_get::<Option<i32>, _>("ttl_seconds")?.is_some() {
            return Err(DbError::ArtifactSnapshotReset);
        }
        if row.try_get::<String, _>("visibility")? == "open" || members.contains_key(&id) {
            result.push((id, row.try_get("version")?, members.get(&id).cloned()));
        }
    }
    Ok(result)
}

async fn current_rows(
    conn: &mut PgConnection,
    community: CommunityId,
    channels: Vec<Uuid>,
    query: &ArtifactQuery,
) -> Result<Vec<(Entry, String)>> {
    let mut heads = QueryBuilder::<sqlx::Postgres>::new(
        "SELECT artifact_id,event_id FROM artifact_heads WHERE community_id=",
    );
    heads
        .push_bind(community.as_uuid())
        .push(" AND NOT deleted AND channel_id=ANY(")
        .push_bind(channels)
        .push(")");
    if let Some((_, types)) = query.tags.iter().find(|(name, _)| name == "type") {
        heads
            .push(" AND artifact_type=ANY(")
            .push_bind(types)
            .push(")");
    }
    heads.push(" LIMIT ").push_bind((MAX_ROWS + 1) as i64);
    let heads = heads.build().fetch_all(&mut *conn).await?;
    if heads.len() > MAX_ROWS {
        return Err(DbError::ArtifactSnapshotLimit);
    }
    let heads = heads
        .into_iter()
        .map(|r| {
            Ok((
                r.try_get::<Vec<u8>, _>("event_id")?,
                r.try_get::<Uuid, _>("artifact_id")?,
            ))
        })
        .collect::<Result<std::collections::HashMap<_, _>>>()?;
    let mut events = QueryBuilder::<sqlx::Postgres>::new(
        "SELECT e.id,e.channel_id,e.xmin::text AS version FROM events e WHERE e.community_id=",
    );
    events
        .push_bind(community.as_uuid())
        .push(" AND e.kind=45010 AND e.deleted_at IS NULL AND e.id=ANY(")
        .push_bind(heads.keys().cloned().collect::<Vec<_>>())
        .push(")");
    super::artifact_query::tag_predicates(&mut events, query);
    events.push(" LIMIT ").push_bind((MAX_ROWS + 1) as i64);
    let rows = events.build().fetch_all(&mut *conn).await?;
    if rows.len() > MAX_ROWS {
        return Err(DbError::ArtifactSnapshotLimit);
    }
    let mut result = Vec::with_capacity(rows.len());
    for row in rows {
        let id: Vec<u8> = row.try_get("id")?;
        let artifact_id = heads
            .get(&id)
            .copied()
            .ok_or_else(|| DbError::InvalidData("snapshot head missing".into()))?;
        result.push((
            Entry {
                artifact_id,
                revision_id: hex::encode(id),
                channel_id: row.try_get("channel_id")?,
            },
            row.try_get("version")?,
        ));
    }
    result.sort_unstable_by_key(|(entry, _)| entry.artifact_id);
    Ok(result)
}

impl Db {
    /// Capture all matching current identities in one bounded database snapshot.
    pub async fn capture_artifact_manifest(
        &self,
        community: CommunityId,
        reader: &[u8],
        query: &ArtifactQuery,
    ) -> Result<Manifest> {
        let mut tx = begin(self).await?;
        let snapshot: String = sqlx::query_scalar("SELECT pg_current_snapshot()::text")
            .fetch_one(&mut *tx)
            .await?;
        let parts: Vec<_> = snapshot.split(':').collect();
        let xmax = parts
            .get(1)
            .ok_or_else(|| DbError::InvalidData("invalid database snapshot".into()))?
            .parse::<u64>()
            .map_err(|_| DbError::InvalidData("invalid database snapshot".into()))?;
        let active = parts
            .get(2)
            .ok_or_else(|| DbError::InvalidData("invalid database snapshot".into()))?
            .split(',')
            .filter(|v| !v.is_empty())
            .map(|v| v.parse::<u64>().map(|n| (n as u32).to_string()))
            .collect::<std::result::Result<Vec<_>, _>>()
            .map_err(|_| DbError::InvalidData("invalid database snapshot".into()))?;
        let policy = policy(&mut tx, community, reader, query).await?;
        let rows = current_rows(
            &mut tx,
            community,
            policy.iter().map(|(id, _, _)| *id).collect(),
            query,
        )
        .await?;
        let (entries, revisions) = rows.into_iter().unzip();
        let manifest = Manifest {
            entries,
            revisions,
            policy,
            predicates: query.tags.clone(),
            xmax: (xmax as u32).to_string(),
            active,
        };
        if serde_json::to_vec(&manifest)?.len() > MAX_BYTES {
            return Err(DbError::ArtifactSnapshotLimit);
        }
        tx.commit().await?;
        Ok(manifest)
    }

    /// Recheck the full manifest and fetch only requested captured revisions.
    /// An empty request validates the completion boundary without reading bodies.
    pub async fn read_artifact_manifest(
        &self,
        community: CommunityId,
        reader: &[u8],
        manifest: &Manifest,
        requested: &[String],
        body_bytes: usize,
    ) -> Result<Vec<StoredEvent>> {
        if manifest.entries.len() != manifest.revisions.len() || requested.len() > 100 {
            return Err(DbError::InvalidData(
                "invalid artifact snapshot read".into(),
            ));
        }
        let selected;
        let complete = requested.is_empty();
        let manifest = if complete {
            manifest
        } else {
            let mut entries = vec![];
            let mut revisions = vec![];
            for id in requested {
                let index = manifest
                    .entries
                    .iter()
                    .position(|entry| &entry.revision_id == id)
                    .ok_or_else(|| DbError::InvalidData("revision outside snapshot".into()))?;
                entries.push(manifest.entries[index].clone());
                revisions.push(manifest.revisions[index].clone());
            }
            let homes = entries
                .iter()
                .map(|e| e.channel_id)
                .collect::<std::collections::HashSet<_>>();
            selected = Manifest {
                entries,
                revisions,
                policy: manifest
                    .policy
                    .iter()
                    .filter(|(id, _, _)| homes.contains(id))
                    .cloned()
                    .collect(),
                predicates: manifest.predicates.clone(),
                xmax: manifest.xmax.clone(),
                active: manifest.active.clone(),
            };
            &selected
        };
        let mut tx = begin(self).await?;
        let current_policy = if complete {
            let query = ArtifactQuery {
                view: ArtifactView::Current,
                tags: manifest.predicates.clone(),
                limit: 1,
                offset: 0,
            };
            policy(&mut tx, community, reader, &query)
                .await
                .map_err(|e| match e {
                    DbError::ArtifactSnapshotUnsupportedScope => DbError::ArtifactSnapshotReset,
                    other => other,
                })?
        } else {
            body_policy(
                &mut tx,
                community,
                reader,
                manifest.policy.iter().map(|(id, _, _)| *id).collect(),
            )
            .await?
        };
        if current_policy != manifest.policy {
            return Err(DbError::ArtifactSnapshotReset);
        }
        let ids = manifest
            .entries
            .iter()
            .map(|e| e.artifact_id)
            .collect::<Vec<_>>();
        let revisions = manifest
            .entries
            .iter()
            .map(|e| {
                hex::decode(&e.revision_id)
                    .map_err(|_| DbError::InvalidData("invalid captured revision".into()))
            })
            .collect::<Result<Vec<_>>>()?;
        // Fetch each bounded set once. A join over correlated arrays can choose
        // repeated scans when a new community has no statistics yet.
        let heads = sqlx::query("SELECT artifact_id,channel_id,deleted FROM artifact_heads WHERE community_id=$1 AND artifact_id=ANY($2)")
            .bind(community.as_uuid()).bind(&ids).fetch_all(&mut *tx).await?;
        let heads = heads
            .into_iter()
            .map(|r| {
                Ok((
                    r.try_get::<Uuid, _>("artifact_id")?,
                    (
                        r.try_get::<Uuid, _>("channel_id")?,
                        r.try_get::<bool, _>("deleted")?,
                    ),
                ))
            })
            .collect::<Result<std::collections::HashMap<_, _>>>()?;
        let rows = sqlx::query("SELECT id,channel_id,xmin::text AS version FROM events WHERE community_id=$1 AND id=ANY($2) AND deleted_at IS NULL LIMIT 50001")
            .bind(community.as_uuid()).bind(&revisions).fetch_all(&mut *tx).await?;
        if rows.len() != manifest.entries.len() {
            return Err(DbError::ArtifactSnapshotReset);
        }
        let visible = rows
            .into_iter()
            .map(|r| {
                Ok((
                    hex::encode(r.try_get::<Vec<u8>, _>("id")?),
                    (
                        r.try_get::<Uuid, _>("channel_id")?,
                        r.try_get::<String, _>("version")?,
                    ),
                ))
            })
            .collect::<Result<std::collections::HashMap<_, _>>>()?;
        for (entry, version) in manifest.entries.iter().zip(&manifest.revisions) {
            if heads.get(&entry.artifact_id) != Some(&(entry.channel_id, false))
                || visible.get(&entry.revision_id) != Some(&(entry.channel_id, version.clone()))
            {
                return Err(DbError::ArtifactSnapshotReset);
            }
        }
        // age(xid) uses signed transaction distance, including XID wraparound.
        // Active capture transactions must also be checked when they commit.
        let changed: bool = sqlx::query_scalar(
            "SELECT EXISTS(SELECT 1 FROM artifact_revisions r LEFT JOIN events e \
             ON e.community_id=r.community_id AND e.id=r.event_id \
             WHERE r.community_id=$1 AND r.artifact_id=ANY($2) \
             AND (age(r.xmin)<=age($3::text::xid) OR r.xmin::text=ANY($4)) \
             AND (e.id IS NULL OR e.deleted_at IS NOT NULL \
             OR e.tags @> '[[\"op\",\"delete\"]]'::jsonb OR e.tags @> '[[\"op\",\"move\"]]'::jsonb))",
        ).bind(community.as_uuid()).bind(&ids).bind(&manifest.xmax).bind(&manifest.active)
            .fetch_one(&mut *tx).await?;
        if changed {
            return Err(DbError::ArtifactSnapshotReset);
        }
        let requested = requested
            .iter()
            .map(|s| {
                let index = manifest
                    .entries
                    .iter()
                    .position(|e| &e.revision_id == s)
                    .ok_or_else(|| DbError::InvalidData("revision outside snapshot".into()))?;
                Ok(revisions[index].clone())
            })
            .collect::<Result<Vec<_>>>()?;
        if requested.is_empty() {
            tx.commit().await?;
            return Ok(vec![]);
        }
        // Check serialized row sizes before transferring content from Postgres.
        let bytes: i64 = sqlx::query_scalar(
            "SELECT coalesce(sum(octet_length(to_json(content)::text)+octet_length(tags::text)+1024),0)::bigint \
             FROM events WHERE community_id=$1 AND id=ANY($2)",
        ).bind(community.as_uuid()).bind(&requested).fetch_one(&mut *tx).await?;
        if bytes > body_bytes as i64 {
            return Err(DbError::ArtifactSnapshotLimit);
        }
        let rows = sqlx::query("SELECT id,pubkey,created_at,kind,tags,content,sig,received_at,channel_id FROM events WHERE community_id=$1 AND id=ANY($2) ORDER BY id")
            .bind(community.as_uuid()).bind(requested).fetch_all(&mut *tx).await?;
        let mut events = vec![];
        for row in rows {
            events.push(
                crate::event::row_to_stored_event(row)?
                    .ok_or_else(|| DbError::InvalidData("invalid snapshot event".into()))?,
            );
        }
        tx.commit().await?;
        Ok(events)
    }
}
