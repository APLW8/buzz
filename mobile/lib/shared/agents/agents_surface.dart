import 'package:flutter/widgets.dart';
import '../deeplink/deep_link.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// Optional agent-management entry point supplied by the app composition root.
final agentsSurfaceProvider = Provider<void Function(BuildContext)?>(
  (ref) => null,
);

/// Exact public keys whose remote service has confirmed ACTIVE lifecycle.
/// Remote workers wake on messages, so this means available, not socket presence.
final availableRemoteAgentsProvider = Provider<Set<String>>((ref) => const {});

/// Optional composition handler for editable agent drafts from external links.
final agentCreationSurfaceProvider =
    Provider<Future<void> Function(BuildContext, AgentCreationDeepLink)?>(
      (ref) => null,
    );

/// Owner-definition artwork supplied by the remote-agent composition root.
/// This is separate from the agent's signed kind-0 profile.
final agentDefinitionAvatarsProvider = Provider<Map<String, String>>(
  (ref) => const {},
);
