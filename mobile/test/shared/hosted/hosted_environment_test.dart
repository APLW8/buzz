import 'package:buzz/shared/hosted/hosted_environment.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('community realms map only to their trusted account origin', () {
    expect(
      HostedEnvironment.accountOriginFor(
        Uri.parse('wss://team.communities.buzz.xyz'),
      ),
      Uri.parse('https://app.builderlab.xyz'),
    );
    expect(
      HostedEnvironment.accountOriginFor(
        Uri.parse('wss://team.communities.public.builderlabstaging.xyz'),
      ),
      Uri.parse('https://app.builderlabstaging.xyz'),
    );
    for (final host in [
      'team.communities.test.blockstaging.build',
      'buzz.test.blockstaging.build',
    ]) {
      expect(
        HostedEnvironment.accountOriginFor(Uri.parse('wss://$host')),
        Uri.parse('https://test.blockstaging.build'),
      );
    }
    for (final value in [
      'wss://test.blockstaging.build',
      'wss://buzz-push.test.blockstaging.build',
      'wss://other.test.blockstaging.build',
      'wss://buzz.test.blockstaging.build.attacker.test',
      'wss://buzz.test.blockstaging.build.',
      'wss://buzz.test.blockstaging.build:8443',
      'wss://user@buzz.test.blockstaging.build',
      'wss://buzz.test.blockstaging.build/path',
      'wss://buzz.test.blockstaging.build?account=other',
      'wss://communities.test.blockstaging.build',
      'wss://team.communities.public.builderlabstaging.xyz.attacker.test',
      'wss://communities.public.builderlabstaging.xyz',
      'wss://team.communities.public.builderlabstaging.xyz.',
      'wss://team.communities.public.builderlabstaging.xyz:8443',
      'ws://team.communities.public.builderlabstaging.xyz',
      'wss://user@team.communities.public.builderlabstaging.xyz',
      'wss://team.communities.public.builderlabstaging.xyz/path',
      'wss://team.communities.public.builderlabstaging.xyz?account=other',
      'wss://team.communities.public.builderlabstaging.xyz#fragment',
      'wss://team.builderlabstaging.xyz',
    ]) {
      expect(
        HostedEnvironment.accountOriginFor(Uri.parse(value)),
        isNull,
        reason: value,
      );
    }
  });

  test('selected build never accepts another account realm', () {
    for (final (relay, account) in [
      ('wss://a.communities.buzz.xyz', 'https://app.builderlab.xyz'),
      (
        'wss://a.communities.public.builderlabstaging.xyz',
        'https://app.builderlabstaging.xyz',
      ),
      (
        'wss://a.communities.test.blockstaging.build',
        'https://test.blockstaging.build',
      ),
      ('wss://buzz.test.blockstaging.build', 'https://test.blockstaging.build'),
    ]) {
      expect(
        HostedEnvironment.supportsRelay(Uri.parse(relay)),
        HostedEnvironment.origin == Uri.parse(account),
      );
    }
  });

  test('authentication follows only configured DNS domain boundaries', () {
    expect(HostedEnvironment.enabled, HostedEnvironment.authDomains.isNotEmpty);
    for (final domain in HostedEnvironment.authDomains) {
      for (final host in [
        domain,
        'team.$domain',
        'TEAM.${domain.toUpperCase()}.',
      ]) {
        expect(HostedEnvironment.requiresAuth(host), isTrue, reason: host);
      }
      expect(HostedEnvironment.requiresAuth('$domain.attacker.test'), isFalse);
      expect(HostedEnvironment.requiresAuth('not$domain'), isFalse);
    }
    if (HostedEnvironment.authDomains.isEmpty) {
      for (final host in [
        'buzz.xyz',
        'team.communities.buzz.xyz',
        'team.communities.public.builderlabstaging.xyz',
      ]) {
        expect(HostedEnvironment.requiresAuth(host), isFalse);
      }
    }
  });
}
