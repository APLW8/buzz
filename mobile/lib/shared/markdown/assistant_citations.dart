// Recognize the provider's envelope, not arbitrary XML or angle-bracket text.
final _citationBlock = RegExp(
  r' {0,3}<oai-mem-citation>\s*'
  r'<citation_entries>[^<>]*</citation_entries>\s*'
  r'(?:<rollout_ids>[^<>]*</rollout_ids>\s*)?'
  r'</oai-mem-citation>[ \t]*(?:\r?\n|$)',
);
final _fence = RegExp(r'^ {0,3}(`{3,}|~{3,})(.*)$');
final _ticks = RegExp(r'`+');

/// Hides complete provider memory citations in assistant prose for display only.
///
/// The caller must establish assistant authorship. Signed content is untouched.
/// Standalone envelopes are recognized regardless of payload or position, while
/// literal code, quotes, indented examples, and incomplete/unknown markup stay.
String assistantDisplayContent(String content) {
  if (!content.contains('<oai-mem-citation>')) return content;
  final output = StringBuffer();
  var offset = 0;
  String? fenceCharacter;
  var fenceLength = 0;
  var inlineLength = 0;
  while (offset < content.length) {
    final newline = content.indexOf('\n', offset);
    final end = newline < 0 ? content.length : newline + 1;
    final line = content.substring(offset, end);
    final fence = _fence.firstMatch(line.trimRight());
    if (fenceCharacter != null) {
      if (fence != null &&
          fence[1]![0] == fenceCharacter &&
          fence[1]!.length >= fenceLength &&
          fence[2]!.trim().isEmpty) {
        fenceCharacter = null;
      }
    } else if (inlineLength == 0 && fence != null) {
      fenceCharacter = fence[1]![0];
      fenceLength = fence[1]!.length;
    } else {
      if (inlineLength == 0) {
        final citation = _citationBlock.matchAsPrefix(content, offset);
        if (citation != null) {
          offset = citation.end;
          continue;
        }
      }
      // Keep multiline inline-code examples literal too. Conservatively retain
      // the rest after an unmatched backtick rather than hide possible code.
      for (final tick in _ticks.allMatches(line)) {
        var slashes = 0;
        for (var i = tick.start - 1; i >= 0 && line[i] == r'\'; i--) {
          slashes++;
        }
        if (inlineLength == 0 && slashes.isOdd) continue;
        final length = tick.end - tick.start;
        if (inlineLength == 0) {
          inlineLength = length;
        } else if (inlineLength == length) {
          inlineLength = 0;
        }
      }
    }
    output.write(line);
    offset = end;
  }
  return output.toString();
}
