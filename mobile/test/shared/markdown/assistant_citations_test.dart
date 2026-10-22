import 'package:buzz/shared/markdown/assistant_citations.dart';
import 'package:flutter_test/flutter_test.dart';

const citation = '''<oai-mem-citation>
<citation_entries>
MEMORY.md:34-34|note=[Pinned mobile toolchain guidance verified locally]
</citation_entries>
<rollout_ids>
</rollout_ids>
</oai-mem-citation>''';

void main() {
  test('removes metadata while preserving all surrounding bytes', () {
    const image = '![STATUS\\_MENU.png](<https://example.test/image.png>)';
    const source = 'Reply.\n\n$citation\n$image';
    expect(assistantDisplayContent(source), 'Reply.\n\n$image');
    expect(assistantDisplayContent('$citation\nAnswer\n$citation'), 'Answer\n');
  });
  test('accepts varied payloads, whitespace and optional rollout ids', () {
    for (final block in [
      citation.replaceAll('\n', '\r\n'),
      citation
          .replaceAll('MEMORY.md:34-34', 'memory/other.md:1-99')
          .replaceAll('<rollout_ids>\n', '<rollout_ids>\nfirst\nsecond\n'),
      '<oai-mem-citation> <citation_entries>other</citation_entries> </oai-mem-citation>',
      '  $citation',
    ]) {
      expect(assistantDisplayContent('$block\nAnswer'), 'Answer');
    }
  });
  final literals = <String, String>{
    'inline': '`$citation`',
    'double backticks': '``$citation``',
    'backtick fence': '```xml\n$citation\n```',
    'tilde fence': '~~~xml\n$citation\n~~~',
    'long fence': '````\n```\n$citation\n````',
    'unclosed fence': '```xml\n$citation',
    'unclosed inline': '`example\n$citation',
    'indented code': citation.split('\n').map((l) => '    $l').join('\n'),
    'quoted example': citation.split('\n').map((l) => '> $l').join('\n'),
    'escaped': '\\$citation',
    'literal mention': 'The tag is <oai-mem-citation>.',
    'unknown envelope': '<oai-mem-citation>Useful prose</oai-mem-citation>',
    'incomplete': citation.replaceAll('</oai-mem-citation>', ''),
    'unknown inner tag': citation.replaceAll('citation_entries', 'example'),
    'ordinary HTML': '<details>Useful prose</details>',
    'same line prose': 'Explain $citation please',
  };
  for (final entry in literals.entries) {
    test('preserves ${entry.key}', () {
      expect(assistantDisplayContent(entry.value), entry.value);
    });
  }
  test('resumes filtering after code closes', () {
    final example = '~~~xml\n$citation\n~~~\n';
    expect(
      assistantDisplayContent('$example$citation\nAnswer'),
      '${example}Answer',
    );
  });
  test('does not repeatedly scan nested malformed openers', () {
    final malformed = '<oai-mem-citation>\n' * 10000;
    expect(assistantDisplayContent(malformed), malformed);
  });
}
