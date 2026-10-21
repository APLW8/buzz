NIP-AR
======

Channel Artifacts
-----------------

`draft` `optional` `relay`

Defines `kind:45010` for editable records called **artifacts**. Each artifact has one home channel and may be attached to a thread. Its home determines who can read it. Any number of artifacts, including of the same type, may share a channel or thread.

The relay manages identity, access, and revisions. Clients define the content types, such as `buzz.task` or `buzz.project`.

## Event format

Each event contains a complete snapshot. For example, a task created directly in a channel (standard signing fields omitted):

```json
{
  "kind": 45010,
  "tags": [
    ["ar", "1"],
    ["d", "04737c81-e5e8-4412-bb47-f446813cfeba"],
    ["h", "9b353519-f4fe-4757-aef4-bec6cc0ae54c"],
    ["type", "buzz.task"],
    ["title", "Fix the payment timeout"],
    ["op", "create"],
    ["assignee", "<assignee-pubkey>"],
    ["project", "17cfe3ca-b3d0-4a76-a2a4-4eaf0d3a4109"]
  ],
  "content": "{\"version\":1,\"status\":\"open\"}"
}
```

The `assignee` and `project` tags and the payload are illustrative, not required fields; this NIP does not define a task schema.

| Tag | Meaning |
| --- | --- |
| `ar` | Envelope version; `1`. |
| `d` | Stable artifact UUID. |
| `h` | Home channel UUID. |
| `type` | Namespaced content type. |
| `title` | Absent on `delete`; otherwise required, nonblank display title, at most 512 UTF-8 bytes. |
| `op` | `create`, `update`, `move`, `delete`, or `restore`. |
| `root` | Optional conversation anchor event ID within `h`. |
| `prev` | Previous accepted revision ID; required except on creation. |

Each listed tag has exactly two string elements and occurs once, except optional tags may be absent and `title` MUST be absent on `delete`. UUIDs are lowercase, hyphenated, and non-nil; event IDs are 64 lowercase hex characters. Type names are dot-separated lowercase ASCII components, each starting with a letter and otherwise using letters, digits, `_`, or `-`, up to 128 bytes total. `buzz.*` is reserved for published Buzz client contracts.

Relays MUST reject invalid envelopes, unsupported envelope versions, and events with more than 256 tags. Normal event-size and write quotas apply.

Clients place fields needed for filtering in client-defined tags. The relay matches tag names and values without interpreting their meaning; `content` remains opaque text. Client-defined tags cannot override the envelope or grant access.

## Identity and edits

An artifact is identified by `(community, d)`, independently of its author or home. `d` and `type` are immutable. Kind 45010 is a regular stored event, not a NIP-01 addressable event. It falls in Buzz's forum and social kind range (45000–45999) but is not a forum post and follows none of the forum rules.

Creation requires an unused `d`, `op=create`, and no `prev`. Every later revision MUST name the current accepted event in `prev`. The relay checks authorization and advances the current revision atomically: two competing edits cannot both succeed. Timestamps do not choose the winner.

Resubmitting an already accepted event succeeds without applying it again, even if a later revision has since become current, so a client that lost an acknowledgement never sees a false conflict. The response reveals nothing the sender can no longer read. A different event whose `prev` is not the current revision is a conflict. On conflict, clients fetch the current revision and reconcile their changes rather than resubmitting with only `prev` replaced, which would overwrite the competing edit. An `update` keeps `h`; a `move` changes it.

A `create` whose `d` is already in use fails. When the sender cannot read the existing artifact, the error reveals only that the identity is taken, never its home, type, title, or current revision. Clients MAY derive `d` deterministically, for example from the message an artifact tracks, and accept that disclosure.

On creation or when changed from the previous accepted revision, `root` MUST identify an existing, undeleted conversation anchor in `h`. Later loss of that anchor does not prevent edits. Replies belong to that conversation, not to an artifact revision.

## Access

Channel read permission governs every artifact read, including lookups, history, search, previews, counts, and live updates. Threads inherit their channel's audience. Membership and visibility changes take effect on subsequent reads and deliveries.

Write permission means permission to post a kind-9 message in the channel, including authentication, token restrictions, moderation, and archive checks. Relays apply these checks the same way, and at the same point, as for a kind-9 message. This includes agents and, where channel policy permits, nonmembers of open channels. Artifact writes use `messages:write`, the scope that admits kind-9 posting.

| Operation | Required permission |
| --- | --- |
| Create, update, delete, or restore | Write in the home channel. |
| Move | Write in both source and destination. |

These rules apply to every type and do not depend on who created the artifact. DM participants are peers. The relay determines channel type from the stored channel, not from an artifact tag.

Relationship tags organize work without changing access. Linking a task to a project does not move it or share it. References to repositories or other services retain those services' access and action permissions. Errors MUST NOT disclose inaccessible artifact details.

## Moving and deleting

A move publishes the current snapshot into the destination under the same `d`. Its `root` must be absent or belong to the destination. Clients MUST show the destination audience and the information being shared before confirmation.

The relay MUST atomically advance the current revision and store both arrival in the destination and removal from the source. The source receives a separate relay-authenticated removal identifying the artifact, source scope, and the revision it replaced, without destination metadata or content. Both are stored events, so a client that misses live delivery recovers them by replaying the channel. Relays unable to provide this MUST reject moves.

Earlier revisions remain under their original channels' access rules; a move never lets the destination read revisions from the source. The destination can load current state without reading earlier revisions. Conversation messages stay where they are.

Deletion is a soft delete: a revision with `op=delete`, empty content, and no `title` tag. It preserves the current `type`, `h`, and `root`, and contains only envelope tags and NIP-OA `auth` tags the relay has verified. It removes the artifact from current-state queries and active views. Its revisions stay readable under their channels' access rules until redacted or expired by retention, so a lookup by `d` returns the deletion. After deletion, only `restore` is accepted: it names the deletion in `prev`, keeps its `h`, and carries a complete snapshot that becomes the current state again. A deleted `d` stays reserved and is never reused for another artifact. Completing or archiving work is a content change, not deletion or channel archival.

## Moderation and retention

Relays MUST reject kind-5 deletion requests targeting artifact revisions with an explicit reason. A NIP-29 kind-9005 removal redacts a revision under the channel's ordinary message-removal rules: the relay withholds that revision from every surface, including lookups, history, and search. The relay still records the revision as accepted, so redaction never changes which revision is current, and its ID remains valid as `prev`. Redacting an artifact's current revision retires the artifact: it is absent from current-state queries, and clients that do not already hold that revision's ID cannot edit it further. Revision history is subject to the community's retention policy; expiring earlier revisions MUST NOT remove the current revision or break `prev` checks.

## Current state and queries

An artifact's current state is its latest accepted revision, as determined by the `prev` rules above. Current-state queries MUST return only that revision and omit deleted artifacts. For example, a task whose current revision belongs to Project B no longer appears in Project A's list, even if an earlier revision belonged there. Revision history is queried separately. This NIP does not define a public acceptance order or history pagination; relays record the order in which they accept revisions, and a later sync specification defines how clients observe it.

Relays MUST support querying current artifacts across channels the reader can access using exact tag-name/value matches, including multi-character tag names. Conditions on different tag names are combined with AND; requested values for one name are combined with OR. A match compares the tag name and its first value in the same tag. Access checks and tag matching apply before pagination and any counts. Older revisions do not contribute matches.

Relays MUST advertise and enforce limits on tag-name/value sizes, total tag bytes, query predicates and values, and page size. Queries MUST run within an enforced execution budget. Unsupported or over-limit requests fail explicitly; predicates MUST NOT be silently ignored or incomplete results presented as complete.

Artifact revisions are state changes, not conversation messages. Receiving one MUST NOT increase chat or reply counts, add a chat unread, mark a conversation read, or repeat mention or push notifications for tags carried over from the previous revision.

## Client behavior

Clients validate content before interpreting it as a known type. Unknown types or malformed content render a safe fallback using the title, type, and home link. Editors MUST preserve unfamiliar fields and annotation tags or decline the edit. References may be unavailable or cyclic; clients must handle them safely without assuming relay validation.

Artifact text is untrusted. A type name, relationship tag, or payload cannot authorize a privileged action. Moving, deleting, or revoking access cannot erase copies already downloaded.

## Stable manifest transport

The relay advertises `artifacts.snapshot.version = 1` in NIP-11. This
extension uses signed `POST /query` requests. Each request contains one
filter. It uses the same community and membership checks as other queries.
The existing `current` and `history` responses keep their array format.

Start a capture with:

```json
[{"artifact":"snapshot","action":"start","query":{"artifact":"current","#type":["buzz.task"]}}]
```

The query accepts current-state tag predicates. It does not accept `limit`
or `offset`. The relay captures all matching current identities in one
repeatable-read database transaction. Version 1 supports permanent channels only. A scope with a readable current
artifact in a TTL channel fails before the relay publishes a token. An
unrelated TTL chat does not block a task query. The relay never silently
omits matching artifacts in TTL channels.
Archive status remains client content.
The capture includes archived tasks that match the query.

Start and page responses have this form:

```json
{"version":1,"token":"opaque","expiresAt":1792600000,"entries":[{"artifactId":"uuid","revisionId":"event-id","channelId":"uuid"}],"nextToken":"opaque-cursor"}
```

`expiresAt` is an integer in epoch seconds. `token` remains constant for the
capture. A token is bound to its reader, community, query, and capture
generation. It grants no access by itself. The cursor names an immutable
page position within that capture. A page request has this form:

```json
[{"artifact":"snapshot","action":"page","token":"opaque","cursor":"opaque-cursor"}]
```

Each response supplies the cursor for the next page. Repeating a cursor
returns the same entries. A `null` `nextToken` marks the final page. The
relay tracks the pages it serves. Completion fails if a page is skipped.
A lost page response can be retried with the same cursor.

Fetch exact captured bodies with:

```json
[{"artifact":"snapshot","action":"bodies","token":"opaque","revisionIds":["event-id"]}]
```

The response is `{"version":1,"token":"opaque","events":[...]}`. It contains
exactly the requested revision IDs. It never substitutes a newer revision.
The client verifies each signature and its artifact, channel, and revision
against the manifest. The client can reuse a verified body that it already
has. Body durability is a client obligation. The relay does not keep body
receipts.

Validate the completion boundary with:

```json
[{"artifact":"snapshot","action":"complete","token":"opaque"}]
```

A valid response is `{"version":1,"token":"opaque","complete":true}`. Every request rechecks database authority. Manifest pages and completion
validate the full frozen scope. A body read validates only the requested
captured channels and revisions. A change in another captured channel can
remain undetected until completion; it still prevents absence reconciliation. Access
changes, a missing or redacted captured revision, and deletion or movement
of a captured artifact require a reset. A delete followed by restore, or a
move followed by a move back, still requires a reset. Ordinary post-capture
updates leave the captured revision available. Channel row changes can
conservatively require a reset, including metadata and TTL changes.

The client starts its active live subscriptions before capture. Loss of the
live socket prevents client completion. Server completion does not prove
that every captured home has a live subscription. Periodic authoritative
captures repair homes outside the active routes. It saves needed bodies before
it reconciles absent identities. Completion alone does not permit deletion
of local writes or live events received after capture. The client uses its
local write boundary to preserve those records. If the live interval is
lost, the client retains local records and starts a new capture. Live
removal hints and periodic captures repair missed access and removal events.
This extension has no durable global change log.

### Limits and failures

NIP-11 advertises these fields under `artifacts.snapshot`:

| Field | Value |
| --- | ---: |
| `version` | 1 |
| `maxRows` | 50000 |
| `pageRows` | 1000 |
| `pageBytes` | 262144 |
| `bodyRows` | 100 |
| `bodyBytes` | 8388608 |
| `lifetimeSeconds` | 300 |
| `permanentChannelsOnly` | true |

A capture above the row or byte limit fails. It is never truncated. The relay inspects at most 50,000 active memberships, readable channels,
and current candidates per operation. The candidate limit applies after the
immutable type predicate and before other tag predicates. Each internal
manifest is at most 16 MiB. Shared state is limited to 32 active
captures and 64 MiB of charged snapshot storage. Each reader has at most two
captures per community. Each process runs at most four snapshot operations
at once. Each SQL statement has a two-second limit. Each operation has an
eight-second elapsed limit. These limits include access checks.

A bounded error response contains `error` and `code` with the same value:

| HTTP status | Code | Client action |
| --- | --- | --- |
| 409 | `snapshot_reset` | Retain local records. Start a new capture with bounded backoff. |
| 413 | `snapshot_limit` | Reduce a body batch or query scope. Never reconcile a partial capture as complete. |
| 422 | `snapshot_unsupported_scope` | Retain local records. Use a scope that contains only permanent channels. |
| 400 | `snapshot_invalid` | Correct the request. |
| 503 | `snapshot_unavailable` | Retry with bounded backoff. Retain local records. |

A single body above the byte limit fails explicitly. Admission and
membership checks can also return their normal errors. All failures prevent
absence reconciliation.

Snapshot state uses the existing shared Redis store. It supports requests
across relay processes without session affinity. The complete manifest is
published atomically before its token is returned. The fixed expiry does
not extend on reads. Redis expiry, eviction, or loss requires a reset. A
Redis outage returns a service failure. The relay uses no memory fallback.
One Redis hash holds manifests, direct body records, and quota charges.
Eviction removes them together. Body reads fetch only the requested records.
A serving write lease protects capture registration. Community deletion
removes its records and quota charges.
Each capture has a fixed logical expiry. A bounded allocation step removes
expired captures. The hash expires when its last capture expires. A completed capture remains
replayable until expiry and counts against the resource limits during that
interval.
