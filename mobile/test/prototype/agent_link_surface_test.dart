import 'dart:async';
import 'dart:convert';
import 'package:buzz/features/channels/deep_link_dispatcher.dart';
import 'package:buzz/prototype/agent_link_surface.dart';
import 'package:buzz/prototype/create_agent_sheet.dart';
import 'package:buzz/prototype/remote_agent_controller.dart';
import 'package:buzz/shared/agents/agents_surface.dart';
import 'package:buzz/shared/community/community.dart';
import 'package:buzz/shared/community/community_provider.dart';
import 'package:buzz/shared/deeplink/deep_link.dart';
import 'package:buzz/shared/deeplink/pending_deep_link_provider.dart';
import 'package:buzz/shared/hosted/account_identity_store.dart';
import 'package:buzz/shared/hosted/browser_auth.dart';
import 'package:buzz/shared/hosted/hosted_relay_auth.dart';
import 'package:buzz/shared/theme/theme.dart';
import 'package:buzz/shared/widgets/avatar_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'remote_agent_controller_test.dart' show BoundAccount;

class _Controller extends RemoteAgentController {
  _Controller(BoundAccount account)
    : super(
        account: account,
        keys: AccountIdentityStore(),
        browser: BrowserAuth(),
        relayAuth: HostedRelayAuth(account),
      );
  final hydrated = Completer<void>();
  String? submittedName;
  String? submittedInstructions;
  Object? submittedAvatar;
  @override
  Future<void> initialize() => hydrated.future;
  @override
  Future<void> ensureBinding() async {
    owner = 'owner';
  }

  @override
  Future<void> selectCommunity(AddCommunityDeepLink value) async {
    community = value;
  }

  @override
  Future<bool> create(
    String name, {
    String instructions = '',
    Object? avatar,
  }) async {
    submittedName = name;
    submittedInstructions = instructions;
    submittedAvatar = avatar;
    return true;
  }
}

void main() {
  for (final cold in [true, false]) {
    testWidgets(
      'external draft waits for hydration, editable and never auto-creates: cold=$cold',
      (tester) async {
        final stream = StreamController<Uri>();
        PendingDeepLinkNotifier.debugUriStreamOverride = stream.stream;
        final account = BoundAccount('owner');
        final controller = _Controller(account);
        final community = Completer<Community?>();
        final payload = {
          'v': 1,
          'name': 'QR Scout',
          'instructions': 'Answer briefly.',
          'avatar': {'emoji': '🦉', 'color': '#476CFF'},
        };
        final uri = Uri.parse(
          'buzz://agent/new#${base64Url.encode(utf8.encode(jsonEncode(payload))).replaceAll('=', '')}',
        );
        addTearDown(() {
          PendingDeepLinkNotifier.debugUriStreamOverride = null;
          stream.close();
          controller.dispose();
          controller.relayAuth.dispose();
          account.dispose();
        });
        final ready = ValueNotifier(!cold);
        addTearDown(ready.dispose);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              activeCommunityProvider.overrideWith((ref) => community.future),
              agentCreationSurfaceProvider.overrideWithValue(
                (context, draft) =>
                    showAgentLinkCreate(context, controller, draft),
              ),
            ],
            child: MaterialApp(
              theme: AppTheme.light(),
              home: ValueListenableBuilder<bool>(
                valueListenable: ready,
                builder: (context, active, _) => DeepLinkDispatcher(
                  dispatchMessageLinks: active,
                  child: const Scaffold(body: Text('Current community')),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        stream.add(uri);
        await tester.pump();
        expect(find.byType(CreatePrototypeAgentSheet), findsNothing);
        expect(controller.submittedName, isNull);
        ready.value = true;
        controller.hydrated.complete();
        await tester.pump();
        expect(find.byType(CreatePrototypeAgentSheet), findsNothing);
        community.complete(
          Community.create(
            name: 'Test community',
            relayUrl: 'wss://test.example',
            pubkey: 'owner',
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Create in Test community'), findsOneWidget);
        expect(find.byType(AvatarImage), findsOneWidget);
        expect(controller.submittedName, isNull);
        await tester.enterText(
          find.widgetWithText(TextField, 'Name'),
          'Edited Scout',
        );
        await tester.enterText(
          find.widgetWithText(TextField, 'Instructions'),
          'Edited instructions.',
        );
        await tester.pump();
        await tester.tap(find.byTooltip('Create'));
        await tester.pumpAndSettle();
        expect(controller.submittedName, 'Edited Scout');
        expect(controller.submittedInstructions, 'Edited instructions.');
        expect(controller.submittedAvatar, payload['avatar']);
        expect(find.byType(CreatePrototypeAgentSheet), findsNothing);
        expect(find.text('Current community'), findsOneWidget);
      },
    );
  }
}
