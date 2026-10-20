# Throwaway staging remote-agent prototype

This is a separate mobile entry point rebased onto main `139f8903d5fd075a172b7555d88ae0e616cdcb39`, including the final authentication implementation from PR #8375 (`b6aa5539e3a44fe32a4bfe2963dfb23f10316985`). It uses the existing hosted-account session and identity-binding code, then the desktop BuilderLab Beekeeper API to register and activate an agent.

Entry point: `lib/main_prototype.dart`. Required build defines: `BUZZ_BUILDERLAB_URL=https://app.builderlabstaging.xyz`, `BUZZ_AUTH_DOMAINS=communities.public.builderlabstaging.xyz`, and `BUZZ_HOSTED_RELAY_AUTH=false` for the currently deployed public staging backend. The running test app has bundle identifier `xyz.block.buzz.dev.mobile.remoteprototype` and display name **Buzz Remote Prototype**.

## Simulator use

1. Open the saved staging community in the normal Buzz app.
2. Tap **Agents**, immediately to the left of Search. The list is scoped to that community and pushes agent details within the same modal when an agent is selected.
3. Tap **Add agent**, enter a display name and optional private instructions, then **Create**. Successful creation returns to the list. A failed attempt offers **Resume**, preserving its identity and instructions.
4. Open an agent profile to copy its public key or **Message** it. Normal channel mention discovery and admission rules still apply.
5. If signed out, use **Sign in** in Agents, then finish Mac Chrome login through `http://127.0.0.1:18763/start`. The loopback handoff expires after ten minutes and validates state and PKCE.

Remote availability is an explicit product presentation: exact keys returned ACTIVE by the authenticated Beekeeper registry show green Online in the profile, DM header/list and mention ranking (the Agents list shows names and avatars only). Beekeeper listens for messages and starts/resumes workers, so the worker's transient WebSocket presence is not its availability. Other agents and humans retain relay presence. This does not claim sandbox tool authorization or service-health guarantees.

The current registry supports name and private instructions, via registration then activation then `update-agent`. It offers no harness or model selection. Instructions are stored in device-only secure storage while setup is pending, separately from public pending metadata.

The prototype reuses an existing owner identity only after the current account binding confirms the same key. It adopts the saved key into the account-scoped slot without deleting the old record. New-community admission uses the shared encrypted-backup, binding verification, and relay probe services. Reopening an existing saved community verifies its key and current binding without redoing onboarding or replacing its record. It does not implement new-user identity selection or recovery UI. A debug-only native method transfers a one-time simulator launch environment value into device-only Keychain. It is compiled only for a debug simulator and checks the prototype bundle identifier. No key is embedded in source or build configuration.

The agent's private key remains on BuilderLab. Activation uses the owner's NIP-OA authorization, explicitly subscribes the agent to the selected community, and publishes a relay listing with owner-only responses and parallelism 1. Attestation alone only reconciles server-configured communities, so it is insufficient for a newly created community. Pending setup contains public identifiers only and is scoped to the staging account.

This is a local experiment, not a production onboarding implementation. Browser account sign-in, live registration, relay admission and agent response must all be verified before treating the end-to-end flow as working.

Verified on 2026-10-16: Chrome sign-in, existing Tom identity binding, disposable public staging community creation, agent registration/attestation/subscription, and a real reply in the private `prototype-test` channel. Agent `8397ca0794853c62d53c910775ac316474ec7f577bde8c5199091c15dae47953` replied “Remote agent is ready.” to event `7246a58737e32d1f7d60d75747c15f254dafa0b8c2742ecf6ac73485909671b4`. No production state was changed.

Adaptation source was recovered from Codex startup-cleanup snapshot `902ca75bae20e91d153acc40b3245e8f3e6384b8`; the original branch is preserved. Current worktree: `/Users/tomb/.codex/worktrees/remote-prototype-current/buzz`, branch `remote-prototype-current`. The app and prototype share one account client. The normal app retains main’s joined-community API. The prototype explicitly lists owned communities using `/v1/buzz/communities/list`: public staging returns 404 for `/joined` and `/identity/assertions` on October 19. Federated relay authentication remains at the documented default off until backend issuance exists; both agent listing publication and chat support it when enabled. No exception is added to normal app discovery or admission. The October 16 evidence above is historical, not verification of this adaptation.

October 19 validation so far: 122 hosted/prototype tests and full mobile-check passed, simulator build succeeded, fresh Chrome sign-in and account setup completed for the original subject, and original bound Buzz identity adopted without replacement. Fresh simulator E2E passed: selected the existing agent mention, sent event `b77569c7c013d1a807a2e4530c0b93f1a76fc997cf7dcd1d1d5e529abfb51b95` from the app, and received `d9cef9ae50dee8796cc59ce72578b7f39fac1a5df181970a2e124b9f6cf15b73`, “Rebased mobile prototype works.” Existing account, key, agent and private channel were preserved. Eight staging-specific prototype tests pass, including saved-community identity mismatch rejection.

Remaining live gates: public staging returns 404 for joined-community discovery and federated assertion issuance, and 400 for the current HPKE backup upload. New-community onboarding and federated enforcement are not claimed verified. New agent creation in the already-admitted community has also been repeated through the Agents modal; sandbox tool execution remains unverified. No production or conference release changes.

The clean Agents UI was validated on October 19: two fresh agents were created through the modal, successful creation returned to the updated list, and the existing profile supported Copy public key and Message into the correct DM. The controlled `UI Verification` agent received its optional instructions and replied exactly “Mobile Agents UI works.” to a verification request. Profiles opened from the list and the DM both showed Online. Focused validation: 107 mobile tests plus 13 staging prototype tests; full mobile-check and Xcode simulator build passed. These are agent-run simulator checks, not a user walkthrough.

## QR-create links

`buzz://agent/new#<base64url UTF-8 JSON>` opens an editable draft over the
current community. Opening a link never registers an agent. Version 1 accepts:

```json
{"v":1,"name":"QR Owl","instructions":"Keep answers brief.","avatar":{"emoji":"🦉","color":"#476CFF"}}
```

`avatar` may instead be an HTTPS image URL string. Emoji backgrounds use
`#RRGGBB`; emoji must be one grapheme. Image bytes, HTTP URLs and URL credentials
are rejected. The hard limit is **1,024 bytes for the entire encoded URL**, not
just its JSON. Unknown JSON fields are ignored. Names use the existing
prototype's 1–64 letter/number/space/dot/hyphen/underscore contract.

Both cold-start Camera links and warm external hyperlinks use the existing
app-link queue. Dispatch waits for signed-in app/account and current-community
hydration. Name and instructions are editable, avatar is read-only, and the
header names the destination community. A community change prevents submission.
Only the default remote provider is used. No QR signing or QR-generator UI is
included. Signed-out users must sign in and reopen the link; unfinished agent
setup must be resumed before opening a new draft.

Create opens above the retained Agents list. Only the top creation form displays
submission progress. Success reveals the refreshed list; failure preserves the
form and pending identity for retry. Agent details remain a pushed page inside
Agents, with Back, Message, Copy public key and an ownership-gated Delete action.
Delete requires confirmation and removes the selected-community registration
before the remote runtime, preserving history and memberships.

### Avatar persistence and compatibility

Beekeeper register, attest and update contracts do not accept an avatar. The QR
avatar is therefore stored as **owner-definition artwork**, not a rewritten
agent-signed kind-0 profile: a canonical NIP-AP kind-30175 definition carries
`display_name` and `avatar_url`, and the kind-30177 instance links its slug via
`persona_id`. Private instructions stay in Beekeeper and secure pending storage,
never in the public definition. Emoji descriptors become the existing Buzz SVG
avatar format; HTTPS image URLs are retained without uploading image bytes.

Public avatar URLs are cached per account across local restarts. Opening Agents
also restores artwork from the owner's linked relay definitions. The prototype
shows definition artwork in its list, detail, DM list and message/thread avatars.
Other clients that render only kind-0 profiles will continue to show that profile's
avatar. Deletion currently leaves the reusable owner definition behind. It does
not delete registrations or definitions from other communities.

## Physical-device preparation (October 20, 2026)

Use an isolated personal-team identity, **com.tombrow.buzz.remoteprototype**,
with its `.NotificationService` extension and matching App Group, team
**DE7S2975CH**. Do not replace BuzzDev (`com.tombrow.buzz.mobile`), normal Buzz,
or other prototypes. The entry point and staging defines above are unchanged.
The debug identity-import channel and Mac Chrome bridge are simulator-only;
physical builds use normal native browser authentication.

Build with Xcode, not `flutter build`:

```sh
xcodebuild -workspace mobile/ios/Runner.xcworkspace -scheme Runner \
  -configuration Debug -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/buzz-remote-qr-device-build -allowProvisioningUpdates \
  BUNDLE_IDENTIFIER=com.tombrow.buzz.remoteprototype \
  BUZZ_DEVELOPMENT_TEAM=DE7S2975CH DEVELOPMENT_TEAM=DE7S2975CH \
  APP_DISPLAY_NAME='Buzz Remote Prototype' FLUTTER_TARGET=lib/main_prototype.dart \
  CODE_SIGN_STYLE=Automatic build
```

The first phone-target compilation passed with an existing development profile,
but that artifact was not installed. Isolated signing is currently blocked:
Xcode 27 reports **No Accounts**, its personal-account list is empty, and the
fallback wildcard profile lacks the required explicit app capabilities. Restore
the personal Xcode account and provision the isolated app/extension before
retrying. Do not strip entitlements to work around this gate.

Physical validation awaits an exclusive iPhone SE reservation from the mobile
coordinator. BLIMP is the corporate iPhone 15 and prohibits sideloading; the
personal iPhone 16e is excluded. Do not substitute the unverified 12 mini.

Pending acceptance: install the isolated signed build on the reserved test phone,
complete sign-in/current-community readiness, scan the hand-authored demo QR with
Camera, verify no automatic creation, edit/submit, and verify avatar persistence
and a real agent response. Source/widget tests and QR image decoding do not prove
these physical-device steps. No production or conference-release inclusion.
