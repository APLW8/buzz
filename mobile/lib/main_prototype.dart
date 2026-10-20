import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'app.dart';
import 'main.dart' show runBuzzApp;
import 'prototype/remote_agent_controller.dart';
import 'prototype/simulator_browser.dart';
import 'shared/hosted/account_identity_store.dart';
import 'shared/hosted/browser_auth.dart';
import 'shared/hosted/hosted_relay_auth.dart';
import 'shared/agents/agents_surface.dart';
import 'prototype/agents_sheet.dart';
import 'prototype/agent_link_surface.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // A one-time, in-memory simulator launch environment transfers the owner's
  // existing identity into device-only Keychain. Never compiled into the app.
  var simulator = false;
  if (kDebugMode) {
    try {
      final nsec = await const MethodChannel(
        'buzz/prototype_identity',
      ).invokeMethod<String>('take');
      simulator = true;
      if (nsec != null) await AccountIdentityStore().create(nsec);
    } on MissingPluginException {
      // This channel is intentionally registered only by the simulator build.
    }
  }
  await runBuzzApp(RemotePrototype(useSimulatorBrowser: simulator));
}

/// Separate entry point keeps the throwaway workflow out of normal app builds.
class RemotePrototype extends HookConsumerWidget {
  const RemotePrototype({super.key, this.useSimulatorBrowser = false});

  /// Uses the Mac Chrome loopback bridge only after simulator detection.
  final bool useSimulatorBrowser;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = useMemoized(
      () => RemoteAgentController(
        account: ref.read(builderlabAccountProvider),
        relayAuth: ref.read(hostedRelayAuthProvider),
        browser: BrowserAuth(
          openBrowser: useSimulatorBrowser ? openSimulatorChrome : null,
        ),
        keys: AccountIdentityStore(),
      ),
    );
    useListenable(controller);
    useEffect(() {
      unawaited(controller.initialize());
      return controller.dispose;
    }, [controller]);
    return ProviderScope(
      overrides: [
        agentsSurfaceProvider.overrideWithValue(
          (context) => showPrototypeAgents(context, controller),
        ),
        agentCreationSurfaceProvider.overrideWithValue(
          (context, draft) => showAgentLinkCreate(context, controller, draft),
        ),
        agentDefinitionAvatarsProvider.overrideWithValue(
          controller.account.account == null ? const {} : controller.avatarUrls,
        ),
        availableRemoteAgentsProvider.overrideWithValue({
          for (final agent in controller.agents)
            if (controller.account.account != null &&
                (agent['status'] == 'BEEKEEPER_AGENT_STATUS_ACTIVE' ||
                    agent['status'] == 2))
              agent['agent_pubkey'] as String,
        }),
      ],
      child: const App(),
    );
  }
}
