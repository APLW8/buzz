import 'package:buzz/features/channels/channel.dart';
import 'package:buzz/shared/community/community.dart';
import 'package:buzz/shared/push/push_subscription.dart';
import 'package:buzz/shared/push/push_subscription_provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nostr/nostr.dart' as nostr;

void main() {
  const activeID = '123e4567-e89b-42d3-a456-426614174000';
  const archivedID = '123e4567-e89b-42d3-a456-426614174001';
  const nonMemberID = '123e4567-e89b-42d3-a456-426614174002';

  test(
    'derives desired subscriptions from nsec, membership, and mute state',
    () {
      final nsec = nostr.Keys.generate().nsec;
      final subscriptions = desiredBuzzPushSubscriptions(
        community: Community.create(
          name: 'Team',
          relayUrl: 'https://relay.example.com',
          nsec: nsec,
        ),
        channels: [
          channel(activeID),
          channel(archivedID, archived: true),
          channel(nonMemberID, isMember: false),
        ],
        mutedChannelIds: const [activeID, archivedID],
      );

      expect(subscriptions, isNotNull);
      expect(subscriptions, hasLength(1));
      expect(subscriptions!.single.filter.pTags, hasLength(1));
      expect(subscriptions.single.ignore, hasLength(2));
      expect(subscriptions.single.ignore.first.kinds, buzzPushRenderableKinds);
      expect(subscriptions.single.ignore.last.hTags, [activeID]);
    },
  );

  test('subscribes channel-wide to joined DMs and own Solo chats only', () {
    final keys = nostr.Keys.generate();
    const dmID = '123e4567-e89b-42d3-a456-426614174003';
    const soloID = '123e4567-e89b-42d3-a456-426614174004';
    const archivedSoloID = '123e4567-e89b-42d3-a456-426614174005';
    const otherSoloID = '123e4567-e89b-42d3-a456-426614174006';
    const streamID = '123e4567-e89b-42d3-a456-426614174007';
    const mutedSoloID = '123e4567-e89b-42d3-a456-426614174008';
    const legacySoloID = '123e4567-e89b-42d3-a456-426614174009';
    Channel solo(String id, {String? createdBy, bool archived = false}) =>
        channel(
          id,
          channelType: 'stream',
          visibility: 'private',
          labels: const ['buzz.solo'],
          createdBy: createdBy ?? keys.public,
          archived: archived,
        );
    final subscriptions = desiredBuzzPushSubscriptions(
      community: Community.create(
        name: 'Team',
        relayUrl: 'https://relay.example.com',
        nsec: keys.nsec,
      ),
      channels: [
        channel(dmID),
        solo(soloID),
        solo(archivedSoloID, archived: true),
        solo(otherSoloID, createdBy: 'author'),
        channel(streamID, channelType: 'stream', visibility: 'private'),
        solo(mutedSoloID),
        channel(legacySoloID, channelType: 'stream', visibility: 'private'),
      ],
      legacySoloChannelIds: const [legacySoloID],
      mutedChannelIds: const [mutedSoloID],
    );

    expect(subscriptions, hasLength(2));
    expect(subscriptions!.first.ignore.last.hTags, [mutedSoloID]);
    expect(subscriptions.last.filter.kinds, buzzPushChannelKinds);
    expect(subscriptions.last.filter.hTags, [dmID, soloID, legacySoloID]);
  });

  test('returns no desired subscriptions without a signing identity', () {
    final subscriptions = desiredBuzzPushSubscriptions(
      community: Community.create(
        name: 'Team',
        relayUrl: 'https://relay.example.com',
      ),
      channels: [channel(activeID)],
      mutedChannelIds: const [],
    );

    expect(subscriptions, isNull);
  });
}

Channel channel(
  String id, {
  bool isMember = true,
  bool archived = false,
  String channelType = 'dm',
  String visibility = 'open',
  List<String> labels = const [],
  String createdBy = 'author',
}) => Channel(
  id: id,
  name: id,
  channelType: channelType,
  visibility: visibility,
  labels: labels,
  description: '',
  createdBy: createdBy,
  createdAt: DateTime(2026),
  memberCount: 1,
  isMember: isMember,
  archivedAt: archived ? DateTime(2026) : null,
);
