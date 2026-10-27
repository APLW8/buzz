part of '../settings_page.dart';

class _NotificationsSection extends ConsumerWidget {
  const _NotificationsSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (defaultTargetPlatform != TargetPlatform.iOS) {
      return const SizedBox.shrink();
    }
    final community = ref.watch(activeCommunityProvider).value;
    if (community == null) return const SizedBox.shrink();
    final setup = ref.watch(buzzPushSetupStatusProvider);
    final capability = ref.watch(currentRelayPushDescriptorProvider);
    final hasCapability =
        !capability.isLoading &&
        !capability.hasError &&
        capability.value != null;
    final optOutPending =
        community.pushSubscriptionState.pendingTombstoneGeneration != null;
    if (!hasCapability &&
        !community.pushNotificationsEnabled &&
        !optOutPending &&
        !setup.hasError) {
      return const SizedBox.shrink();
    }
    final canToggle = hasCapability || community.pushNotificationsEnabled;
    final overflow = community.pushNotificationsEnabled
        ? ref.watch(pushSubscriptionSyncProvider).value
        : null;

    void setEnabled(bool enabled) {
      unawaited(
        ref
            .read(communityListProvider.notifier)
            .setPushNotificationsEnabled(community.id, enabled),
      );
    }

    return AppListCard(
      verticalPadding: Grid.twelve,
      children: [
        if (setup.hasError)
          AppListRow(
            key: const ValueKey('push-setup-retry'),
            title: 'Notification setup failed',
            subtitle: 'You can keep using Buzz. Tap to retry notifications.',
            onTap: () => retryBuzzPushSetup(ref),
          ),
        MergeSemantics(
          key: const ValueKey('push-notifications-setting'),
          child: Stack(
            alignment: Alignment.centerRight,
            children: [
              AppListRow(
                key: const ValueKey('push-notifications-enabled'),
                title: 'Notifications',
                // Reserve horizontal room without letting the switch's 48dp
                // layout height expand this single-line row.
                trailing: const SizedBox(width: 60),
                onTap: canToggle
                    ? () => setEnabled(!community.pushNotificationsEnabled)
                    : null,
              ),
              Positioned.fill(
                right: Grid.xs,
                child: Align(
                  alignment: Alignment.centerRight,
                  child: Switch.adaptive(
                    value: community.pushNotificationsEnabled,
                    onChanged: canToggle ? setEnabled : null,
                  ),
                ),
              ),
            ],
          ),
        ),
        if (overflow != null && overflow.chats > 0)
          AppListRow(
            key: const ValueKey('push-solo-coverage'),
            title: 'Older Solo chats notify only on mention',
            subtitle: _soloOverflowText(overflow),
          ),
      ],
    );
  }
}

String _soloOverflowText(SoloOverflow overflow) {
  final past = overflow.chats == 1
      ? '1 chat is past this relay’s notification limit.'
      : '${overflow.chats} chats are past this relay’s notification limit.';
  if (overflow.muted == 0) return past;
  if (overflow.chats == 1) {
    return '$past It is muted but still notifies on mention.';
  }
  return overflow.muted == 1
      ? '$past 1 of them is muted but still notifies on mention.'
      : '$past ${overflow.muted} of them are muted but still notify on mention.';
}
