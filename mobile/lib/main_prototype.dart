import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'app.dart';
import 'main.dart' show runBuzzApp;
import 'prototype/remote_agent_controller.dart';
import 'shared/hosted/account_identity_store.dart';
import 'shared/hosted/browser_auth.dart';
import 'shared/hosted/hosted_relay_auth.dart';
import 'shared/agents/agents_surface.dart';
import 'prototype/agents_sheet.dart';
import 'prototype/agent_link_surface.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await runBuzzApp(const RemotePrototype());
}

/// Separate entry point keeps the throwaway workflow out of normal app builds.
class RemotePrototype extends HookConsumerWidget {
  const RemotePrototype({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = useMemoized(
      () => RemoteAgentController(
        account: ref.read(builderlabAccountProvider),
        relayAuth: ref.read(hostedRelayAuthProvider),
        browser: BrowserAuth(),
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
        agentsSurfaceProvider.overrideWithValue((context) async {
          await controller.run(controller.refresh);
          if (context.mounted) await showPrototypeAgents(context, controller);
        }),
        agentCreationSurfaceProvider.overrideWithValue((context, draft) async {
          await controller.run(controller.refresh);
          if (context.mounted) {
            await showAgentLinkCreate(context, controller, draft);
          }
        }),
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
