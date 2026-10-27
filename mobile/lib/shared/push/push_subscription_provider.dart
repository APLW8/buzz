import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../features/channels/channel.dart';
import '../../features/channels/channel_mutes/channel_mutes_provider.dart';
import '../../features/channels/channels_provider.dart';
import '../auth/auth.dart';
import '../me/me_sync.dart';
import '../relay/relay_provider.dart';
import 'push_subscription.dart';
import 'push_relay_capability_provider.dart';
import 'push_setup_recovery.dart';

/// Keeps the persisted desired lease and the App Group snapshot aligned with
/// the active identity, joined channels, and mute state. This is desired client
/// policy only. Relay-accepted authority is introduced by lease publication.
final pushSubscriptionSyncProvider = FutureProvider.autoDispose<void>((
  ref,
) async {
  try {
    if (ref.watch(authProvider).value?.status != AuthStatus.authenticated) {
      return;
    }
    final active = ref.watch(activeCommunityProvider).value;
    if (active == null ||
        !active.pushNotificationsEnabled ||
        ref.watch(currentRelayPushDescriptorProvider).value == null) {
      return;
    }
    final channels = ref.watch(channelsProvider).value;
    final mutes = ref.watch(channelMutesProvider);
    if (channels == null || !mutes.isReady) {
      return;
    }

    // Legacy Solo chats are listed only in the Solo record. Wait while it
    // loads so an unresolved record never drops them. If it fails without a
    // cached copy, keep DMs and mentions current; the Solo tab cannot list
    // those chats either, and recovery republishes them.
    final soloRecord = ref.watch(meGroupsProvider);
    if (soloRecord.isLoading && !soloRecord.hasValue) return;

    final subscriptions = desiredBuzzPushSubscriptions(
      community: active,
      channels: channels,
      legacySoloChannelIds: soloRecord.value?.channels ?? const [],
      mutedChannelIds: [
        for (final entry in mutes.store.channels.entries)
          if (entry.value.muted) entry.key,
      ],
    );
    if (subscriptions == null) return;
    await ref
        .read(communityListProvider.notifier)
        .updateDesiredPushSubscriptions(active.id, subscriptions);
  } catch (error, stack) {
    reportPushSetupError('subscription synchronization', error, stack);
    rethrow;
  }
}, retry: pushSetupRetry);

List<BuzzPushSubscription>? desiredBuzzPushSubscriptions({
  required Community community,
  required Iterable<Channel> channels,
  required Iterable<String> mutedChannelIds,
  Iterable<String> legacySoloChannelIds = const [],
}) {
  final pubkey = community.pubkey ?? pubkeyFromNsec(community.nsec);
  if (pubkey == null || pubkey.isEmpty) return null;
  return buildDesiredBuzzPushSubscriptions(
    myPubkey: pubkey,
    channelIds: [
      // Channel-wide traffic pushes only for joined DMs and the viewer's own
      // Solo chats, which are conversations with them. Other channels push
      // through an exact #p mention, so subscribing to every joined channel
      // would over-notify.
      for (final channel in channels)
        if ((channel.isDm ||
                channel.isPersonalChat(pubkey, legacySoloChannelIds)) &&
            channel.isMember &&
            !channel.isArchived)
          channel.id,
    ],
    mutedChannelIds: mutedChannelIds,
  );
}
