import 'dart:convert';
import 'dart:io';

import 'package:buzz/prototype/remote_agent_controller.dart';
import 'package:buzz/shared/deeplink/deep_link.dart';
import 'package:buzz/shared/emoji/emoji_avatar.dart';
import 'package:buzz/shared/hosted/account_identity_store.dart';
import 'package:buzz/shared/hosted/browser_auth.dart';
import 'package:buzz/shared/hosted/hosted_relay_auth.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nostr/nostr.dart' as nostr;
import 'package:shared_preferences/shared_preferences.dart';

import 'remote_agent_controller_test.dart' show BoundAccount;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'signed avatar definition links to the owner policy without instructions',
    () async {
      FlutterSecureStorage.setMockInitialValues({});
      SharedPreferences.setMockInitialValues({});
      final owner = nostr.Keys('0' * 63 + '1');
      final agent = nostr.Keys('0' * 63 + '2');
      final store = AccountIdentityStore().forSubject('prototype-owner');
      await store.create(owner.nsec);
      final account = BoundAccount(owner.public);
      final auth = HostedRelayAuth(account);
      final controller = RemoteAgentController(
        account: account,
        browser: BrowserAuth(),
        keys: AccountIdentityStore(),
        relayAuth: auth,
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final sockets = <WebSocket>[];
      final events = <Map<String, dynamic>>[];
      final connections = server.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        sockets.add(socket);
        socket.add(jsonEncode(['AUTH', 'avatar-fixture']));
        socket.listen((raw) {
          final frame = jsonDecode(raw as String) as List;
          final event = Map<String, dynamic>.from(frame[1] as Map);
          if (frame.first == 'EVENT') events.add(event);
          socket.add(jsonEncode(['OK', event['id'], true, '']));
        });
      });
      addTearDown(() async {
        controller.dispose();
        auth.dispose();
        account.dispose();
        for (final socket in sockets) {
          await socket.close();
        }
        await connections.cancel();
        await server.close(force: true);
      });
      final selected = AddCommunityDeepLink(
        name: 'Local fixture',
        relayUrl: 'ws://127.0.0.1:${server.port}',
      );
      final setup = {
        'name': 'Owl',
        'pubkey': agent.public,
        'request': 'same-request',
        'instructions': 'Private runtime instructions',
        'avatar': {'emoji': '🦉', 'color': '#476CFF'},
      };
      await controller.publishAvatarDefinition(selected, setup);
      await controller.publishPolicy(selected, setup);
      expect(events.map((event) => event['kind']), [30175, 30177]);
      expect(events.every((event) => event['pubkey'] == owner.public), isTrue);
      expect(
        events.every((event) => nostr.Event.fromMap(event).isValid()),
        isTrue,
      );
      expect(events[0]['tags'], [
        ['d', 'qr-same-request'],
      ]);
      final definition = jsonDecode(events[0]['content'] as String) as Map;
      expect(
        parseEmojiAvatarDataUrl(definition['avatar_url'] as String)?.emoji,
        '🦉',
      );
      final policy = jsonDecode(events[1]['content'] as String) as Map;
      expect(policy['persona_id'], 'qr-same-request');
      expect(events[1]['tags'], contains(equals(['d', agent.public])));
      expect(
        jsonEncode(events),
        isNot(contains('Private runtime instructions')),
      );
    },
  );
}
