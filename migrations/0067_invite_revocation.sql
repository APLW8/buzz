ALTER TABLE relay_invites ADD COLUMN revoked_at TIMESTAMPTZ;
ALTER TABLE relay_invites ADD COLUMN legacy_admission BOOLEAN NOT NULL DEFAULT true;

-- Serialize invitation admission with restriction and ownership changes per tenant.
CREATE FUNCTION invite_admission_lock(community UUID) RETURNS VOID
LANGUAGE sql AS $$
    SELECT pg_advisory_xact_lock(hashtextextended('invite-admission:' || community::text, 0));
$$;

-- Live revocation is application-owned: supported restriction and owner writers
-- take invite_admission_lock before row locks and revoke in the same commit.
-- Rollout gate: drain all old writer pods before lifting bans or reopening
-- invitation admission, then rerun backfill_invite_revocations() under the
-- schema-destruction maintenance lock to repair bans committed during rollout.
-- Keep active bans authoritative for every invite. Legacy rows are additionally
-- revoked for any retained restriction row on their canonical issuer or current
-- owner, even when the restriction was lifted or the invite was minted later.
-- Do not infer enforcement from moderation or action audit rows. Scope every
-- issuer, owner, and restriction lookup to the invitation's community.
-- Schema migrations hold the exclusive schema-destruction lock. Retain the
-- universal tenant fence too: acquire its shared lock, then read the current
-- generation before applying this narrowly scoped historical security repair.
-- A quiescing tenant may return to active, so skipping it could revive bearers.
CREATE FUNCTION backfill_invite_revocations() RETURNS BIGINT
LANGUAGE plpgsql AS $$
DECLARE
    target RECORD;
    affected BIGINT;
    total BIGINT := 0;
    current_generation BIGINT;
    prior_community TEXT := current_setting('buzz.deletion_executor_community', true);
    prior_generation TEXT := current_setting('buzz.deletion_fence_generation', true);
BEGIN
    FOR target IN SELECT id FROM communities
                  WHERE EXISTS (SELECT 1 FROM relay_invites WHERE community_id = communities.id)
                  ORDER BY id
    LOOP
        PERFORM pg_advisory_xact_lock_shared(community_deletion_lock_key(target.id));
        SELECT deletion_fence_generation INTO STRICT current_generation
        FROM communities WHERE id = target.id;
        PERFORM set_config('buzz.deletion_executor_community', target.id::text, true);
        PERFORM set_config('buzz.deletion_fence_generation', current_generation::text, true);
        UPDATE relay_invites i SET revoked_at = clock_timestamp()
        WHERE i.community_id = target.id AND i.revoked_at IS NULL
          AND (
            EXISTS (
                SELECT 1 FROM community_bans b
                WHERE b.community_id = i.community_id
                  AND (
                    b.pubkey = CASE WHEN octet_length(i.created_by) = 64
                                        AND i.created_by !~ '[^0-9a-f]'
                                    THEN decode(i.created_by, 'hex') END
                    OR b.pubkey = (
                        SELECT u.agent_owner_pubkey
                        FROM users u
                        WHERE u.community_id = i.community_id
                          AND octet_length(i.created_by) = 64
                          AND i.created_by !~ '[^0-9a-f]'
                          AND encode(u.pubkey, 'hex') = i.created_by
                    )
                  )
                  AND (
                    i.legacy_admission
                    OR (b.banned AND (b.ban_expires_at IS NULL
                                      OR b.ban_expires_at > clock_timestamp()))
                  )
            )
            OR (i.legacy_admission AND (
                octet_length(i.created_by) <> 64 OR i.created_by ~ '[^0-9a-f]'
            ))
          );
        GET DIAGNOSTICS affected = ROW_COUNT;
        total := total + affected;
        PERFORM set_config('buzz.deletion_executor_community', COALESCE(prior_community, ''), true);
        PERFORM set_config('buzz.deletion_fence_generation', COALESCE(prior_generation, ''), true);
    END LOOP;
    RETURN total;
END
$$;

SELECT backfill_invite_revocations();
