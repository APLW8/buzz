import 'dart:convert';
import 'package:buzz/shared/relay/relay.dart';
import 'package:buzz/shared/emoji/emoji_avatar.dart';
import 'package:buzz/prototype/remote_agent_controller.dart';
import 'package:buzz/shared/deeplink/deep_link.dart';
import 'package:buzz/shared/hosted/account_identity_store.dart';
import 'package:buzz/shared/hosted/browser_auth.dart';
import 'package:buzz/shared/hosted/hosted_environment.dart';
import 'package:buzz/shared/hosted/hosted_relay_auth.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nostr/nostr.dart' as nostr;
import 'package:shared_preferences/shared_preferences.dart';

import 'remote_agent_controller_test.dart' show BoundAccount;

class _Registry extends BoundAccount {
  _Registry(super.pubkey);
  final calls = <String>[];
  final bodies = <String, Map<String, dynamic>>{};
  bool failInstructions = true;
  @override
  Future<Map<String, dynamic>> post(
    String path,
    Map<String, dynamic> body,
  ) async {
    calls.add(path.split('/').last);
    bodies[path] = body;
    switch (path) {
      case '/v3/beekeeper/register-agent':
        return {
          'status': 1,
          'agent_pubkey': nostr.Keys('0' * 63 + '2').public,
          'agent_id': 'agent',
        };
      case '/v3/beekeeper/attest-agent':
        return {'status': 1};
      case '/v3/beekeeper/update-agent':
        if (failInstructions) throw StateError('instructions unavailable');
        return {};
      case '/v3/beekeeper/add-buzz-subscription':
        return {'status': 1};
      default:
        throw StateError('Unexpected request: $path');
    }
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
  Object? publishedAvatar;
  @override
  Future<void> publishAvatarDefinition(
    AddCommunityDeepLink selected,
    Map<String, dynamic> setup,
  ) async {
    publishedAvatar = setup['avatar'];
    (account as _Registry).calls.add('publish-avatar');
  }

  @override
  Future<void> refresh() async {}
  @override
  Future<void> publishPolicy(
    AddCommunityDeepLink selected,
    Map<String, dynamic> setup,
  ) async {
    (account as _Registry).calls.add('publish-policy');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'a fresh controller restores definition avatar through owner instance linkage',
    () async {
      final key = nostr.Keys('0' * 63 + '1');
      final pubkey = nostr.Keys('0' * 63 + '2').public;
      final account = _Registry(key.public);
      final controller = _Controller(account, AccountIdentityStore())
        ..owner = key.public
        ..agents = [
          {'agent_pubkey': pubkey},
        ];
      addTearDown(() {
        controller.dispose();
        controller.relayAuth.dispose();
        account.dispose();
      });
      final url = emojiAvatarDataUrl('🦉', 0xff476cff);
      final requests = <int>[];
      await controller.restoreDefinitionAvatars((filter) async {
        requests.add(filter.kinds.single);
        expect(filter.authors, [key.public]);
        final instance = filter.kinds.single == 30177;
        expect(filter.tags['#d'], instance ? [pubkey] : ['qr-demo']);
        return [
          NostrEvent(
            id: instance ? 'instance' : 'definition',
            pubkey: key.public,
            createdAt: 1,
            kind: filter.kinds.single,
            tags: [
              ['d', instance ? pubkey : 'qr-demo'],
            ],
            content: jsonEncode(
              instance ? {'persona_id': 'qr-demo'} : {'avatar_url': url},
            ),
            sig: '',
          ),
        ];
      });
      expect(requests, [30177, 30175]);
      expect(controller.avatarUrls, {pubkey: url});
      expect(
        parseEmojiAvatarDataUrl(controller.avatarUrls[pubkey])?.emoji,
        '🦉',
      );
    },
  );

  test(
    'instructions follow activation; failed update resumes same identity before subscription',
    () async {
      FlutterSecureStorage.setMockInitialValues({});
      SharedPreferences.setMockInitialValues({});
      final key = nostr.Keys('0' * 63 + '1');
      final keys = AccountIdentityStore();
      await keys.create(key.nsec);
      final account = _Registry(key.public);
      final controller = _Controller(account, keys)
        ..community = AddCommunityDeepLink(
          name: 'Test',
          relayUrl: 'wss://test.${HostedEnvironment.communitySuffix}',
        );
      addTearDown(() {
        controller.dispose();
        controller.relayAuth.dispose();
        account.dispose();
      });
      expect(
        await controller.create('Scout', instructions: 'x' * 20001),
        isFalse,
      );
      expect(account.calls, isEmpty);
      expect(controller.pending, isNull);
      expect(
        await controller.create(
          'Scout',
          instructions: 'Reply concisely.',
          avatar: const {'emoji': '🦉', 'color': '#476CFF'},
        ),
        isFalse,
      );
      expect(account.calls, ['register-agent', 'attest-agent', 'update-agent']);
      expect(controller.pending?['id'], 'agent');
      expect(controller.pending?['instructions'], 'Reply concisely.');
      final prefs = await SharedPreferences.getInstance();
      final scope =
          'remote-prototype:${HostedEnvironment.origin.host}:prototype-owner';
      expect(prefs.getString('$scope:pending'), isNotNull);
      expect(
        prefs.getString('$scope:pending'),
        isNot(contains('Reply concisely.')),
      );
      expect(prefs.getKeys().any((key) => key.startsWith('null:')), isFalse);
      account.failInstructions = false;
      expect(
        await controller.create(
          'Other name',
          instructions: 'Other instructions',
        ),
        isTrue,
      );
      expect(account.calls, [
        'register-agent',
        'attest-agent',
        'update-agent',
        'attest-agent',
        'update-agent',
        'add-buzz-subscription',
        'publish-avatar',
        'publish-policy',
      ]);
      expect(
        account.bodies['/v3/beekeeper/update-agent']?['agent_instructions'],
        'Reply concisely.',
      );
      expect(controller.publishedAvatar, {'emoji': '🦉', 'color': '#476CFF'});
      final persistedAvatars = prefs.getString('$scope:avatars');
      expect(persistedAvatars, contains('data:image/svg+xml'));
      expect(persistedAvatars, isNot(contains('Reply concisely.')));
      expect(controller.pending, isNull);
    },
  );
}
