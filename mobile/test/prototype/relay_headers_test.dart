import 'dart:convert';
import 'dart:io';

import 'package:buzz/shared/relay/signed_event_relay.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nostr/nostr.dart' as nostr;

void main() {
  test('prototype publication carries federated admission header', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final received = server.first.then((request) async {
      expect(
        request.headers.value('Nostr-Federated-Identity'),
        'Bearer fixture',
      );
      final socket = await WebSocketTransformer.upgrade(request);
      socket.add(jsonEncode(['AUTH', 'fixture-challenge']));
      socket.listen((raw) {
        final frame = jsonDecode(raw as String) as List;
        final event = frame[1] as Map;
        if (frame.first == 'AUTH') {
          socket.add(jsonEncode(['OK', event['id'], true, '']));
        } else {
          expect(frame.first, 'EVENT');
          expect(event['kind'], 30177);
          socket.add(jsonEncode(['OK', event['id'], true, '']));
        }
      });
      return socket;
    });
    final key = nostr.Keys('0' * 63 + '1');
    try {
      await submitSignedEventOnce(
        wsUrl: 'ws://127.0.0.1:${server.port}',
        nsec: key.nsec,
        kind: 30177,
        content: '{}',
        tags: const [],
        headers: const {'Nostr-Federated-Identity': 'Bearer fixture'},
      );
      await (await received).close();
    } finally {
      await server.close(force: true);
    }
  });
}
