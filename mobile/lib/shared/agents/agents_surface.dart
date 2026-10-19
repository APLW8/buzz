import 'package:flutter/widgets.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// Optional agent-management entry point supplied by the app composition root.
final agentsSurfaceProvider = Provider<void Function(BuildContext)?>(
  (ref) => null,
);

/// Exact public keys whose remote service has confirmed ACTIVE lifecycle.
/// Remote workers wake on messages, so this means available, not socket presence.
final availableRemoteAgentsProvider = Provider<Set<String>>((ref) => const {});
