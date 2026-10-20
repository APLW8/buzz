import 'dart:convert';
import 'package:buzz/shared/deeplink/deep_link.dart';
import 'package:flutter_test/flutter_test.dart';

Uri link(Object value) => Uri.parse(
  'buzz://agent/new#${base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '')}',
);

void main() {
  final valid = <String, Object>{
    'v': 1,
    'name': 'QR Scout',
    'instructions': 'Answer briefly.',
    'avatar': {'emoji': '🦉', 'color': '#476CFF'},
  };
  test(
    'versioned drafts preserve text and either avatar shape, ignore extra fields',
    () {
      final draft =
          parseBuzzDeepLink(link({...valid, 'untrusted_extra': 'ignored'}))
              as AgentCreationDeepLink;
      expect(draft.name, 'QR Scout');
      expect(draft.instructions, 'Answer briefly.');
      expect(draft.avatar, valid['avatar']);
      expect(draft.avatarUrl, startsWith('data:image/svg+xml,'));
      expect(draft.toString(), isNot(contains('Answer briefly.')));
      final image =
          parseBuzzDeepLink(
                link({...valid, 'avatar': 'https://example.com/avatar.png'}),
              )
              as AgentCreationDeepLink;
      expect(image.avatarUrl, 'https://example.com/avatar.png');
    },
  );
  test(
    'rejects invalid versions, types, image bytes, insecure URLs, and malformed data',
    () {
      for (final invalid in [
        {...valid, 'v': 2},
        {...valid, 'v': 1.0},
        {...valid, 'name': ''},
        {...valid, 'instructions': 3},
        {...valid, 'avatar': 'data:image/png;base64,AA=='},
        {...valid, 'avatar': 'http://example.com/a.png'},
        {...valid, 'avatar': 'https://user:secret@example.com/a.png'},
        {
          ...valid,
          'avatar': {'emoji': 'two', 'color': '#476CFF'},
        },
        {
          ...valid,
          'avatar': {'emoji': '🦉', 'color': 'red'},
        },
      ]) {
        expect(parseBuzzDeepLink(link(invalid)), isNull);
      }
      for (final uri in [
        'buzz://agent/new#bad!',
        'buzz://agent/new#e30',
        'buzz://agent/new?auto=true#e30',
        'buzz://agent/other#e30',
      ]) {
        expect(parseBuzzDeepLink(Uri.parse(uri)), isNull);
      }
    },
  );
  test(
    'hard cap applies to the entire encoded URL, including unknown fields',
    () {
      var largest = link(valid);
      for (var n = 0; n < 1500; n++) {
        final candidate = link({...valid, 'ignored': 'x' * n});
        if (utf8.encode(candidate.toString()).length >
            maxAgentCreationLinkBytes) {
          expect(parseBuzzDeepLink(largest), isA<AgentCreationDeepLink>());
          expect(parseBuzzDeepLink(candidate), isNull);
          break;
        }
        largest = candidate;
      }
    },
  );
}
