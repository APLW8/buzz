//! Community-ID lookup and idempotent operator admission for parent workflows.

use super::*;

impl DeletionStore {
    /// Find the current request, including terminal requests. If only aborted
    /// requests exist, return the latest one; callers must not silently recreate it.
    pub async fn find_for_community(
        &self,
        community: CommunityId,
    ) -> Result<Option<DeletionRequest>> {
        let row = sqlx::query(
            "SELECT * FROM community_deletion_requests WHERE community_id = $1
             ORDER BY (stage = 'aborted'), created_at DESC, id DESC LIMIT 1",
        )
        .bind(community.as_uuid())
        .fetch_optional(&self.pool)
        .await?;
        row.map(row_to_request).transpose()
    }

    /// Submit operator intent by immutable community ID, or return its existing
    /// request unchanged. The boolean identifies a newly inserted request.
    /// This does not approve, fence, or execute deletion.
    pub async fn submit_for_community(
        &self,
        community: CommunityId,
        requested_by: &str,
        reason: Option<&str>,
    ) -> Result<(DeletionRequest, bool)> {
        crate::store::entity_deletion::requests::validate_operator(requested_by)?;
        if reason.is_some_and(|value| value.len() > 4096) {
            return Err(DbError::DeletionSafety("reason exceeds 4096 bytes".into()));
        }
        let mut tx = self.pool.begin().await?;
        // Serialize our admissions and community lifecycle changes, while
        // allowing the legacy request FK's KEY SHARE check. FOR UPDATE would
        // deadlock a concurrent host-based INSERT against our unique-index wait.
        // The unique index also handles that existing host-based submit API.
        let target: Option<(String, String, bool)> = sqlx::query_as(
            "SELECT host, deletion_state, deleted_at IS NOT NULL
             FROM communities WHERE id = $1 FOR NO KEY UPDATE",
        )
        .bind(community.as_uuid())
        .fetch_optional(&mut *tx)
        .await?;
        let existing = sqlx::query(
            "SELECT * FROM community_deletion_requests WHERE community_id = $1
             ORDER BY (stage = 'aborted'), created_at DESC, id DESC LIMIT 1",
        )
        .bind(community.as_uuid())
        .fetch_optional(&mut *tx)
        .await?;
        if let Some(row) = existing {
            let request = row_to_request(row)?;
            tx.commit().await?;
            return Ok((request, false));
        }
        let (host, state, deleted) =
            target.ok_or_else(|| DbError::NotFound(format!("community {community}")))?;
        if state != "active" || deleted {
            return Err(DbError::DeletionSafety(
                "cannot submit deletion for an inactive community without a request".into(),
            ));
        }
        let inserted = sqlx::query(
            "INSERT INTO community_deletion_requests
                 (community_id, community_host, requested_by, reason)
             VALUES ($1, $2, $3, $4)
             ON CONFLICT (community_id) WHERE stage <> 'aborted' DO NOTHING
             RETURNING *",
        )
        .bind(community.as_uuid())
        .bind(host)
        .bind(requested_by)
        .bind(reason)
        .fetch_optional(&mut *tx)
        .await?;
        let created = inserted.is_some();
        let row = match inserted {
            Some(row) => row,
            // A separate statement gets a new READ COMMITTED snapshot after a
            // concurrent host-based submission wins the unique-index race.
            None => {
                sqlx::query(
                    "SELECT * FROM community_deletion_requests WHERE community_id = $1
                 ORDER BY (stage = 'aborted'), created_at DESC, id DESC LIMIT 1",
                )
                .bind(community.as_uuid())
                .fetch_one(&mut *tx)
                .await?
            }
        };
        let request = row_to_request(row)?;
        tx.commit().await?;
        Ok((request, created))
    }
}
