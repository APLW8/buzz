import 'dart:async';

import 'package:buzz/prototype/agents_sheet.dart';
import 'package:buzz/features/profile/user_profile_sheet.dart';
import 'package:buzz/shared/mentions/agent_identity_provider.dart';
import 'package:buzz/shared/relay/relay.dart';
import 'package:nostr/nostr.dart' as nostr;
import 'package:buzz/prototype/create_agent_sheet.dart';
import 'package:buzz/prototype/remote_agent_controller.dart';
import 'package:buzz/shared/agents/agents_surface.dart';
import 'package:buzz/shared/community/community.dart';
import 'package:buzz/shared/community/community_provider.dart';
import 'package:buzz/shared/deeplink/deep_link.dart';
import 'package:buzz/shared/hosted/account_identity_store.dart';
import 'package:buzz/shared/hosted/browser_auth.dart';
import 'package:buzz/shared/hosted/builderlab_account.dart';
import 'package:buzz/shared/hosted/hosted_relay_auth.dart';
import 'package:buzz/features/profile/presence_cache_provider.dart';
import 'package:buzz/shared/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

class _Presence extends PresenceCacheNotifier {
  @override
  Map<String, String> build() => {'remote': 'offline', 'local': 'away'};
}

class _Controller extends RemoteAgentController {
  _Controller(BuilderlabAccountClient account)
    : super(
        account: account,
        browser: BrowserAuth(),
        keys: AccountIdentityStore(),
        relayAuth: HostedRelayAuth(account),
      );
  String? submittedName;
  String? submittedInstructions;
  bool succeed = true;
  Completer<void>? creationGate;
  @override
  Future<void> ensureBinding() async {
    owner = 'owner';
  }

  @override
  Future<void> selectCommunity(AddCommunityDeepLink value) async {
    community = value;
  }

  @override
  Future<bool> create(
    String name, {
    String instructions = '',
    Object? avatar,
  }) async {
    submittedName = name;
    submittedInstructions = instructions;
    if (creationGate case final gate?) {
      return run(() async {
        await gate.future;
        if (!succeed) throw StateError('Creation failed. Retry.');
      });
    }
    status = 'Creation failed. Retry.';
    return succeed;
  }
}

void main() {
  test(
    'account-wide agents require verified owner profiles on the current relay',
    () async {
      final owner = nostr.Keys('0' * 63 + '1');
      final here = nostr.Keys('0' * 63 + '2');
      final elsewhere = nostr.Keys('0' * 63 + '3');
      final forged = nostr.Keys('0' * 63 + '4');
      final keys = await registeredCommunityAgents(
        [
          for (final key in [here, elsewhere, forged])
            {'agent_pubkey': key.public},
        ],
        owner.public,
        (filter) async => [
          NostrEvent(
            id: 'here',
            pubkey: here.public,
            createdAt: 1,
            kind: 0,
            tags: [signOwnerAuthorization(owner, here.public)],
            content: '{}',
            sig: '',
          ),
          NostrEvent(
            id: 'forged',
            pubkey: forged.public,
            createdAt: 1,
            kind: 0,
            tags: [signOwnerAuthorization(owner, here.public)],
            content: '{}',
            sig: '',
          ),
        ],
      );
      expect(keys, {here.public});
    },
  );

  test(
    'remote availability overrides socket offline without changing local presence',
    () {
      final container = ProviderContainer(
        overrides: [
          presenceCacheProvider.overrideWith(_Presence.new),
          availableRemoteAgentsProvider.overrideWithValue({'remote'}),
        ],
      );
      addTearDown(container.dispose);
      expect(container.read(presentedPresenceProvider), {
        'remote': 'online',
        'local': 'away',
      });
      expect(container.read(presenceCacheProvider)['remote'], 'offline');
    },
  );

  testWidgets('agent detail pushes inside one modal and Back restores list', (
    tester,
  ) async {
    final account = BuilderlabAccountClient();
    final controller = _Controller(account);
    addTearDown(() {
      controller.dispose();
      controller.relayAuth.dispose();
      account.dispose();
    });
    final pubkey = 'a' * 64;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          agentDirectoryProvider.overrideWith(
            (ref) async => [AgentDirectoryEntry(pubkey: pubkey)],
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showPrototypeAgents(context, controller),
                child: const Text('Open Agents'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open Agents'));
    await tester.pumpAndSettle();
    final list = tester.element(find.byType(PrototypeAgentsSheet));
    await tester.tap(find.byKey(ValueKey(pubkey)));
    await tester.pump();
    for (var frame = 0; frame < 3; frame++) {
      await tester.pump(const Duration(milliseconds: 60));
      final surface = find.byKey(const ValueKey('agent-detail-surface'));
      expect(tester.widget<Material>(surface).color?.a, 1);
      expect(
        tester.getSize(surface),
        tester.getSize(find.byType(Navigator).last),
      );
      expect(tester.takeException(), isNull);
    }
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(find.byType(UserProfileSheet), findsOneWidget);
    expect(list.mounted, isTrue);
    await tester.tap(find.byTooltip('Back'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(
      tester
          .widget<Material>(find.byKey(const ValueKey('agent-detail-surface')))
          .color
          ?.a,
      1,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpAndSettle();
    expect(find.byType(UserProfileSheet), findsNothing);
    expect(find.byKey(ValueKey(pubkey)), findsOneWidget);
    expect(tester.element(find.byType(PrototypeAgentsSheet)), same(list));
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsNothing);
  });

  for (final succeeds in [true, false]) {
    testWidgets(
      'creation overlays retained list; only top modal progresses: $succeeds',
      (tester) async {
        final account = BuilderlabAccountClient();
        final gate = Completer<void>();
        final controller = _Controller(account)
          ..succeed = succeeds
          ..creationGate = gate;
        addTearDown(() {
          controller.dispose();
          controller.relayAuth.dispose();
          account.dispose();
        });
        final existing = 'a' * 64;
        final added = 'b' * 64;
        final community = Community.create(
          name: 'Test',
          relayUrl: 'wss://test.example',
          pubkey: 'owner',
        );
        var completed = false;
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              activeCommunityProvider.overrideWith((ref) async => community),
              agentDirectoryProvider.overrideWith(
                (ref) async => [
                  AgentDirectoryEntry(pubkey: existing),
                  if (completed && succeeds) AgentDirectoryEntry(pubkey: added),
                ],
              ),
            ],
            child: MaterialApp(
              theme: AppTheme.light(),
              home: Builder(
                builder: (context) => Scaffold(
                  body: TextButton(
                    onPressed: () => showPrototypeAgents(context, controller),
                    child: const Text('Open Agents'),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Open Agents'));
        await tester.pumpAndSettle();
        final list = tester.element(find.byType(PrototypeAgentsSheet));
        await tester.tap(find.byTooltip('Add agent'));
        await tester.pumpAndSettle();
        expect(find.byType(BottomSheet), findsNWidgets(2));
        expect(list.mounted, isTrue);
        final createContext = tester.element(
          find.byType(CreatePrototypeAgentSheet),
        );
        expect(
          Navigator.of(createContext),
          Navigator.of(createContext, rootNavigator: true),
        );
        expect(Navigator.of(list), isNot(Navigator.of(createContext)));
        await tester.enterText(find.widgetWithText(TextField, 'Name'), 'Scout');
        await tester.pump();
        await tester.tap(find.byTooltip('Create'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(controller.busy, isTrue);
        expect(find.byType(LinearProgressIndicator), findsOneWidget);
        expect(
          find.descendant(
            of: find.byType(PrototypeAgentsSheet),
            matching: find.byType(LinearProgressIndicator),
          ),
          findsNothing,
        );
        expect(find.byKey(ValueKey(existing)), findsOneWidget);
        expect(
          tester
              .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.check))
              .onPressed,
          isNull,
        );
        completed = true;
        gate.complete();
        await tester.pumpAndSettle();
        expect(find.byType(BottomSheet), findsNWidgets(succeeds ? 1 : 2));
        expect(tester.element(find.byType(PrototypeAgentsSheet)), same(list));
        if (succeeds) {
          expect(find.byKey(ValueKey(added)), findsOneWidget);
        } else {
          expect(find.text('Creation failed. Retry.'), findsOneWidget);
          expect(
            tester
                .widget<IconButton>(
                  find.widgetWithIcon(IconButton, Icons.check),
                )
                .onPressed,
            isNotNull,
          );
        }
      },
    );
  }

  for (final succeed in [true, false]) {
    testWidgets(
      'Create returns to list only after confirmed success: $succeed',
      (tester) async {
        final account = BuilderlabAccountClient();
        final controller = _Controller(account)..succeed = succeed;
        addTearDown(() {
          controller.dispose();
          controller.relayAuth.dispose();
          account.dispose();
        });
        final community = Community.create(
          name: 'Test community',
          relayUrl: 'wss://test.communities.public.builderlabstaging.xyz',
          pubkey: 'owner',
        );
        var refreshed = false;
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              activeCommunityProvider.overrideWith((ref) async => community),
            ],
            child: MaterialApp(
              theme: AppTheme.light(),
              home: Builder(
                builder: (context) => Scaffold(
                  body: TextButton(
                    onPressed: () => showModalBottomSheet<void>(
                      context: context,
                      isScrollControlled: true,
                      builder: (_) => CreatePrototypeAgentSheet(
                        controller: controller,
                        community: community,
                        onCreated: () => refreshed = true,
                      ),
                    ),
                    child: const Text('Agents list'),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Agents list'));
        await tester.pumpAndSettle();
        await tester.enterText(find.widgetWithText(TextField, 'Name'), 'Scout');
        await tester.enterText(
          find.widgetWithText(TextField, 'Instructions'),
          'Reply concisely.',
        );
        await tester.pump();
        await tester.tap(find.byTooltip('Create'));
        await tester.pumpAndSettle();
        expect(controller.submittedName, 'Scout');
        expect(controller.submittedInstructions, 'Reply concisely.');
        expect(controller.community?.relayUrl, community.relayUrl);
        expect(refreshed, succeed);
        expect(
          find.text('Create agent'),
          succeed ? findsNothing : findsOneWidget,
        );
        if (!succeed) {
          expect(find.text('Creation failed. Retry.'), findsOneWidget);
        }
      },
    );
  }
}
