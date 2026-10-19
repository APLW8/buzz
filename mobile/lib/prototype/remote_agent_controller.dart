import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:nostr/nostr.dart' as nostr;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../shared/community/community.dart';
import '../shared/community/community_storage.dart';
import '../shared/deeplink/deep_link.dart';
import '../shared/hosted/account_identity_store.dart';
import '../shared/hosted/browser_auth.dart';
import '../shared/hosted/builderlab_account.dart';
import '../shared/hosted/hosted_communities.dart';
import '../shared/hosted/hosted_environment.dart';
import '../shared/hosted/web_connect_binding.dart';
import '../shared/relay/signed_event_relay.dart';

/// Staging-only experiment using the same account and Beekeeper contracts as desktop.
class RemoteAgentController extends ChangeNotifier {
  RemoteAgentController({
    required this.account,
    required this.browser,
    required this.keys,
  });
  final BuilderlabAccountClient account;
  final BrowserAuth browser;
  final AccountIdentityStore keys;
  final _subscriptions = <StreamSubscription<dynamic>>[];
  bool busy = false;
  int _operation = 0;
  String status = 'Loading saved sign-in…';
  String? owner;
  List<AddCommunityDeepLink> communities = [];
  AddCommunityDeepLink? community;
  List<Map<String, dynamic>> agents = [];
  Map<String, dynamic>? pending;
  String? _scope;

  Future<void> initialize() async {
    if (HostedEnvironment.origin.host != 'app.builderlabstaging.xyz') {
      throw StateError(
        'This prototype requires the staging build configuration.',
      );
    }
    _subscriptions.add(
      browser.codes.listen((code) {
        busy = false;
        unawaited(
          run(() async {
            await account.exchange(code: code.code, verifier: code.verifier);
            await refresh();
          }),
        );
      }),
    );
    _subscriptions.add(
      browser.failures.listen((failure) {
        busy = false;
        status = 'Sign-in did not finish: ${failure.name}. Try again.';
        notifyListeners();
      }),
    );
    await run(() async {
      await browser.initialize();
      await account.restore();
      await refresh();
    });
  }

  Future<void> run(Future<void> Function() action) async {
    if (busy) return;
    busy = true;
    final operation = ++_operation;
    notifyListeners();
    try {
      await action();
    } catch (error) {
      // Account failures never carry credentials or response bodies.
      status = error is AccountFailure
          ? 'BuilderLab: ${error.name}. ${error == AccountFailure.signedOut ? 'Sign in again.' : 'Your session is retained.'}'
          : error is AccountIdentityFailure
          ? 'Buzz identity: ${error.name}.'
          : error is StateError
          ? error.message.toString()
          : 'Operation failed (${error.runtimeType}). Retry the same setup.';
    } finally {
      if (operation == _operation) {
        busy = false;
        notifyListeners();
      }
    }
  }

  Future<void> signIn() => run(() async {
    status =
        'Waiting for Mac Chrome. Open http://127.0.0.1:18763/start '
        'on your Mac, then sign in to your public staging account. '
        'This attempt expires after 10 minutes.';
    notifyListeners();
    await browser.start({'type': 'remote-prototype'});
  });

  Future<void> refresh() async {
    owner = (await keys.read())?.pubkey;
    final session = account.account;
    if (session == null) {
      status = 'Sign in to your staging BuilderLab account.';
      return;
    }
    _scope =
        'remote-prototype:${HostedEnvironment.origin.host}:${session.subject}';
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('$_scope:pending');
    pending = raw == null
        ? null
        : Map<String, dynamic>.from(jsonDecode(raw) as Map);
    if (owner == null) {
      status = 'Import your existing Buzz identity to discover communities.';
      return;
    }
    await ensureBinding();
    communities = await loadHostedCommunities(account);
    final selected =
        pending?['community'] ?? prefs.getString('$_scope:community');
    community = communities.where((c) => c.relayUrl == selected).firstOrNull;
    if (community == null && communities.length == 1) {
      community = communities.single;
    }
    final result = await account.post('/v3/beekeeper/list-agents', {});
    requireStatus(result, 'SUCCESS', 1);
    final rows = result['agents'] ?? [];
    if (rows is! List) throw StateError('Invalid agent listing.');
    agents = rows.map((row) => Map<String, dynamic>.from(row as Map)).toList();
    status = pending == null
        ? 'Signed in. Choose a community and create an agent.'
        : 'Unfinished setup saved. Resume to use the same agent.';
  }

  Future<void> createTestCommunity() => run(() async {
    await ensureBinding();
    final response = await account.post('/v1/buzz/communities', {
      'name': 'tomb-remote-prototype-20261016',
    });
    if (response['error'] != null) {
      throw StateError('Staging community creation was not confirmed.');
    }
    await refresh();
    if (communities.isEmpty) {
      throw StateError(
        'Created community is not available yet. Refresh to retry discovery.',
      );
    }
  });

  Future<void> selectCommunity(AddCommunityDeepLink value) async {
    if (pending != null) {
      throw StateError('Finish the pending agent before changing community.');
    }
    community = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('$_scope:community', value.relayUrl);
    notifyListeners();
  }

  Future<void> ensureBinding() async {
    final subject = account.account?.subject;
    final identity = await keys.read();
    if (subject == null || identity == null) {
      throw StateError(
        'Sign in and transfer your existing Buzz identity first.',
      );
    }
    final current = await account.currentIdentity();
    final bound = (current['identity'] as Map?)?['pubkey_hex'];
    if (bound == identity.pubkey) return;
    if (bound != null) {
      throw StateError(
        'This account is bound to a different Buzz identity. Nothing was replaced.',
      );
    }
    if (current['error'] != null &&
        (current['error'] as Map)['setup_needed'] != true) {
      throw StateError(
        'BuilderLab could not verify the existing identity binding.',
      );
    }
    final challenge = await account.post(
      '/v1/buzz/nostr-identities/challenge',
      {'origin': HostedEnvironment.origin.toString()},
    );
    final fields = <String, String>{
      'audience': 'buzz:nostr-identity',
      'action': 'bind_nostr_identity',
      'protocol': 'buzz-nostr-identity',
      'version': '1',
      'return': 'browser_fragment_v1',
      'callback_url': HostedEnvironment.origin.resolve('/buzz').toString(),
    };
    for (final field in [
      'challenge_id',
      'nonce',
      'verification_code',
      'origin',
      'expires_at',
    ]) {
      if (challenge[field] is! String) {
        throw StateError('Invalid identity challenge.');
      }
      fields[field] = challenge[field] as String;
    }
    final request = parseNostrBindDeepLink(
      Uri(scheme: 'buzz', host: 'nostr-bind', queryParameters: fields),
    );
    if (request == null) throw StateError('Invalid identity challenge.');
    await WebConnectBindingService().complete(
      request: request,
      subject: subject,
      expectedPubkey: identity.pubkey,
      withKeys: keys.withKeys,
      verify:
          ({
            required subject,
            required challengeId,
            required nonce,
            required signedPayload,
          }) async {
            if (account.account?.subject != subject) {
              throw StateError('Account changed.');
            }
            final result = await account
                .post('/v1/buzz/nostr-identities/verify', {
                  'challenge_id': challengeId,
                  'nonce': nonce,
                  'signed_payload': signedPayload,
                });
            final key = (result['identity'] as Map?)?['pubkey_hex'];
            if (key is! String) {
              throw StateError('Identity binding was not confirmed.');
            }
            return key;
          },
    );
  }

  Future<void> _savePending(Map<String, dynamic> value) async {
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.setString('$_scope:pending', jsonEncode(value))) {
      throw StateError('Could not save unfinished setup.');
    }
    pending = value;
  }

  Future<void> create(String name) => run(() async {
    final selected = community;
    if (selected == null) {
      throw StateError('Choose an existing staging community.');
    }
    if (!HostedEnvironment.supportsRelay(Uri.parse(selected.relayUrl))) {
      throw StateError('Unsupported community.');
    }
    await ensureBinding();
    if (pending == null) {
      final trimmed = name.trim();
      if (!RegExp(r'^[\w .-]{1,64}$').hasMatch(trimmed)) {
        throw StateError(
          'Use 1–64 letters, numbers, spaces, dots, hyphens or underscores.',
        );
      }
      await _savePending({
        'name': trimmed,
        'community': selected.relayUrl,
        'owner': owner,
        'request': const Uuid().v4(),
      });
    }
    var setup = Map<String, dynamic>.from(pending!);
    if (setup['owner'] != owner || setup['community'] != selected.relayUrl) {
      throw StateError('Resume using the original identity and community.');
    }
    if (setup['pubkey'] == null) {
      status = 'Creating remote identity…';
      notifyListeners();
      final result = await account.post('/v3/beekeeper/register-agent', {
        'agent_name': setup['name'],
        'idempotency_key': setup['request'],
      });
      requireStatus(result, 'UNATTESTED', 1);
      final pubkey = result['agent_pubkey'];
      if (pubkey is! String ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(pubkey) ||
          result['agent_id'] is! String) {
        throw StateError('Invalid registration response. Retry this setup.');
      }
      setup = {...setup, 'pubkey': pubkey, 'id': result['agent_id']};
      await _savePending(setup);
    }
    final pubkey = setup['pubkey'] as String;
    status = 'Authorizing and activating agent…';
    notifyListeners();
    final auth = await keys.withKeys(
      (key) async => signOwnerAuthorization(key, pubkey),
    );
    final result = await account.post('/v3/beekeeper/attest-agent', {
      'agent_pubkey': pubkey,
      'owner_auth_tag_json': jsonEncode(auth),
      'community_url': selected.relayUrl,
    });
    requireStatus(result, 'ACTIVE', 1);
    await subscribe(setup['id'] as String);
    await keys.withKeys((key) async {
      await submitSignedEventOnce(
        wsUrl: selected.relayUrl,
        nsec: key.nsec,
        kind: 30177,
        content: jsonEncode({
          'name': setup['name'],
          'parallelism': 1,
          'respond_to': 'owner-only',
        }),
        tags: [
          ['d', pubkey],
          ['runtime', 'block.builderlab/builderlab'],
        ],
      );
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('$_scope:pending');
    pending = null;
    await refresh();
    status =
        '${setup['name']} is active. Open Buzz and mention it in a channel.';
  });

  Future<void> subscribe(String agentId) async {
    final selected = community;
    if (selected == null) throw StateError('Choose a community first.');
    final result = await account.post('/v3/beekeeper/add-buzz-subscription', {
      'agent_id': agentId,
      'community': Uri.parse(selected.relayUrl).host,
    });
    final value = result['status'];
    if (value != 1 &&
        value != 2 &&
        value != 'ADD_BUZZ_SUBSCRIPTION_STATUS_CREATED' &&
        value != 'ADD_BUZZ_SUBSCRIPTION_STATUS_ALREADY_EXISTS') {
      throw StateError('Community subscription was not confirmed ($value).');
    }
    status = 'Agent subscribed to ${selected.name}. Mention it in Buzz.';
  }

  Future<void> saveCommunity() async {
    final selected = community;
    if (selected == null) throw StateError('Choose a community first.');
    await keys.withKeys((key) async {
      final storage = CommunityStorage();
      final existing = (await storage.loadAll())
          .where((c) => c.relayUrl == selected.relayUrl)
          .firstOrNull;
      if (existing != null && existing.pubkey != key.public) {
        throw StateError('Saved community has another identity.');
      }
      final saved =
          existing ??
          Community.create(
            name: selected.name,
            relayUrl: selected.relayUrl,
            nsec: key.nsec,
            pubkey: key.public,
          );
      await storage.save(saved);
      await storage.saveActiveId(saved.id);
    });
  }

  @override
  void dispose() {
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    unawaited(browser.dispose());
    account.dispose();
    super.dispose();
  }
}

/// Sign the protocol preimage, not a Nostr event ID.
List<String> signOwnerAuthorization(nostr.Keys owner, String agent) {
  if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(agent) || agent == owner.public) {
    throw StateError('Invalid agent key.');
  }
  final digest = sha256
      .convert(utf8.encode('nostr:agent-auth:$agent:'))
      .toString();
  return [
    'auth',
    owner.public,
    '',
    nostr.Schnorr.sign(secretKey: owner.secret, message: digest),
  ];
}

void requireStatus(Map<String, dynamic> result, String suffix, int numeric) {
  final status = result['status'];
  if (status == numeric || (status is String && status.endsWith('_$suffix'))) {
    return;
  }
  throw StateError(
    'BuilderLab did not confirm $suffix (${status is String || status is num ? status : 'missing status'}).',
  );
}
