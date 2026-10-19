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
    'instructions follow activation; failed update resumes same identity before subscription',
    () async {
      FlutterSecureStorage.setMockInitialValues({});
      SharedPreferences.setMockInitialValues({});
      final key = nostr.Keys('0' * 63 + '1');
      final keys = AccountIdentityStore();
      await keys.create(key.nsec);
      final account = _Registry(key.public);
      final controller = _Controller(account, keys)
        ..community = const AddCommunityDeepLink(
          name: 'Test',
          relayUrl: 'wss://test.communities.public.builderlabstaging.xyz',
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
        await controller.create('Scout', instructions: 'Reply concisely.'),
        isFalse,
      );
      expect(account.calls, ['register-agent', 'attest-agent', 'update-agent']);
      expect(controller.pending?['id'], 'agent');
      expect(controller.pending?['instructions'], 'Reply concisely.');
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getString('null:pending'),
        isNot(contains('Reply concisely.')),
      );
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
        'publish-policy',
      ]);
      expect(
        account.bodies['/v3/beekeeper/update-agent']?['agent_instructions'],
        'Reply concisely.',
      );
      expect(controller.pending, isNull);
    },
    skip: HostedEnvironment.origin.host != 'app.builderlabstaging.xyz'
        ? 'Run with the staging build define.'
        : false,
  );
}
