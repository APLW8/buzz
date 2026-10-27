//! Privileged, in-process community API. This is not a network endpoint and
//! grants no new authority: callers must already be authorized operators.

use crate::enumerate_tenant_prefixes;
use anyhow::Result;
use buzz_core::CommunityId;
use buzz_db::deletion::{DeletionRequest, DeletionStage, DeletionStore, FrozenInventory};
use buzz_media::MediaStorage;
use std::sync::Arc;

/// Lookup and submit community deletion requests without claiming or executing
/// them. Operator approval remains a separate existing community operation.
pub struct CommunityDeletionApi {
    store: DeletionStore,
    media: Arc<MediaStorage>,
}

impl CommunityDeletionApi {
    /// Use the writer database and its matching deployment's object storage.
    pub fn new(store: DeletionStore, media: Arc<MediaStorage>) -> Self {
        Self { store, media }
    }

    /// Read current saved status, including blocked, completed and aborted
    /// requests. This never prepares, approves, or recreates a request.
    pub async fn lookup(&self, community: CommunityId) -> Result<Option<DeletionRequest>> {
        Ok(self.store.find_for_community(community).await?)
    }

    /// Create and prepare a request if none exists; concurrent submissions
    /// converge on the existing request without resetting its state or provenance.
    /// If preparation fails, the submitted row remains durable. The existing
    /// community `submit --host ... --requested-by ...` command can resume it.
    pub async fn submit(
        &self,
        community: CommunityId,
        requested_by: &str,
        reason: Option<&str>,
    ) -> Result<DeletionRequest> {
        let (request, created) = self
            .store
            .submit_for_community(community, requested_by, reason)
            .await?;
        if !created {
            return Ok(request);
        }
        let inventory = FrozenInventory {
            schema: self.store.inventory_schema(community).await?,
            storage: enumerate_tenant_prefixes(&self.store, &self.media, &request, None, None)
                .await?,
        };
        match self.store.freeze_inventory(request.id, &inventory).await {
            Ok(request) => Ok(request),
            Err(error) => {
                // An operator may have prepared/approved/aborted it while the
                // object listing ran. Never overwrite that committed state.
                let current = self.store.get(request.id).await?;
                if current.stage != DeletionStage::Submitted {
                    Ok(current)
                } else {
                    Err(error.into())
                }
            }
        }
    }
}
