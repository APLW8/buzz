# Public simulator proof

This local prototype uses the full mobile onboarding flow and the prototype
remote-agent surfaces. It is not a release build. No App Clip is required.

## Isolation and repeatable builds

Use a new simulator rather than uninstalling an old app: uninstalling does not
prove Keychain state is empty. The helper never erases a simulator or account.
Production and staging have separate bundle IDs, app groups, Keychain groups,
account origins and build directories. Separate simulators
also prevent the two apps competing for the shared `buzz://` URL scheme.

From the repository root, activate Hermit first:

```sh
. ./bin/activate-hermit
python3 mobile/scripts/run-remote-prototype.py production \
  --device C287B2F1-DB50-4EC2-8C1F-20AF94FB5AD1 \
  --output <output-dir>/native-production
python3 mobile/scripts/run-remote-prototype.py staging \
  --device 61321F37-2AF8-4658-A367-6DAE29B82348 \
  --output <output-dir>/staging
```

| Build | Account origin | Hosted relay domain |
|---|---|---|
| production | `https://app.builderlab.xyz` | `communities.buzz.xyz` |
| staging | `https://app.builderlabstaging.xyz` | `communities.public.builderlabstaging.xyz` |

Xcode builds, signs, installs, and launches the selected app. No `flutter run` or
`flutter build` is used. To repeat a truly fresh-device test, create another
simulator and pass its UDID. Rerunning against the same device preserves state.

The default `--relay-auth false` leaves federated assertion issuance disabled;
it does not disable hosted account authentication, identity recovery, backup,
or community admission. Set it true only after verifying deployed support.

## User walkthrough

1. Open the exact Feedback invitation in the new simulator's Safari:
   `<Feedback community invite URL>`.
   This tests the QR's URL and app handoff, not a camera scan. Tom selected this
   existing Feedback invitation for the proof; its November 10 role is unverified.
   It is a production community, so use the production build. Staging needs its
   own valid community invitation and account, not rewritten production URLs.
2. Tom reviews and accepts the web age/terms prompts and opens Buzz.
3. A matching hosted invitation automatically starts account authentication.
   Authentication uses the shipping iOS `ASWebAuthenticationSession` bridge.
   The helper enables the existing debug-only `BUZZ_DEBUG_PRIVATE_LOGIN=true`
   option so this proof uses an ephemeral mobile browser session. No desktop
   Chrome bridge or identity-import channel is present. Tom selects the account
   and completes sign-in in the simulator's native authentication sheet.
4. Sign in using the intended existing account. Production candidate supplied
   by Tom in the allowlist discussion: Tom's personal account. Account
   capability and community membership must be checked live; an open allowlist
   PR is not proof of deployed access. Do not create a replacement identity or
   leave an existing real community without Tom's decision.
5. Verify existing-key recovery and the intended community. The current client
   may ask for community terms again in-app after web acceptance. Tom must
   personally accept those prompts. Recovery failure must stop, not mint a new
   key for a bound account.
6. Open the existing QR Owl `buzz://agent/new#...` link from its preserved
   artifact. Check name, instructions, and owl avatar before explicit Create.
7. Confirm creation in the joined community, open Message, send a deliberate
   test, and observe an actual remote reply. A populated draft is not success.
8. Verify avatar in Agents and profile, relaunch the same app, and check again.
   Record avatar persistence separately from prefill and cached rendering.

## Evidence boundaries

Fresh boot, successful login, identity recovery, membership, capability,
creation, reply, and avatar restoration are separate results. No live result
should be inferred from source inspection or unit tests. The old prototype's
successful staging replies and October 26 staging backup400/agent403 outcomes
are historical observations only.

## October 26 native-auth correction

The earlier desktop Chrome sign-in is not mobile-auth acceptance. Its simulator
and browser session remain preserved. The new production proof uses simulator
`C287B2F1-DB50-4EC2-8C1F-20AF94FB5AD1`, with no imported identity. The intended
personal account is Tom's personal account; Tom completes authentication.

The prior production request to `/api/goose/v1/buzz/nsec-backups/status`
returned HTTP 404. Source inspection suggests the backup module is not configured
in production, while staging has recovery disabled. Deployed configuration has
not been verified. Native login success alone will not resolve that server
blocker, and failure must not be interpreted as permission to replace a key.
