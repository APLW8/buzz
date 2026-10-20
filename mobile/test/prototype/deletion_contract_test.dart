import 'package:buzz/prototype/remote_agent_controller.dart';
import 'package:buzz/prototype/delete_agent_action.dart';
import 'package:buzz/shared/community/community.dart';
import 'package:buzz/shared/community/community_provider.dart';
import 'package:buzz/shared/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:buzz/shared/deeplink/deep_link.dart';
import 'package:buzz/shared/hosted/account_identity_store.dart';
import 'package:buzz/shared/hosted/browser_auth.dart';
import 'package:buzz/shared/hosted/hosted_relay_auth.dart';
import 'package:buzz/shared/relay/relay.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nostr/nostr.dart' as nostr;
import 'package:shared_preferences/shared_preferences.dart';

import 'remote_agent_controller_test.dart' show BoundAccount;

class _Registry extends BoundAccount {
  _Registry(super.pubkey);
  final calls = <String>[];
  int result = 2;
  @override
  Future<Map<String, dynamic>> post(
    String path,
    Map<String, dynamic> body,
  ) async {
    expect(path, '/v3/beekeeper/delete-agent');
    expect(body, {'agent_id': 'remote-id'});
    calls.add('delete-runtime');
    return {'status': result};
  }
}

class _Controller extends RemoteAgentController {
  _Controller(_Registry account, AccountIdentityStore keys)
    : super(
        account: account,
        browser: BrowserAuth(),
        keys: keys,
        relayAuth: HostedRelayAuth(account),
      );
  bool rejectPolicy = false;
  @override
  Future<void> removePolicy(
    AddCommunityDeepLink selected,
    String pubkey,
  ) async {
    (account as _Registry).calls.add('remove-registration');
    if (rejectPolicy) throw StateError('Relay rejected deletion');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'owned remote deletion requires confirmation; local agents have no action',
    (tester) async {
      final owner = nostr.Keys('0' * 63 + '1');
      final agent = nostr.Keys('0' * 63 + '2').public;
      final registry = _Registry(owner.public);
      final controller = _Controller(registry, AccountIdentityStore())
        ..owner = owner.public
        ..agents = [
          {
            'agent_pubkey': agent,
            'agent_id': 'remote-id',
            'agent_name': 'Scout',
          },
        ];
      addTearDown(() {
        controller.dispose();
        controller.relayAuth.dispose();
        registry.dispose();
      });
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            activeCommunityProvider.overrideWith(
              (ref) async => Community.create(
                name: 'Test',
                relayUrl: 'wss://test.example',
                pubkey: owner.public,
              ),
            ),
          ],
          child: MaterialApp(
            theme: AppTheme.light(),
            home: Scaffold(
              body: Column(
                children: [
                  DeleteAgentAction(controller: controller, pubkey: agent),
                  DeleteAgentAction(controller: controller, pubkey: 'local'),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Delete agent'), findsOneWidget);
      await tester.tap(find.text('Delete agent'));
      await tester.pumpAndSettle();
      expect(find.text('Delete Scout?'), findsOneWidget);
      expect(registry.calls, isEmpty);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(registry.calls, isEmpty);
      expect(controller.agents, hasLength(1));
    },
  );

  test(
    'deletion requires confirmed registration absence; disabled runtime stays retryable',
    () async {
      FlutterSecureStorage.setMockInitialValues({});
      SharedPreferences.setMockInitialValues({});
      final owner = nostr.Keys('0' * 63 + '1');
      final agent = nostr.Keys('0' * 63 + '2').public;
      final keys = AccountIdentityStore();
      await keys.create(owner.nsec);
      final registry = _Registry(owner.public);
      final controller = _Controller(registry, keys)
        ..agents = [
          {'agent_pubkey': agent, 'agent_id': 'remote-id'},
        ];
      addTearDown(() {
        controller.dispose();
        controller.relayAuth.dispose();
        registry.dispose();
      });
      var registrationExists = true;
      var current = true;
      Future<bool> remove() => controller.deleteAgent(
        pubkey: agent,
        selected: const AddCommunityDeepLink(
          name: 'Test',
          relayUrl: 'wss://test.example',
        ),
        communityOwner: owner.public,
        isCurrent: () => current,
        fetch: (filter) async {
          registry.calls.add('read-registration');
          expect(filter.kinds, [30177]);
          expect(filter.authors, [owner.public]);
          expect(filter.tags, {
            '#d': [agent],
          });
          return registrationExists
              ? [
                  NostrEvent(
                    id: 'registration',
                    pubkey: owner.public,
                    createdAt: 1,
                    kind: 30177,
                    tags: [
                      ['d', agent],
                    ],
                    content: '{}',
                    sig: '',
                  ),
                ]
              : [];
        },
      );
      controller.rejectPolicy = true;
      expect(await remove(), isFalse);
      expect(registry.calls, ['remove-registration']);
      registry.calls.clear();
      controller.rejectPolicy = false;
      expect(await remove(), isFalse);
      expect(registry.calls, ['remove-registration', 'read-registration']);
      registry.calls.clear();
      registrationExists = false;
      expect(await remove(), isFalse);
      expect(controller.status, contains('disabled'));
      expect(controller.agents, hasLength(1));
      expect(controller.deletedAgents, isEmpty);
      registry.calls.clear();
      current = false;
      expect(await remove(), isFalse);
      expect(registry.calls, isEmpty);
      current = true;
      registry.result = 3; // Already missing also confirms a retry.
      expect(await remove(), isTrue);
      expect(registry.calls, [
        'remove-registration',
        'read-registration',
        'delete-runtime',
      ]);
      expect(controller.agents, isEmpty);
      expect(controller.deletedAgents, {agent});
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getKeys().where((key) => key.endsWith(':deleting')),
        hasLength(1),
      );
      expect(
        prefs.getStringList(
          prefs.getKeys().singleWhere((key) => key.endsWith(':deleting')),
        ),
        [agent],
      );
    },
  );
}
