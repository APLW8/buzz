import 'package:buzz/shared/community/community.dart';
import 'package:buzz/shared/community/community_storage.dart';
import 'package:buzz/shared/deeplink/deep_link.dart';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:buzz/shared/hosted/account_identity_store.dart';
import 'package:buzz/shared/hosted/builderlab_account.dart';
import 'package:buzz/shared/hosted/browser_auth.dart';
import 'package:buzz/shared/hosted/hosted_environment.dart';
import 'package:buzz/shared/hosted/hosted_relay_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:nostr/nostr.dart' as nostr;
import 'package:buzz/prototype/remote_agent_controller.dart';
import 'package:buzz/shared/crypto/nip_oa.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });
  test(
    'late account sign-in refreshes agents in a joined non-owned community',
    () async {
      final key = nostr.Keys('0' * 63 + '1');
      final store = AccountIdentityStore();
      final account = _LateAccount(key.public);
      final browser = _LocalBrowser();
      final auth = HostedRelayAuth(account);
      final controller = RemoteAgentController(
        account: account,
        browser: browser,
        keys: store,
        relayAuth: auth,
      );
      addTearDown(() {
        controller.dispose();
        auth.dispose();
        account.dispose();
      });
      await controller.initialize();
      expect(browser.initialized, isTrue);
      expect(controller.status, 'Sign in to your BuilderLab account.');
      expect(account.routes, isEmpty);

      // Normal hosted onboarding owns login and persists the existing key in
      // its account slot. The prototype must consume that same slot.
      account.signedIn = true;
      await store.forSubject('prototype-owner').create(key.nsec);
      final joined = Community.create(
        name: 'Invited event',
        relayUrl: 'wss://event.${HostedEnvironment.communitySuffix}',
        pubkey: key.public,
        nsec: key.nsec,
      );
      await CommunityStorage().save(joined);
      await controller.selectCommunity(
        AddCommunityDeepLink(name: joined.name, relayUrl: joined.relayUrl),
      );
      await controller.refresh();
      expect(account.routes, ['/v3/beekeeper/list-agents']);
      expect(controller.owner, key.public);
      expect(controller.community?.relayUrl, joined.relayUrl);
      expect(controller.communities.single.relayUrl, joined.relayUrl);
      expect(controller.agents.single['agent_name'], 'Existing remote');
      expect(await store.read(), isNull);
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getString(
          'remote-prototype:${HostedEnvironment.origin.host}:prototype-owner:community',
        ),
        joined.relayUrl,
      );
      expect(prefs.getKeys().any((key) => key.startsWith('null:')), isFalse);
    },
  );
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

  for (final matching in [true, false]) {
    test('saved community preserves identity; matching=$matching', () async {
      final key = nostr.Keys('0' * 63 + '1');
      final other = nostr.Keys('0' * 63 + '2');
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
      final savedKey = matching ? key : other;
      final saved = Community.create(
        name: 'prototype',
        relayUrl: 'wss://prototype.communities.public.builderlabstaging.xyz',
        nsec: savedKey.nsec,
        pubkey: savedKey.public,
      );
      final storage = CommunityStorage();
      await storage.save(saved);
      controller.owner = key.public;
      controller.community = AddCommunityDeepLink(
        name: saved.name,
        relayUrl: saved.relayUrl,
      );
      if (matching) {
        await controller.saveCommunity();
        expect(await storage.loadActiveId(), saved.id);
      } else {
        await expectLater(
          controller.saveCommunity(),
          throwsA(AccountIdentityFailure.mismatch),
        );
        expect(await storage.loadActiveId(), isNull);
      }
      expect((await storage.loadAll()).single.nsec, savedKey.nsec);
      expect(
        (await store.forSubject('prototype-owner').read())!.pubkey,
        key.public,
      );
      controller.dispose();
      auth.dispose();
      account.dispose();
    });
  }
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

class _LocalBrowser extends BrowserAuth {
  bool initialized = false;
  @override
  Future<void> initialize() async => initialized = true;
}

class _LateAccount extends BuilderlabAccountClient {
  _LateAccount(this.pubkey);
  final String pubkey;
  bool signedIn = false;
  final routes = <String>[];
  @override
  BuilderlabAccount? get account => signedIn
      ? BuilderlabAccount(
          subject: 'prototype-owner',
          expiresAt: DateTime.utc(2030),
        )
      : null;
  @override
  Future<BuilderlabAccount?> restore() async => account;
  @override
  Future<Map<String, dynamic>> currentIdentity() async => {
    'identity': {'pubkey_hex': pubkey},
  };
  @override
  Future<Map<String, dynamic>> post(
    String path,
    Map<String, dynamic> body,
  ) async {
    routes.add(path);
    if (path != '/v3/beekeeper/list-agents') {
      throw StateError('Agent refresh must not require community ownership.');
    }
    return {
      'status': 1,
      'agents': [
        {
          'agent_pubkey': nostr.Keys('0' * 63 + '2').public,
          'agent_name': 'Existing remote',
        },
      ],
    };
  }
}
