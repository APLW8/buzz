import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../features/profile/user_profile_sheet.dart';
import '../features/channels/channel.dart';
import '../features/channels/channel_detail_page.dart';
import '../shared/community/community_provider.dart';
import '../shared/crypto/nip_oa.dart';
import '../shared/identity_names/identity_names_provider.dart';
import '../shared/mentions/agent_identity_provider.dart';
import '../shared/profile/user_cache_provider.dart';
import '../shared/relay/relay.dart';
import '../shared/theme/theme.dart';
import '../shared/widgets/avatar_image.dart';
import '../shared/widgets/buzz_titled_sheet_layout.dart';
import '../shared/widgets/modal_presentation.dart';
import 'create_agent_sheet.dart';
import 'delete_agent_action.dart';
import 'remote_agent_controller.dart';

/// Opens a community-scoped Agents navigation stack inside one modal.
Future<void> showPrototypeAgents(
  BuildContext context,
  RemoteAgentController controller,
) async {
  final channel = await showBuzzModalBottomSheet<Channel>(
    context: context,
    isScrollControlled: true,
    showCloseButton: false,
    builder: (_) => _AgentsNavigation(controller: controller),
  );
  if (channel != null && context.mounted) {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(builder: (_) => ChannelDetailPage(channel: channel)),
    );
  }
}

class _AgentsNavigation extends HookConsumerWidget {
  const _AgentsNavigation({required this.controller});

  final RemoteAgentController controller;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final communityId = ref.watch(activeCommunityProvider).asData?.value?.id;
    final navigator = useMemoized(() => GlobalKey<NavigatorState>(), [
      communityId,
    ]);
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * .72,
      child: NavigatorPopHandler<Channel>(
        onPopWithResult: (result) => navigator.currentState!.pop(result),
        child: Navigator(
          key: navigator,
          onGenerateRoute: (_) => MaterialPageRoute<void>(
            builder: (listContext) => Material(
              color: context.colors.surface,
              child: PrototypeAgentsSheet(
                controller: controller,
                onClose: () => Navigator.of(context).pop(),
                onSelect: (pubkey) async {
                  final channel = await Navigator.of(listContext).push<Channel>(
                    MaterialPageRoute(
                      builder: (detailContext) => Material(
                        key: const ValueKey('agent-detail-surface'),
                        color: context.colors.surface,
                        child: SizedBox.expand(
                          child: BuzzTitledSheetLayout(
                            title: 'Agent',
                            leading: IconButton(
                              tooltip: 'Back',
                              icon: const Icon(Icons.arrow_back_ios_new),
                              onPressed: () =>
                                  Navigator.of(detailContext).pop(),
                            ),
                            trailing: IconButton(
                              tooltip: 'Close',
                              icon: const Icon(Icons.close),
                              onPressed: () => Navigator.of(context).pop(),
                            ),
                            child: UserProfileSheet(
                              pubkey: pubkey,
                              contextualActions: (_) => DeleteAgentAction(
                                controller: controller,
                                pubkey: pubkey,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                  if (channel != null && context.mounted) {
                    Navigator.of(context).pop(channel);
                  }
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Only registry identities with verified owner profiles on this relay belong
/// in its list. Account-wide registry entries alone are not community membership.
Future<Set<String>> registeredCommunityAgents(
  List<Map<String, dynamic>> agents,
  String? owner,
  Future<List<NostrEvent>> Function(NostrFilter) fetch,
) async {
  if (agents.isEmpty || owner == null) return {};
  final keys = agents.map((agent) => agent['agent_pubkey'] as String).toSet();
  final events = await fetch(NostrFilters.profilesBatch(keys.toList()));
  return {
    for (final event in events)
      if (keys.contains(event.pubkey) &&
          verifiedOaOwnerPubkey(event.tags, event.pubkey) == owner)
        event.pubkey,
  };
}

class PrototypeAgentsSheet extends HookConsumerWidget {
  const PrototypeAgentsSheet({
    required this.controller,
    required this.onClose,
    required this.onSelect,
    super.key,
  });
  final VoidCallback onClose;
  final ValueChanged<String> onSelect;
  final RemoteAgentController controller;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    useListenable(controller);
    final community = ref.watch(activeCommunityProvider).asData?.value;
    final directory = ref.watch(agentDirectoryProvider);
    final registryFuture = useMemoized(
      () => registeredCommunityAgents(
        controller.agents,
        controller.owner,
        ref.read(relaySessionProvider.notifier).fetchHistory,
      ),
      [community?.relayUrl, controller.agents, controller.owner],
    );
    final registered = useFuture(registryFuture, preserveState: false);
    final keys = {
      ...?registered.data,
      for (final entry in directory.asData?.value ?? <AgentDirectoryEntry>[])
        entry.pubkey,
    }.where((key) => !controller.deletedAgents.contains(key)).toList();
    final names = watchIdentityNames(
      ref,
      keys,
      agentPubkeys: keys.toSet(),
      fallbackNames: {
        for (final agent in controller.agents)
          agent['agent_pubkey'] as String: agent['agent_name'] as String,
      },
    );
    keys.sort((a, b) => names.labelFor(a).compareTo(names.labelFor(b)));
    final profiles = ref.watch(userCacheProvider);
    final failed = directory.hasError || registered.hasError;
    final loading =
        controller.busy ||
        directory.isLoading ||
        registered.connectionState != ConnectionState.done;

    Future<void> refresh() async {
      await controller.run(controller.refresh);
      if (context.mounted) ref.invalidate(agentDirectoryProvider);
    }

    return SizedBox(
      height: MediaQuery.sizeOf(context).height * .72,
      child: BuzzTitledSheetLayout(
        title: 'Agents',
        leading: IconButton(
          tooltip: 'Close',
          icon: const Icon(Icons.close),
          onPressed: onClose,
        ),
        trailing: IconButton(
          tooltip: 'Add agent',
          onPressed: community == null || controller.busy
              ? null
              : () => showBuzzModalBottomSheet<bool>(
                  context: context,
                  isScrollControlled: true,
                  showCloseButton: false,
                  builder: (_) => CreatePrototypeAgentSheet(
                    controller: controller,
                    community: community,
                    onCreated: () => ref.invalidate(agentDirectoryProvider),
                  ),
                ),
          icon: const Icon(Icons.add),
        ),
        child: Material(
          color: Colors.transparent,
          child: RefreshIndicator(
            onRefresh: refresh,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(Grid.xs, 0, Grid.xs, Grid.sm),
              children: [
                if (loading) const LinearProgressIndicator(),
                if (controller.account.account == null)
                  ListTile(
                    title: const Text('Sign in to create an agent'),
                    subtitle: controller.busy ? Text(controller.status) : null,
                    trailing: TextButton(
                      onPressed: controller.busy ? null : controller.signIn,
                      child: const Text('Sign in'),
                    ),
                  ),
                if (failed)
                  ListTile(
                    title: const Text('Could not load agents'),
                    trailing: TextButton(
                      onPressed: refresh,
                      child: const Text('Retry'),
                    ),
                  ),
                if (!loading && !failed && keys.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(Grid.sm),
                    child: Text(
                      'No agents in this community yet.',
                      textAlign: TextAlign.center,
                    ),
                  ),
                for (final key in keys)
                  ListTile(
                    key: ValueKey(key),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: Grid.xxs,
                      vertical: Grid.xxs,
                    ),
                    leading: AvatarImage(
                      imageUrl: profiles[key]?.avatarUrl,
                      radius: Grid.sm,
                      isAgent: true,
                      backgroundColor: context.colors.surfaceContainerHighest,
                      fallback: Center(
                        child: Text(names.labelFor(key).characters.first),
                      ),
                    ),
                    title: Text(names.labelFor(key)),
                    onTap: () => onSelect(key),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
