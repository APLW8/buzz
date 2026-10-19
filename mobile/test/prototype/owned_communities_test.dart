import 'package:buzz/prototype/owned_communities.dart';
import 'package:buzz/shared/hosted/builderlab_account.dart';
import 'package:buzz/shared/hosted/hosted_environment.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'explicit staging discovery uses owned route and rejects foreign relays',
    () async {
      final account = OwnedAccount();
      if (HostedEnvironment.origin.host != 'app.builderlabstaging.xyz') {
        await expectLater(
          loadPrototypeOwnedCommunities(account),
          throwsStateError,
        );
        expect(account.called, isFalse);
      } else {
        final communities = await loadPrototypeOwnedCommunities(account);
        expect(account.called, isTrue);
        expect(
          communities.single.relayUrl,
          'wss://prototype.communities.public.builderlabstaging.xyz',
        );
      }
      account.dispose();
    },
  );
}

class OwnedAccount extends BuilderlabAccountClient {
  bool called = false;
  @override
  Future<Map<String, dynamic>> post(
    String path,
    Map<String, dynamic> body,
  ) async {
    expect(path, '/v1/buzz/communities/list');
    expect(body, isEmpty);
    called = true;
    return {
      'communities': [
        {
          'name': 'prototype',
          'normalized_host':
              'prototype.communities.public.builderlabstaging.xyz',
        },
        {'name': 'foreign', 'normalized_host': 'foreign.communities.buzz.xyz'},
      ],
    };
  }
}
