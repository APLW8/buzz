import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:nostr/nostr.dart' as nostr;
import 'package:buzz/shared/relay/media_auth.dart';
import 'package:buzz/shared/relay/relay_session.dart';
import 'package:buzz/shared/crypto/event_signer.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final results = <String>[];
  final key = '0' * 63 + '3';
  final nsec = nostr.Nip19.encode(prefix: nostr.Nip19Prefix.nsec, data: key);
  final cold = Stopwatch()..start();
  final first = signEvent(
    kind: 9,
    content: 'iOS native signing 🐝',
    secretKey: key,
  );
  results.add('cold complete event: ${cold.elapsedMicroseconds} us');
  if (!first.isValid()) throw StateError('Native signature rejected by Dart');
  for (var i = 0; i < 100; i++) {
    signEvent(kind: 9, content: '', secretKey: key);
  }
  for (final count in [1, 8, 32, 64]) {
    final samples = <int>[];
    for (var round = 0; round < 100; round++) {
      final watch = Stopwatch()..start();
      for (var i = 0; i < count; i++) {
        signEvent(
          kind: 24242,
          content: '',
          secretKey: key,
          tags: [
            ['t', 'get'],
            ['expiration', '1800000060'],
          ],
        );
      }
      samples.add(watch.elapsedMicroseconds);
    }
    samples.sort();
    results.add(
      'burst $count: p50 ${samples[50]} p95 ${samples[95]} max ${samples.last} us',
    );
  }
  final media = MediaGetAuthService(
    baseUrl: 'https://relay.example',
    nsec: nsec,
  );
  final watch = Stopwatch()..start();
  final proofs = <Map<String, String>>[];
  for (var i = 0; i < 64; i++) {
    proofs.add(await media.headersForAsync('https://relay.example/media/$i'));
  }
  results.add('64 complete media headers: ${watch.elapsedMicroseconds} us');
  for (final proof in proofs) {
    final encoded = proof['Authorization']!.split(' ').last;
    final event = nostr.Event.fromJson(utf8.decode(base64Decode(encoded)));
    if (!event.isValid()) throw StateError('Invalid media proof');
  }
  if ((await media.headersForAsync(
    'https://foreign.example/media/x',
  )).isNotEmpty) {
    throw StateError('Foreign host received credentials');
  }
  results.add('media signatures and foreign-host isolation: PASS');
  final queryWatch = Stopwatch()..start();
  final headers = <String>[];
  for (var i = 0; i < 32; i++) {
    headers.add(
      buildNip98AuthHeader(
        nsec: nsec,
        url: 'https://relay.example/query',
        method: 'POST',
        bodyBytes: utf8.encode(
          jsonEncode({
            'kinds': [9],
            '#h': ['channel-$i'],
            'limit': 50,
          }),
        ),
      ),
    );
  }
  results.add(
    '32 complete NIP98 headers: ${queryWatch.elapsedMicroseconds} us',
  );
  for (final header in headers) {
    nostr.Event.fromJson(utf8.decode(base64Decode(header.split(' ').last)));
  }
  results.add('query signatures: PASS');
  for (final result in results) {
    debugPrint('SIGNING_PROBE $result');
  }
  runApp(
    MaterialApp(
      home: Scaffold(body: SafeArea(child: Text(results.join('\n')))),
    ),
  );
}
