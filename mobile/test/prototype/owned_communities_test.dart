import 'package:buzz/prototype/owned_communities.dart';
import 'package:buzz/shared/hosted/builderlab_account.dart';
import 'package:buzz/shared/hosted/hosted_environment.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'explicit discovery uses owned route and rejects other account realms',
    () async {
      final account = OwnedAccount();
      final communities = await loadPrototypeOwnedCommunities(account);
      expect(account.called, isTrue);
      expect(
        communities.single.relayUrl,
        'wss://prototype.${HostedEnvironment.communitySuffix}',
      );
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
        {'name': 'public', 'normalized_host': 'prototype.communities.buzz.xyz'},
        {
          'name': 'block',
          'normalized_host': 'prototype.communities.test.blockstaging.build',
        },
      ],
    };
  }
}
