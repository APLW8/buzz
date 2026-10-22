import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:nostr/nostr.dart' as nostr;

import 'nostr_models.dart';
import 'relay_session.dart';

/// Fresh relay-authoritative NIP-IA snapshots for forward-looking choices.
/// Keeps only an ordering fence, scoped to one account/community session.
class IdentityArchives {
  IdentityArchives(this.baseUrl, this.session, {http.Client Function()? client})
    : _client = client ?? http.Client.new;

  final String baseUrl;
  final RelaySessionNotifier session;
  final http.Client Function() _client;
  NostrEvent? _head;

  /// Fetches and verifies a fresh snapshot. Unknown state fails visibly.
  Future<Set<String>> read() async {
    final client = _client();
    try {
      final base = Uri.parse(baseUrl);
      final uri = Uri(
        scheme: switch (base.scheme) {
          'wss' => 'https',
          'ws' => 'http',
          _ => base.scheme,
        },
        host: base.host,
        port: base.hasPort ? base.port : null,
        path: '/',
      );
      final response = await client
          .send(
            http.Request('GET', uri)
              ..headers['Accept'] = 'application/nostr+json',
          )
          .timeout(const Duration(seconds: 5));
      if (response.statusCode != 200) {
        throw StateError('Could not read relay identity.');
      }
      final bytes = <int>[];
      await (() async {
        await for (final chunk in response.stream) {
          if (bytes.length + chunk.length > 256 * 1024) {
            throw StateError('Relay identity document is too large.');
          }
          bytes.addAll(chunk);
        }
      })().timeout(const Duration(seconds: 5));
      final info = jsonDecode(utf8.decode(bytes));
      final authority = info is Map ? info['self'] : null;
      if (authority is! String ||
          !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(authority)) {
        throw StateError('Relay identity document has no valid self key.');
      }
      final events = await session.queryRelay([
        NostrFilter(
          kinds: const [EventKind.archivedIdentities],
          authors: [authority.toLowerCase()],
          limit: 1,
        ),
      ]);
      if (events.isEmpty) {
        if (_head != null) {
          throw StateError('Relay archive snapshot disappeared.');
        }
        return {};
      }
      if (events.length != 1) {
        throw StateError('Unexpected archive snapshot count.');
      }
      final event = events.single;
      final archived = await compute(_verifySnapshot, (
        event,
        authority.toLowerCase(),
      ));
      final previous = _head;
      if (previous != null &&
          (event.createdAt < previous.createdAt ||
              (event.createdAt == previous.createdAt &&
                  event.id.compareTo(previous.id) > 0))) {
        throw StateError('Relay returned an older archive snapshot.');
      }
      _head = event;
      return archived;
    } finally {
      client.close();
    }
  }
}

Set<String> _verifySnapshot((NostrEvent, String) input) {
  final (event, authority) = input;
  final encoded = jsonEncode(event.toJson());
  final markers = event.tags
      .where((tag) => tag.isNotEmpty && tag.first == '-')
      .toList();
  if (event.kind != EventKind.archivedIdentities ||
      event.pubkey != authority ||
      event.content.isNotEmpty ||
      markers.length != 1 ||
      markers.single.length != 1 ||
      utf8.encode(encoded).length > 2 * 1024 * 1024) {
    throw StateError('Invalid relay archive snapshot.');
  }
  nostr.Event.fromJson(encoded);
  final hex = RegExp(r'^[0-9a-f]{64}$');
  return {
    for (final tag in event.tags)
      if (tag.length >= 2 && tag.first == 'p' && hex.hasMatch(tag[1])) tag[1],
  };
}
