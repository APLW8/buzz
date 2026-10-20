import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:nostr/nostr.dart' as nostr;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../shared/community/community_storage.dart';
import '../shared/deeplink/deep_link.dart';
import '../shared/hosted/account_identity_store.dart';
import '../shared/hosted/browser_auth.dart';
import '../shared/hosted/builderlab_account.dart';
import 'owned_communities.dart';
import '../shared/hosted/hosted_environment.dart';
import '../shared/hosted/hosted_admission.dart';
import '../shared/hosted/hosted_backup_service.dart';
import '../shared/hosted/hosted_community_creation.dart';
import '../shared/hosted/hosted_relay_auth.dart';
import '../shared/relay/relay_provider.dart';
import '../shared/relay/nostr_models.dart';
import '../shared/storage/secure_storage.dart';
import '../shared/relay/signed_event_relay.dart';

/// Staging-only experiment using the same account and Beekeeper contracts as desktop.
class RemoteAgentController extends ChangeNotifier {
  RemoteAgentController({
    required this.account,
    required this.browser,
    required AccountIdentityStore keys,
    required this.relayAuth,
  }) : _keys = keys;
  final BuilderlabAccountClient account;
  final BrowserAuth browser;
  final AccountIdentityStore _keys;
  final HostedRelayAuth relayAuth;
  AccountIdentityStore get keys {
    final subject = account.account?.subject;
    return subject == null ? _keys : _keys.forSubject(subject);
  }

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
  Set<String> deletedAgents = {};

  String get _deletionScope {
    final subject = account.account?.subject;
    if (subject == null) throw AccountFailure.signedOut;
    return 'remote-prototype:${HostedEnvironment.origin.host}:$subject';
  }

  /// Deletes an owned runtime only after its selected-community registration
  /// is accepted as deleted and a fresh relay read confirms its absence.
  Future<bool> deleteAgent({
    required String pubkey,
    required AddCommunityDeepLink selected,
    required String communityOwner,
    required bool Function() isCurrent,
    required Future<List<NostrEvent>> Function(NostrFilter) fetch,
  }) => run(() async {
    final subject = account.account?.subject;
    final scope = _deletionScope;
    void check() {
      if (!isCurrent() || account.account?.subject != subject) {
        throw StateError('Community or account changed. Reopen Agents.');
      }
    }

    check();
    await ensureBinding();
    check();
    if (owner != communityOwner) throw AccountIdentityFailure.mismatch;
    final agent = agents
        .where((row) => row['agent_pubkey'] == pubkey)
        .firstOrNull;
    final id = agent?['agent_id'];
    if (id is! String || id.isEmpty) {
      throw StateError('Owned remote agent ID is unavailable. Refresh Agents.');
    }
    if (pending != null) {
      throw StateError('Finish pending agent setup before deleting an agent.');
    }
    final prefs = await SharedPreferences.getInstance();
    check();
    final tombstones = prefs.getStringList('$scope:deleting')?.toSet() ?? {};
    tombstones.add(pubkey);
    if (!await prefs.setStringList('$scope:deleting', tombstones.toList())) {
      throw StateError('Could not save deletion intent. Retry Delete.');
    }
    final retries = Map<String, dynamic>.from(
      jsonDecode(prefs.getString('$scope:delete-retries') ?? '{}') as Map,
    );
    retries[pubkey] = {...agent!, 'deletion_community': selected.relayUrl};
    if (!await prefs.setString('$scope:delete-retries', jsonEncode(retries))) {
      throw StateError('Could not save deletion retry. Retry Delete.');
    }
    check();
    await removePolicy(selected, pubkey);
    check();
    final remaining = await fetch(
      NostrFilter(
        kinds: const [30177],
        authors: [communityOwner],
        tags: {
          '#d': [pubkey],
        },
      ),
    );
    check();
    if (remaining.isNotEmpty) {
      throw StateError('Community registration still exists. Retry Delete.');
    }
    final result = await account.post('/v3/beekeeper/delete-agent', {
      'agent_id': id,
    });
    check();
    final status = result['status'];
    if (status != 1 &&
        status != 3 &&
        status != 'DELETE_AGENT_STATUS_DELETED' &&
        status != 'DELETE_AGENT_STATUS_NOT_FOUND') {
      throw StateError(
        status == 2 || status == 'DELETE_AGENT_STATUS_DISABLED'
            ? 'Agent deletion is disabled on this server.'
            : 'Agent deletion was not confirmed. Retry Delete.',
      );
    }
    final completed = {...deletedAgents, pubkey};
    if (!await prefs.setStringList('$scope:deleted', completed.toList())) {
      throw StateError(
        'Runtime deleted, but local cleanup failed. Retry Delete.',
      );
    }
    deletedAgents = completed;
    retries.remove(pubkey);
    await prefs.setString('$scope:delete-retries', jsonEncode(retries));
    agents = agents.where((row) => row['agent_pubkey'] != pubkey).toList();
    this.status = 'Remote agent deleted.';
  });

  /// Removes only this owner's registration in the selected community.
  Future<void> removePolicy(AddCommunityDeepLink selected, String pubkey) =>
      keys.withKeys((key) async {
        await submitSignedEventOnce(
          wsUrl: selected.relayUrl,
          headers: await relayAuth.headers(
            RelayConfig(baseUrl: selected.relayUrl, nsec: key.nsec),
          ),
          nsec: key.nsec,
          kind: 5,
          content: '',
          tags: [
            ['a', '30177:${key.public}:$pubkey'],
          ],
        );
      });

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

  Future<bool> run(Future<void> Function() action) async {
    if (busy) return false;
    busy = true;
    final operation = ++_operation;
    notifyListeners();
    try {
      await action();
      return true;
    } catch (error) {
      // Account failures never carry credentials or response bodies.
      status = error is AccountFailure
          ? 'BuilderLab: ${error.name}. ${error == AccountFailure.signedOut ? 'Sign in again.' : 'Your session is retained.'}'
          : error is AccountIdentityFailure
          ? 'Buzz identity: ${error.name}.'
          : error is StateError
          ? error.message.toString()
          : 'Operation failed (${error.runtimeType}). Retry the same setup.';
      return false;
    } finally {
      if (operation == _operation) {
        busy = false;
        notifyListeners();
      }
    }
  }

  Future<bool> signIn() => run(() async {
    status =
        'Waiting for Mac Chrome. Open http://127.0.0.1:18763/start '
        'on your Mac, then sign in to your public staging account. '
        'This attempt expires after 10 minutes.';
    notifyListeners();
    await browser.start({'type': 'remote-prototype'});
  });

  Future<void> refresh() async {
    final session = account.account;
    if (session == null) {
      status = 'Sign in to your staging BuilderLab account.';
      return;
    }
    await adoptBoundIdentity();
    owner = (await keys.read())?.pubkey;
    _scope =
        'remote-prototype:${HostedEnvironment.origin.host}:${session.subject}';
    final prefs = await SharedPreferences.getInstance();
    deletedAgents = prefs.getStringList('$_scope:deleted')?.toSet() ?? {};
    final raw = prefs.getString('$_scope:pending');
    pending = raw == null
        ? null
        : Map<String, dynamic>.from(jsonDecode(raw) as Map);
    if (pending?['hasInstructions'] == true) {
      final instructions = await accountSecureStorage.read(
        key: '$_scope:instructions:${pending!['request']}',
      );
      if (instructions == null) {
        throw StateError('Saved agent instructions are unavailable.');
      }
      pending!['instructions'] = instructions;
    }
    if (owner == null) {
      status = 'Import your existing Buzz identity to discover communities.';
      return;
    }
    await ensureBinding();
    communities = await loadPrototypeOwnedCommunities(account);
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
    final retries = Map<String, dynamic>.from(
      jsonDecode(prefs.getString('$_scope:delete-retries') ?? '{}') as Map,
    );
    for (final retry in retries.values) {
      final row = Map<String, dynamic>.from(retry as Map);
      if (!deletedAgents.contains(row['agent_pubkey']) &&
          !agents.any(
            (agent) => agent['agent_pubkey'] == row['agent_pubkey'],
          )) {
        agents.add(row);
      }
    }
    agents = agents
        .where((row) => !deletedAgents.contains(row['agent_pubkey']))
        .toList();
    status = pending == null
        ? 'Signed in. Choose a community and create an agent.'
        : 'Unfinished setup saved. Resume to use the same agent.';
  }

  Future<bool> createTestCommunity() => run(() async {
    await ensureBinding();
    final subject = account.account!.subject;
    await HostedCreateCommunity(
      'tomb-remote-prototype-20261016',
    ).provision(account, owner!, () => account.account?.subject == subject);
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

  /// Migrate only a locally saved key confirmed by the current server binding.
  /// Keep the original record and refuse account/key replacement.
  Future<void> adoptBoundIdentity() async {
    final subject = account.account?.subject;
    if (subject == null) throw AccountFailure.signedOut;
    final scoped = _keys.forSubject(subject);
    final response = await account.currentIdentity();
    if (account.account?.subject != subject) {
      throw AccountFailure.differentAccount;
    }
    if (response['error'] != null) throw AccountFailure.invalidResponse;
    final bound = (response['identity'] as Map?)?['pubkey_hex'];
    final local = await scoped.read();
    if (local != null) {
      if (bound != local.pubkey) throw AccountIdentityFailure.mismatch;
      return;
    }
    if (bound is! String) throw AccountIdentityFailure.absent;
    await scoped.adoptSaved(
      bound,
      checkCurrent: () {
        if (account.account?.subject != subject) {
          throw AccountFailure.differentAccount;
        }
      },
    );
  }

  Future<void> ensureBinding() async {
    await adoptBoundIdentity();
    owner = (await keys.read())?.pubkey;
    if (owner == null) throw AccountIdentityFailure.absent;
  }

  Future<void> _savePending(Map<String, dynamic> value) async {
    final prefs = await SharedPreferences.getInstance();
    final persisted = Map<String, dynamic>.from(value)..remove('instructions');
    final instructions = value['instructions'] as String?;
    if (instructions != null && instructions.isNotEmpty) {
      await accountSecureStorage.write(
        key: '$_scope:instructions:${value['request']}',
        value: instructions,
      );
      persisted['hasInstructions'] = true;
    }
    if (!await prefs.setString('$_scope:pending', jsonEncode(persisted))) {
      throw StateError('Could not save unfinished setup.');
    }
    pending = value;
  }

  Future<bool> create(String name, {String instructions = ''}) => run(() async {
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
      if (instructions.trim().length > 20000) {
        throw StateError('Use at most 20,000 characters for instructions.');
      }
      await _savePending({
        'name': trimmed,
        'instructions': instructions.trim(),
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
    if ((setup['instructions'] as String?)?.isNotEmpty == true) {
      await account.post('/v3/beekeeper/update-agent', {
        'agent_pubkey': pubkey,
        'agent_instructions': setup['instructions'],
      });
    }
    await subscribe(setup['id'] as String);
    await publishPolicy(selected, setup);
    // Retain the completed registration if the listing refresh fails, so Retry
    // resumes the same identity instead of creating another agent.
    await refresh();
    final prefs = await SharedPreferences.getInstance();
    await accountSecureStorage.delete(
      key: '$_scope:instructions:${setup['request']}',
    );
    await prefs.remove('$_scope:pending');
    pending = null;
    status =
        '${setup['name']} is active. Open Buzz and mention it in a channel.';
  });

  /// Publish the owner policy only after activation and subscription succeed.
  Future<void> publishPolicy(
    AddCommunityDeepLink selected,
    Map<String, dynamic> setup,
  ) async {
    final pubkey = setup['pubkey'] as String;
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getStringList('$_deletionScope:deleting')?.contains(pubkey) ==
        true) {
      throw StateError('Agent deletion is pending. Retry Delete.');
    }
    await keys.withKeys((key) async {
      await submitSignedEventOnce(
        wsUrl: selected.relayUrl,
        headers: await relayAuth.headers(
          RelayConfig(baseUrl: selected.relayUrl, nsec: key.nsec),
        ),
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
  }

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
    final subject = account.account?.subject;
    if (subject == null || owner == null) throw AccountFailure.signedOut;
    await ensureBinding();
    final storage = CommunityStorage();
    final existing = (await storage.loadAll())
        .where((c) => c.relayUrl == selected.relayUrl)
        .firstOrNull;
    if (existing != null) {
      // Reopen an already admitted community, as normal saved-community startup
      // does. New-community backup requirements must not replace its identity.
      if (existing.pubkey != owner ||
          existing.nsec == null ||
          AccountIdentityStore.publicKeyForNsec(existing.nsec!) != owner) {
        throw AccountIdentityFailure.mismatch;
      }
      if (account.account?.subject != subject) {
        throw AccountFailure.differentAccount;
      }
      await storage.saveActiveId(existing.id);
      return;
    }
    await HostedBackupService(
      account,
      keys,
    ).backup(isCurrent: () => account.account?.subject == subject);
    final admission = HostedAdmission(
      account: account,
      store: _keys,
      relayAuth: relayAuth,
    );
    try {
      final prepared = await admission.prepare(selected, subject, owner!);
      await storage.save(prepared);
      await storage.saveActiveId(prepared.id);
    } finally {
      admission.dispose();
    }
  }

  @override
  void dispose() {
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    unawaited(browser.dispose());
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
