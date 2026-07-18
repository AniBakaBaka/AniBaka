import 'package:test/test.dart';

import 'package:baka/services/source/rule_repository_service.dart';

void main() {
  test('default Rule Hub subscription follows AniBakaRule directly', () {
    final uri = Uri.parse(RuleRepositoryService.remoteSubscription);

    expect(uri.scheme, 'https');
    expect(uri.host, 'raw.githubusercontent.com');
    expect(uri.path, '/AniBakaBaka/AniBakaRule/main/index.json');
    expect(
      RuleRepositoryService.defaultSubscription,
      RuleRepositoryService.remoteSubscription,
    );
    expect(
      RuleRepositoryService.remoteSubscription,
      isNot(contains('jsdelivr')),
    );
  });
}
