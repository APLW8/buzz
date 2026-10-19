import 'package:buzz/prototype/agents_sheet.dart';
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
  @override
  Future<void> ensureBinding() async {
    owner = 'owner';
  }

  @override
  Future<void> selectCommunity(AddCommunityDeepLink value) async {
    community = value;
  }

  @override
  Future<bool> create(String name, {String instructions = ''}) async {
    submittedName = name;
    submittedInstructions = instructions;
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
        await tester.enterText(
          find.widgetWithText(TextField, 'Display name'),
          'Scout',
        );
        await tester.enterText(
          find.widgetWithText(TextField, 'Instructions (optional)'),
          'Reply concisely.',
        );
        await tester.pump();
        await tester.tap(find.text('Create'));
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
