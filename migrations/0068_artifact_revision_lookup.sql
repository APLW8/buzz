SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '30s';

CREATE INDEX idx_artifact_revisions_artifact
    ON artifact_revisions (community_id, artifact_id);
