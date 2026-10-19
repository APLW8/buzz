import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:buzz/shared/hosted/account_identity_store.dart';
import 'package:buzz/shared/hosted/builderlab_account.dart';
import 'package:buzz/shared/hosted/browser_auth.dart';
import 'package:buzz/shared/hosted/hosted_relay_auth.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:nostr/nostr.dart' as nostr;
import 'package:buzz/prototype/remote_agent_controller.dart';
import 'package:buzz/shared/crypto/nip_oa.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));
  test(
    'verified binding migrates legacy key without replacing original',
    () async {
      final key = nostr.Keys('0' * 63 + '1');
      final store = AccountIdentityStore();
      await store.create(key.nsec);
      final account = BoundAccount(key.public);
      final auth = HostedRelayAuth(account);
      final controller = RemoteAgentController(
        account: account,
        browser: BrowserAuth(),
        keys: store,
        relayAuth: auth,
      );
      await controller.adoptBoundIdentity();
      expect(
        (await store.forSubject('prototype-owner').read())!.pubkey,
        key.public,
      );
      expect((await store.read())!.pubkey, key.public);
      expect((await controller.keys.read())!.backup, isNull);
      controller.dispose();
      auth.dispose();
      account.dispose();
    },
  );
  test('different bound identity cannot acquire legacy key', () async {
    final key = nostr.Keys('0' * 63 + '1');
    final other = nostr.Keys('0' * 63 + '2');
    final store = AccountIdentityStore();
    await store.create(key.nsec);
    final account = BoundAccount(other.public);
    final auth = HostedRelayAuth(account);
    final controller = RemoteAgentController(
      account: account,
      browser: BrowserAuth(),
      keys: store,
      relayAuth: auth,
    );
    await expectLater(
      controller.adoptBoundIdentity(),
      throwsA(AccountIdentityFailure.absent),
    );
    expect(await store.forSubject('prototype-owner').read(), isNull);
    expect((await store.read())!.pubkey, key.public);
    controller.dispose();
    auth.dispose();
    account.dispose();
  });

  test('owner proof verifies for only the provisioned agent key', () {
    final owner = nostr.Keys('0' * 63 + '1');
    final agent = nostr.Keys('0' * 63 + '2');
    final other = nostr.Keys('0' * 63 + '3');
    final auth = signOwnerAuthorization(owner, agent.public);
    expect(verifiedOaOwnerPubkey([auth], agent.public), owner.public);
    expect(verifiedOaOwnerPubkey([auth], other.public), isNull);
    expect(() => signOwnerAuthorization(owner, owner.public), throwsStateError);
  });
  test('backend disabled and missing statuses cannot count as activation', () {
    requireStatus({'status': 'ATTEST_AGENT_STATUS_ACTIVE'}, 'ACTIVE', 1);
    requireStatus({'status': 1}, 'ACTIVE', 1);
    expect(
      () => requireStatus(
        {'status': 'ATTEST_AGENT_STATUS_FEATURE_DISABLED'},
        'ACTIVE',
        1,
      ),
      throwsStateError,
    );
    expect(() => requireStatus({}, 'ACTIVE', 1), throwsStateError);
  });
}

class BoundAccount extends BuilderlabAccountClient {
  BoundAccount(this.pubkey);
  final String pubkey;
  @override
  BuilderlabAccount get account => BuilderlabAccount(
    subject: 'prototype-owner',
    expiresAt: DateTime.utc(2030),
  );
  @override
  Future<Map<String, dynamic>> currentIdentity() async => {
    'identity': {'pubkey_hex': pubkey},
  };
}
