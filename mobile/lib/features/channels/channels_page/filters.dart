part of '../channels_page.dart';

/// A sheet gives hidden channel rows the same touch targets and presentation
/// as the main list, including unread, mute and working indicators.
class _SectionFilterSheet extends HookConsumerWidget {
  final String group;
  final List<Channel> channels;
  final String? currentPubkey;
  final String? selectedChannelId;
  final Future<void> Function(Channel) onOpen;
  const _SectionFilterSheet({
    required this.group,
    required this.channels,
    required this.currentPubkey,
    this.selectedChannelId,
    required this.onOpen,
  });
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final manager = ref.watch(channelFilterProvider);
    useListenable(manager);
    final readState = ref.watch(readStateProvider);
    final latestChannels = ref.watch(channelsProvider).value ?? channels;
    final sections = ref.watch(channelSectionsProvider).store;
    final stars = ref.watch(channelStarsProvider).store.channels;
    final personalIds =
        ref.watch(meGroupsProvider).asData?.value.channels ?? const <String>[];
    final roster = latestChannels.where((c) {
      if (personalIds.contains(c.id)) return false;
      if (!c.isMember || c.isArchived || (!c.isDm && !c.isStream)) return false;
      final currentGroup = c.isDm
          ? 'dms'
          : stars[c.id]?.starred == true
          ? 'starred'
          : sections.sections.any((s) => s.id == sections.assignments[c.id])
          ? sectionSortGroupKey(sections.assignments[c.id]!)
          : 'channels';
      return currentGroup == group;
    }).toList();
    final names = ref.watch(identityNameSourcesProvider);
    final sortMode = ref.watch(channelSortProvider).sortModeFor(group);
    final ordered = group == 'dms' && sortMode == ChannelSortMode.alpha
        ? sortDmChannelsByDisplayLabel(
            roster,
            currentPubkey: currentPubkey,
            names: names,
          )
        : sortChannelsForList(roster, sortMode);
    final liveUnread = computeUnreadChannelIds(
      channels: roster,
      readState: readState,
      channelsNotifier: ref.read(channelsProvider.notifier),
    );
    final liveMutes = ref.watch(channelMutesProvider).store.channels;
    final clock = useState(0);
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final hidden = <Channel>[];
    var nextExpiry = 0;
    for (final channel in ordered) {
      final mode = manager?.store.modeFor(group) ?? ChannelFilterMode.all;
      final evidence = mode == ChannelFilterMode.active
          ? ref.watch(channelFilterActivityProvider(channel.id))
          : null;
      final at = evidence?.asData?.value;
      final window =
          manager?.store.windowFor(group) ?? defaultActiveWindowSeconds;
      if (at != null &&
          at + window > now &&
          (nextExpiry == 0 || at + window < nextExpiry)) {
        nextExpiry = at + window;
      }
      if (!channelMatchesFilter(
        mode: mode,
        unread: liveUnread.contains(channel.id),
        activitySeconds: at,
        activityKnown: evidence?.asData != null,
        nowSeconds: now,
        windowSeconds: window,
        selected: channel.id == selectedChannelId,
      )) {
        hidden.add(channel);
      }
    }
    useEffect(() {
      if (nextExpiry == 0) return null;
      final timer = Timer(
        Duration(seconds: nextExpiry - now),
        () => clock.value++,
      );
      return timer.cancel;
    }, [nextExpiry, clock.value]);
    final failed = useState<ChannelFilterMode?>(null);
    final saving = useState(false);
    Future<void> save(ChannelFilterMode mode) async {
      if (manager == null) return;
      saving.value = true;
      try {
        await manager.save(group, mode);
        if (context.mounted) {
          failed.value = null;
        }
      } catch (_) {
        if (context.mounted) failed.value = mode;
      } finally {
        if (context.mounted) saving.value = false;
      }
    }

    final writable =
        manager?.ready == true && manager?.busy == false && !saving.value;
    final mode = manager?.store.modeFor(group) ?? ChannelFilterMode.all;
    return SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(Grid.xs),
              child: Text('Filter'),
            ),
            if (manager?.ready != true && manager?.error == null)
              const Padding(
                padding: EdgeInsets.all(Grid.xs),
                child: Text(
                  'Filters are read-only until preferences load from the community.',
                ),
              ),
            if (manager?.error != null && failed.value == null)
              ListTile(
                title: Text(manager!.error!),
                trailing: TextButton(
                  onPressed: manager.busy ? null : manager.refresh,
                  child: const Text('Retry'),
                ),
              ),
            for (final choice in ChannelFilterMode.values)
              Semantics(
                checked: mode == choice,
                inMutuallyExclusiveGroup: true,
                child: ListTile(
                  enabled: writable,
                  leading: Icon(
                    mode == choice
                        ? Icons.radio_button_checked
                        : Icons.radio_button_off,
                  ),
                  title: Text(switch (choice) {
                    ChannelFilterMode.all => 'All',
                    ChannelFilterMode.unreads => 'Unreads',
                    ChannelFilterMode.active => 'Active in the last',
                  }),
                  subtitle: choice == ChannelFilterMode.active
                      ? Text(
                          '${(manager?.store.windowFor(group) ?? defaultActiveWindowSeconds) ~/ 86400} days',
                        )
                      : null,
                  onTap: !writable
                      ? null
                      : () async {
                          if (choice == ChannelFilterMode.active) {
                            await showBuzzDialog<void>(
                              context: context,
                              barrierDismissible: false,
                              builder: (_) => _ActiveFilterDialog(
                                group: group,
                                manager: manager!,
                              ),
                            );
                          } else {
                            await save(choice);
                          }
                        },
                ),
              ),
            if (failed.value != null)
              Padding(
                padding: const EdgeInsets.all(Grid.xs),
                child: Column(
                  children: [
                    const Text('Could not confirm the filter save.'),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          onPressed: saving.value
                              ? null
                              : () {
                                  failed.value = null;
                                  manager?.dismissError();
                                },
                          child: const Text('Dismiss'),
                        ),
                        TextButton(
                          onPressed: !writable
                              ? null
                              : () => save(failed.value!),
                          child: const Text('Retry'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            if (hidden.isNotEmpty) const Divider(),
            for (final channel in hidden)
              _ChannelTile(
                channel: channel,
                isUnread: liveUnread.contains(channel.id),
                isMuted: liveMutes[channel.id]?.muted == true,
                currentPubkey: currentPubkey,
                sectionId: group.startsWith('section:')
                    ? group.substring(8)
                    : null,
                onMarkRead: null,
                onTap: () {
                  Navigator.of(context).pop();
                  unawaited(onOpen(channel));
                },
              ),
          ],
        ),
      ),
    );
  }
}

class _ActiveFilterDialog extends HookWidget {
  final String group;
  final ChannelFilterManager manager;
  const _ActiveFilterDialog({required this.group, required this.manager});
  @override
  Widget build(BuildContext context) {
    useListenable(manager);
    final days = useState(manager.store.windowFor(group) ~/ 86400);
    final busy = useState(false);
    final failed = useState(false);
    return PopScope(
      canPop: !busy.value,
      child: AlertDialog(
        title: const Text('Active in the last'),
        content: SizedBox(
          width: 320,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Wrap(
                  spacing: Grid.xxs,
                  runSpacing: Grid.xxs,
                  children: [
                    for (final preset in {1, 7, 30, 90, days.value})
                      SizedBox(
                        width: 140,
                        child: OutlinedButton(
                          onPressed: busy.value
                              ? null
                              : () => days.value = preset,
                          child: Semantics(
                            checked: days.value == preset,
                            inMutuallyExclusiveGroup: true,
                            child: Text(
                              '$preset ${preset == 1 ? 'day' : 'days'}',
                              style: TextStyle(
                                fontWeight: days.value == preset
                                    ? FontWeight.bold
                                    : FontWeight.normal,
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                if (failed.value)
                  const Padding(
                    padding: EdgeInsets.only(top: Grid.xs),
                    child: Text(
                      'Could not confirm the save. Your selection is retained. Retry or Cancel.',
                    ),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: busy.value
                ? null
                : () {
                    manager.dismissError();
                    Navigator.of(context).pop();
                  },
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: busy.value || !manager.ready
                ? null
                : () async {
                    busy.value = true;
                    failed.value = false;
                    try {
                      await manager.save(
                        group,
                        ChannelFilterMode.active,
                        windowSeconds: days.value * 86400,
                      );
                      if (context.mounted) Navigator.of(context).pop();
                    } catch (_) {
                      if (context.mounted) failed.value = true;
                    } finally {
                      if (context.mounted) busy.value = false;
                    }
                  },
            child: Text(
              busy.value
                  ? 'Saving…'
                  : failed.value
                  ? 'Retry'
                  : 'Apply',
            ),
          ),
        ],
      ),
    );
  }
}
