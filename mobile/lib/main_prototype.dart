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
import 'shared/identity_transfer/nsec_import_sheet.dart';
import 'shared/theme/app_theme.dart';
import 'shared/theme/grid.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // A one-time, in-memory simulator launch environment transfers the owner's
  // existing identity into device-only Keychain. Never compiled into the app.
  final nsec = kDebugMode
      ? await const MethodChannel(
          'buzz/prototype_identity',
        ).invokeMethod<String>('take')
      : null;
  if (kDebugMode && nsec != null) await AccountIdentityStore().create(nsec);
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
        browser: BrowserAuth(
          openBrowser: kDebugMode ? openSimulatorChrome : null,
        ),
        keys: AccountIdentityStore(),
      ),
    );
    useListenable(controller);
    useEffect(() {
      unawaited(controller.initialize());
      return controller.dispose;
    }, [controller]);
    final name = useTextEditingController(text: 'Tom staging prototype');
    final inBuzz = useState(false);
    if (inBuzz.value) {
      return MaterialApp(
        theme: AppTheme.light(),
        darkTheme: AppTheme.dark(),
        home: Stack(
          children: [
            const App(),
            Positioned(
              right: Grid.xs,
              top: Grid.xl,
              child: Material(
                borderRadius: BorderRadius.circular(Radii.card),
                child: TextButton(
                  onPressed: () => inBuzz.value = false,
                  child: const Text('Remote agents'),
                ),
              ),
            ),
          ],
        ),
      );
    }
    return MaterialApp(
      title: 'Buzz Remote Prototype',
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      home: Builder(
        builder: (context) => Scaffold(
          appBar: AppBar(title: const Text('Remote agents · staging')),
          body: ListView(
            padding: const EdgeInsets.all(Grid.gutter),
            children: [
              const Text(
                'Create a BuilderLab agent from your phone',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: Grid.xs),
              Text(controller.status),
              if (controller.busy)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: Grid.xs),
                  child: LinearProgressIndicator(),
                ),
              const SizedBox(height: Grid.xs),
              Text(
                controller.account.account == null
                    ? 'BuilderLab: signed out'
                    : 'BuilderLab: ${controller.account.account!.subject}',
              ),
              Text(
                controller.owner == null
                    ? 'Buzz identity: not transferred'
                    : 'Buzz identity: ${controller.owner!.substring(0, 16)}…',
              ),
              const SizedBox(height: Grid.xs),
              FilledButton(
                onPressed: controller.busy ? null : controller.signIn,
                child: const Text('Sign in to BuilderLab staging'),
              ),
              if (controller.owner == null)
                OutlinedButton(
                  onPressed: controller.busy
                      ? null
                      : () async {
                          await showNsecImportSheet(
                            context,
                            onImport: (nsec) async {
                              await controller.keys.create(nsec);
                            },
                          );
                          await controller.run(controller.refresh);
                        },
                  child: const Text('Import existing Buzz identity'),
                ),
              if (controller.account.account != null) ...[
                const SizedBox(height: Grid.sm),
                const Text('Community'),
                for (final community in controller.communities)
                  ListTile(
                    title: Text(community.name),
                    subtitle: Text(community.relayUrl),
                    leading: Icon(
                      controller.community?.relayUrl == community.relayUrl
                          ? Icons.radio_button_checked
                          : Icons.radio_button_unchecked,
                    ),
                    selected:
                        controller.community?.relayUrl == community.relayUrl,
                    onTap: controller.busy || controller.pending != null
                        ? null
                        : () => controller.run(
                            () => controller.selectCommunity(community),
                          ),
                  ),
                if (controller.communities.isEmpty) ...[
                  const Text('No owned staging communities found.'),
                  OutlinedButton(
                    onPressed: controller.busy
                        ? null
                        : controller.createTestCommunity,
                    child: const Text('Create disposable staging community'),
                  ),
                ],
                const SizedBox(height: Grid.xs),
                TextField(
                  controller: name,
                  enabled: !controller.busy && controller.pending == null,
                  decoration: const InputDecoration(
                    labelText: 'Agent name',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: Grid.xs),
                FilledButton(
                  onPressed:
                      controller.busy ||
                          controller.owner == null ||
                          controller.community == null
                      ? null
                      : () => controller.create(name.text),
                  child: Text(
                    controller.pending == null
                        ? 'Create remote agent'
                        : 'Resume agent setup',
                  ),
                ),
                OutlinedButton(
                  onPressed:
                      controller.busy ||
                          controller.owner == null ||
                          controller.community == null
                      ? null
                      : () => controller.run(() async {
                          await controller.saveCommunity();
                          inBuzz.value = true;
                        }),
                  child: const Text('Open community in Buzz'),
                ),
                TextButton(
                  onPressed: controller.busy
                      ? null
                      : () => controller.run(controller.refresh),
                  child: const Text('Refresh'),
                ),
                const Divider(),
                const Text('Your remote agents'),
                for (final agent in controller.agents)
                  ListTile(
                    title: Text(
                      agent['agent_name'] as String? ?? 'Unnamed agent',
                    ),
                    subtitle: Text(
                      '${agent['status']}\n${agent['agent_pubkey']}',
                    ),
                    isThreeLine: true,
                    trailing: IconButton(
                      tooltip: 'Subscribe to selected community',
                      icon: const Icon(Icons.link),
                      onPressed: controller.busy || controller.community == null
                          ? null
                          : () => controller.run(
                              () => controller.subscribe(
                                agent['agent_id'] as String,
                              ),
                            ),
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
