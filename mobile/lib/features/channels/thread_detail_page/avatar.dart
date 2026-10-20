part of '../thread_detail_page.dart';

class _Avatar extends ConsumerWidget {
  final UserProfile? profile;
  final String pubkey;
  final bool isAgent;

  const _Avatar({
    required this.profile,
    required this.pubkey,
    required this.isAgent,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final initial =
        profile?.initial ?? (pubkey.isNotEmpty ? pubkey[0].toUpperCase() : '?');
    final avatarUrl =
        ref.watch(agentDefinitionAvatarsProvider)[pubkey] ?? profile?.avatarUrl;

    return AvatarImage(
      imageUrl: avatarUrl,
      radius: messageAvatarSize / 2,
      backgroundColor: context.controlSurface,
      fallback: Text(
        initial,
        style: context.textTheme.labelMedium?.copyWith(
          color: context.colors.onPrimaryContainer,
          fontWeight: FontWeight.w600,
        ),
      ),
      isAgent: isAgent,
    );
  }
}
