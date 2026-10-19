# Throwaway staging remote-agent prototype

This is a separate mobile entry point on Wes's mobile-onboarding branch. It uses the existing hosted-account session and identity-binding code, then the desktop BuilderLab Beekeeper API to register and activate an agent.

Entry point: `lib/main_prototype.dart`. Required build define: `BUZZ_BUILDERLAB_URL=https://app.builderlabstaging.xyz`. The running test app has bundle identifier `xyz.block.buzz.dev.mobile.remoteprototype` and display name **Buzz Remote Prototype**.

## Simulator use

1. Tap **Sign in to BuilderLab staging**.
2. In Mac Chrome, open `http://127.0.0.1:18763/start` and finish the staging account login. The loopback handoff expires after ten minutes. The app validates state and exchanges the code with PKCE.
3. Choose an owned staging community, or create the disposable staging community, and enter an agent name.
4. Tap **Create remote agent**. If an operation fails, **Resume agent setup** reuses the saved registration ID and idempotency key.
5. Open the community in Buzz to interact with the agent.

The prototype imports an existing owner identity; it does not implement new-user key backup or recovery. A debug-only native method transfers a one-time simulator launch environment value into device-only Keychain. It is compiled only for a debug simulator and checks the prototype bundle identifier. No key is embedded in source or build configuration.

The agent's private key remains on BuilderLab. Activation uses the owner's NIP-OA authorization, explicitly subscribes the agent to the selected community, and publishes a relay listing with owner-only responses and parallelism 1. Attestation alone only reconciles server-configured communities, so it is insufficient for a newly created community. The link button beside an existing agent idempotently subscribes it to the selected community. Pending setup contains public identifiers only and is scoped to the staging account.

This is a local experiment, not a production onboarding implementation. Browser account sign-in, live registration, relay admission and agent response must all be verified before treating the end-to-end flow as working.

Verified on 2026-10-16: Chrome sign-in, existing Tom identity binding, disposable public staging community creation, agent registration/attestation/subscription, and a real reply in the private `prototype-test` channel. Agent `8397ca0794853c62d53c910775ac316474ec7f577bde8c5199091c15dae47953` replied “Remote agent is ready.” to event `7246a58737e32d1f7d60d75747c15f254dafa0b8c2742ecf6ac73485909671b4`. No production state was changed.
