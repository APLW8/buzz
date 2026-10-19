import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../shared/community/community.dart';
import '../shared/community/community_provider.dart';
import '../shared/deeplink/deep_link.dart';
import '../shared/theme/theme.dart';
import '../shared/widgets/buzz_titled_sheet_layout.dart';
import 'remote_agent_controller.dart';

/// Uses the registry's name and private-instructions contract. Runtime/model
/// selection belongs to the remote service and is not an API option here.
class CreatePrototypeAgentSheet extends HookConsumerWidget {
  const CreatePrototypeAgentSheet({
    required this.controller,
    required this.community,
    required this.onCreated,
    super.key,
  });
  final RemoteAgentController controller;
  final Community community;
  final VoidCallback onCreated;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    useListenable(controller);
    final name = useTextEditingController(
      text: controller.pending?['name'] as String? ?? '',
    );
    final instructions = useTextEditingController(
      text: controller.pending?['instructions'] as String? ?? '',
    );
    useListenable(name);
    final error = useState<String?>(null);
    final active = ref.watch(activeCommunityProvider).asData?.value;
    final sameCommunity = active?.id == community.id;
    final pending = controller.pending != null;

    Future<void> create() async {
      error.value = null;
      final prepared = await controller.run(() async {
        if (!sameCommunity) {
          throw StateError('The active community changed. Reopen Agents.');
        }
        await controller.ensureBinding();
        if (community.pubkey != controller.owner) {
          throw StateError('Sign in with the account for this community.');
        }
        if (controller.pending != null) {
          if (controller.pending!['community'] != community.relayUrl) {
            throw StateError(
              'Finish the pending setup in its original community.',
            );
          }
          controller.community = AddCommunityDeepLink(
            name: community.name,
            relayUrl: community.relayUrl,
          );
        } else {
          await controller.selectCommunity(
            AddCommunityDeepLink(
              name: community.name,
              relayUrl: community.relayUrl,
            ),
          );
        }
      });
      if (!prepared) {
        if (context.mounted) error.value = controller.status;
        return;
      }
      final success = await controller.create(
        name.text,
        instructions: instructions.text,
      );
      if (!context.mounted) return;
      if (success) {
        onCreated();
        Navigator.pop(context, true);
      } else {
        error.value = controller.status;
      }
    }

    return PopScope(
      canPop: !controller.busy,
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: BuzzTitledSheetLayout(
          title: 'Create agent',
          leading: TextButton(
            onPressed: controller.busy ? null : () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          trailing: TextButton(
            onPressed:
                controller.busy || !sameCommunity || name.text.trim().isEmpty
                ? null
                : create,
            child: Text(pending ? 'Resume' : 'Create'),
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(Grid.gutter),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: name,
                  autofocus: true,
                  enabled: !controller.busy && !pending,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(
                    labelText: 'Display name',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: Grid.sm),
                TextField(
                  controller: instructions,
                  enabled: !controller.busy && !pending,
                  minLines: 4,
                  maxLines: 7,
                  decoration: const InputDecoration(
                    labelText: 'Instructions (optional)',
                    hintText: 'Describe what this agent should do.',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: Grid.xs),
                Text(
                  'Runs remotely and responds to you in ${community.name}.',
                  style: context.textTheme.bodySmall,
                ),
                if (controller.busy) ...[
                  const SizedBox(height: Grid.xs),
                  const LinearProgressIndicator(),
                  Text(controller.status),
                ],
                if (error.value != null) ...[
                  const SizedBox(height: Grid.xs),
                  Text(
                    error.value!,
                    style: TextStyle(color: context.colors.error),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
