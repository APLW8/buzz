import 'package:buzz/features/channels/message_content.dart';
import 'package:buzz/features/channels/agent_activity/transcript_item_widget.dart';
import 'package:buzz/features/channels/agent_activity/observer_models.dart';
import 'package:buzz/shared/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import '../../shared/markdown/assistant_citations_test.dart' show citation;

Widget host(Widget child) => ProviderScope(
  child: MaterialApp(
    theme: AppTheme.light(),
    home: AppMarkdownTheme(
      child: Scaffold(body: SingleChildScrollView(child: child)),
    ),
  ),
);

void main() {
  testWidgets('activity filters assistant text only and leaves source intact', (
    tester,
  ) async {
    for (final role in ['assistant', 'user']) {
      final item = MessageItem(
        id: 'message',
        role: role,
        title: 'Message',
        text: 'Answer\n$citation',
        timestamp: '2026-10-21T22:32:42Z',
      );
      await tester.pumpWidget(host(TranscriptItemWidget(item: item)));
      final data = tester.widget<GptMarkdown>(find.byType(GptMarkdown)).data;
      expect(data.contains('oai-mem-citation'), role == 'user');
      expect(item.text, 'Answer\n$citation');
    }
  });

  testWidgets(
    'agent reply hides metadata and retains surrounding text and attachment',
    (tester) async {
      const image = 'https://example.test/status.png';
      const source =
          'Online, Away, and Offline now use filled dots.\n\n$citation\n![Status]($image)';
      await tester.pumpWidget(
        host(const MessageContent(content: source, isAssistant: true)),
      );
      final text = tester
          .widgetList<RichText>(find.byType(RichText))
          .map((w) => w.text.toPlainText())
          .join('\n');
      expect(text, contains('Online, Away, and Offline now use filled dots.'));
      expect(text, isNot(contains('oai-mem-citation')));
      expect(text, isNot(contains('MEMORY.md')));
      expect(
        find.byKey(const ValueKey('message-media-image-preview:$image')),
        findsOneWidget,
      );
    },
  );
  testWidgets('human and code example content reaches markdown unchanged', (
    tester,
  ) async {
    for (final agent in [false, true]) {
      final source = agent ? '```xml\n$citation\n```' : citation;
      await tester.pumpWidget(
        host(MessageContent(content: source, isAssistant: agent)),
      );
      expect(tester.widget<GptMarkdown>(find.byType(GptMarkdown)).data, source);
    }
  });
  testWidgets('new content and author classification recompute display', (
    tester,
  ) async {
    for (final agent in [false, true, false]) {
      await tester.pumpWidget(
        host(MessageContent(content: 'Answer\n$citation', isAssistant: agent)),
      );
      final data = tester.widget<GptMarkdown>(find.byType(GptMarkdown)).data;
      expect(data.contains('oai-mem-citation'), !agent);
    }
  });
}
