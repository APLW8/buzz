import 'dart:convert';

import 'package:buzz/shared/relay/identity_archives.dart';
import 'package:buzz/shared/relay/relay.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nostr/nostr.dart' as nostr;

class _Relay extends RelaySessionNotifier {
  List<NostrEvent> events = [];
  final String authority;
  _Relay(this.authority);
  @override
  Future<List<NostrEvent>> queryRelay(
    List<NostrFilter> filters, {
    Duration timeout = const Duration(seconds: 8),
  }) async {
    expect(filters.single.kinds, [EventKind.archivedIdentities]);
    expect(filters.single.authors, [authority]);
    expect(filters.single.limit, 1);
    return events;
  }
}

void main() {
  final authority = nostr.Keys.generate();
  final agent = nostr.Keys.generate().public;
  NostrEvent snapshot({
    int time = 10,
    bool archived = true,
    List<List<String>>? tags,
    nostr.Keys? signer,
  }) => NostrEvent.fromJson(
    nostr.Event.from(
      kind: EventKind.archivedIdentities,
      content: '',
      secretKey: (signer ?? authority).secret,
      createdAt: time,
      tags:
          tags ??
          [
            ['-'],
            if (archived) ['p', agent],
          ],
    ).toMap(),
  );
  IdentityArchives reader(_Relay relay, {Map<String, dynamic>? document}) =>
      IdentityArchives(
        'https://relay.test',
        relay,
        client: () => MockClient((request) async {
          expect(request.url.toString(), 'https://relay.test/');
          expect(request.headers['Accept'], 'application/nostr+json');
          return http.Response(
            jsonEncode(document ?? {'self': authority.public.toUpperCase()}),
            200,
          );
        }),
      );

  test(
    'fresh archive then unarchive replaces snapshot without sticky exclusions',
    () async {
      final relay = _Relay(authority.public);
      final archives = reader(relay);
      expect(await archives.read(), isEmpty);
      relay.events = [snapshot()];
      expect(await archives.read(), {agent});
      relay.events = [snapshot(time: 11, archived: false)];
      expect(await archives.read(), isEmpty);
      relay.events = [snapshot()];
      await expectLater(archives.read(), throwsStateError);
    },
  );
  test('does not substitute contact pubkey for relay self', () async {
    final relay = _Relay(authority.public);
    await expectLater(
      reader(relay, document: {'pubkey': authority.public}).read(),
      throwsStateError,
    );
  });
  test(
    'rejects forged signatures, wrong authors and malformed protection',
    () async {
      final relay = _Relay(authority.public);
      final badSignature = snapshot().toJson()..['sig'] = '0' * 128;
      for (final event in [
        NostrEvent.fromJson(badSignature),
        snapshot(signer: nostr.Keys.generate()),
        snapshot(
          tags: [
            ['p', agent],
          ],
        ),
        snapshot(
          tags: [
            ['-', 'bad'],
            ['p', agent],
          ],
        ),
        snapshot(
          tags: [
            ['-'],
            ['-'],
            ['p', agent],
          ],
        ),
      ]) {
        relay.events = [event];
        await expectLater(
          reader(relay).read(),
          throwsA(anyOf(isA<Exception>(), isA<StateError>())),
        );
      }
    },
  );
  test(
    'does not silently erase known archive state on missing response',
    () async {
      final relay = _Relay(authority.public)..events = [snapshot()];
      final archives = reader(relay);
      expect(await archives.read(), {agent});
      relay.events = [];
      await expectLater(archives.read(), throwsStateError);
    },
  );
}
