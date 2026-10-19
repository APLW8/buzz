# Throwaway staging remote-agent prototype

This is a separate mobile entry point rebased onto main `139f8903d5fd075a172b7555d88ae0e616cdcb39`, including the final authentication implementation from PR #8375 (`b6aa5539e3a44fe32a4bfe2963dfb23f10316985`). It uses the existing hosted-account session and identity-binding code, then the desktop BuilderLab Beekeeper API to register and activate an agent.

Entry point: `lib/main_prototype.dart`. Required build defines: `BUZZ_BUILDERLAB_URL=https://app.builderlabstaging.xyz`, `BUZZ_AUTH_DOMAINS=communities.public.builderlabstaging.xyz`, and `BUZZ_HOSTED_RELAY_AUTH=false` for the currently deployed public staging backend. The running test app has bundle identifier `xyz.block.buzz.dev.mobile.remoteprototype` and display name **Buzz Remote Prototype**.

## Simulator use

1. Tap **Sign in to BuilderLab staging**.
2. In Mac Chrome, open `http://127.0.0.1:18763/start` and finish the staging account login. The loopback handoff expires after ten minutes. The app validates state and exchanges the code with PKCE.
3. Choose an owned staging community, or create the disposable staging community, and enter an agent name.
4. Tap **Create remote agent**. If an operation fails, **Resume agent setup** reuses the saved registration ID and idempotency key.
5. Open the community in Buzz to interact with the agent.

The prototype reuses an existing owner identity only after the current account binding confirms the same key. It adopts the saved key into the account-scoped slot without deleting the old record. New-community admission uses the shared encrypted-backup, binding verification, and relay probe services. Reopening an existing saved community verifies its key and current binding without redoing onboarding or replacing its record. It does not implement new-user identity selection or recovery UI. A debug-only native method transfers a one-time simulator launch environment value into device-only Keychain. It is compiled only for a debug simulator and checks the prototype bundle identifier. No key is embedded in source or build configuration.

The agent's private key remains on BuilderLab. Activation uses the owner's NIP-OA authorization, explicitly subscribes the agent to the selected community, and publishes a relay listing with owner-only responses and parallelism 1. Attestation alone only reconciles server-configured communities, so it is insufficient for a newly created community. The link button beside an existing agent idempotently subscribes it to the selected community. Pending setup contains public identifiers only and is scoped to the staging account.

This is a local experiment, not a production onboarding implementation. Browser account sign-in, live registration, relay admission and agent response must all be verified before treating the end-to-end flow as working.

Verified on 2026-10-16: Chrome sign-in, existing Tom identity binding, disposable public staging community creation, agent registration/attestation/subscription, and a real reply in the private `prototype-test` channel. Agent `8397ca0794853c62d53c910775ac316474ec7f577bde8c5199091c15dae47953` replied “Remote agent is ready.” to event `7246a58737e32d1f7d60d75747c15f254dafa0b8c2742ecf6ac73485909671b4`. No production state was changed.

Adaptation source was recovered from Codex startup-cleanup snapshot `902ca75bae20e91d153acc40b3245e8f3e6384b8`; the original branch is preserved. Current worktree: `/Users/tomb/.codex/worktrees/remote-prototype-current/buzz`, branch `remote-prototype-current`. The app and prototype share one account client. The normal app retains main’s joined-community API. The prototype explicitly lists owned communities using `/v1/buzz/communities/list`: public staging returns 404 for `/joined` and `/identity/assertions` on October 19. Federated relay authentication remains at the documented default off until backend issuance exists; both agent listing publication and chat support it when enabled. No exception is added to normal app discovery or admission. The October 16 evidence above is historical, not verification of this adaptation.

October 19 validation so far: 122 hosted/prototype tests and full mobile-check passed, simulator build succeeded, fresh Chrome sign-in and account setup completed for the original subject, and original bound Buzz identity adopted without replacement. Fresh simulator E2E passed: selected the existing agent mention, sent event `b77569c7c013d1a807a2e4530c0b93f1a76fc997cf7dcd1d1d5e529abfb51b95` from the app, and received `d9cef9ae50dee8796cc59ce72578b7f39fac1a5df181970a2e124b9f6cf15b73`, “Rebased mobile prototype works.” Existing account, key, agent and private channel were preserved. Eight staging-specific prototype tests pass, including saved-community identity mismatch rejection.

Remaining live gates: public staging returns 404 for joined-community discovery and federated assertion issuance, and 400 for the current HPKE backup upload. New-community onboarding and federated enforcement are not claimed verified. The successful October 19 acceptance path resumes the already-admitted community and existing agent; it does not claim new-agent provisioning was repeated or sandbox tool execution verified. No production or conference release changes.
