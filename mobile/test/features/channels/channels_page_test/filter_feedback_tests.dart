part of '../channels_page_test.dart';

void _filterFeedbackTests(
  Widget Function({required List<Override> overrides}) buildTestable,
) {
  testWidgets('Unreads agrees with highlights in the pre-seed frame', (
    tester,
  ) async {
    final channels = [
      for (final id in ['history', 'forced'])
        Channel(
          id: id,
          name: id,
          channelType: 'stream',
          visibility: 'open',
          description: '',
          memberCount: 1,
          createdBy: 'pk',
          createdAt: DateTime(2025),
          lastMessageAt: DateTime.fromMillisecondsSinceEpoch(
            20000,
            isUtc: true,
          ),
          isMember: true,
        ),
    ];
    final readState = _FakeReadStateNotifier(
      const ReadStateState(
        isReady: true,
        pubkey: 'pk',
        contexts: {},
        version: 0,
        forcedUnreadContexts: {'forced': 'forced'},
      ),
    );
    final manager = _filterTestManager(
      cached: ChannelFilterStore.empty().edit(
        'channels',
        ChannelFilterMode.unreads,
      ),
    );
    await tester.pumpWidget(
      buildTestable(
        overrides: [
          channelsProvider.overrideWith(
            () => _FakeNotifier(
              channels,
              observedEventsByChannel: {
                'history': [_observed(id: 'historical', createdAt: 20)],
              },
            ),
          ),
          readStateProvider.overrideWith(() => readState),
          channelFilterProvider.overrideWithValue(manager),
        ],
      ),
    );
    // The channel future resolves before this frame. Seeding runs at its end,
    // but the rendered frame still reflects timestamp-less read state.
    await tester.pump();
    expect(readState.seededContexts, {'history': 20, 'forced': 20});
    expect(find.text('history'), findsNothing);
    expect(find.text('forced'), findsOneWidget);
    expect(
      tester.widget<Text>(find.text('forced')).style?.fontWeight,
      FontWeight.w700,
    );
    await tester.pumpAndSettle();
    expect(find.text('history'), findsNothing);
    await tester.tap(find.text('Show hidden channels · 1'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<Text>(find.text('history')).style?.fontWeight,
      FontWeight.w400,
    );
    await tester.pumpWidget(const SizedBox());
    manager.dispose();
  });
}
