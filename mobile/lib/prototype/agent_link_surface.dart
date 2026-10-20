import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../shared/community/community_provider.dart';
import '../shared/deeplink/deep_link.dart';
import '../shared/mentions/agent_identity_provider.dart';
import '../shared/widgets/modal_presentation.dart';
import 'create_agent_sheet.dart';
import 'remote_agent_controller.dart';

/// Presents an editable draft over the current community, never auto-submitting.
Future<void> showAgentLinkCreate(
  BuildContext context,
  RemoteAgentController controller,
  AgentCreationDeepLink draft,
) async {
  final container = ProviderScope.containerOf(context);
  await controller.initialize();
  final community = await container.read(activeCommunityProvider.future);
  if (!context.mounted) return;
  if (community == null ||
      controller.account.account == null ||
      controller.busy ||
      controller.pending != null) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Sign in and finish any pending agent setup, then reopen this link.',
        ),
      ),
    );
    return;
  }
  await showBuzzModalBottomSheet<bool>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    showCloseButton: false,
    builder: (_) => CreatePrototypeAgentSheet(
      controller: controller,
      community: community,
      draft: draft,
      onCreated: () => container.invalidate(agentDirectoryProvider),
    ),
  );
}
