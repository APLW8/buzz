import 'package:flutter_test/flutter_test.dart';
import 'package:nostr/nostr.dart' as nostr;
import 'package:buzz/prototype/remote_agent_controller.dart';
import 'package:buzz/shared/crypto/nip_oa.dart';

void main() {
  test('owner proof verifies for only the provisioned agent key', () {
    final owner = nostr.Keys('0' * 63 + '1');
    final agent = nostr.Keys('0' * 63 + '2');
    final other = nostr.Keys('0' * 63 + '3');
    final auth = signOwnerAuthorization(owner, agent.public);
    expect(verifiedOaOwnerPubkey([auth], agent.public), owner.public);
    expect(verifiedOaOwnerPubkey([auth], other.public), isNull);
    expect(() => signOwnerAuthorization(owner, owner.public), throwsStateError);
  });
  test('backend disabled and missing statuses cannot count as activation', () {
    requireStatus({'status': 'ATTEST_AGENT_STATUS_ACTIVE'}, 'ACTIVE', 1);
    requireStatus({'status': 1}, 'ACTIVE', 1);
    expect(
      () => requireStatus(
        {'status': 'ATTEST_AGENT_STATUS_FEATURE_DISABLED'},
        'ACTIVE',
        1,
      ),
      throwsStateError,
    );
    expect(() => requireStatus({}, 'ACTIVE', 1), throwsStateError);
  });
}
