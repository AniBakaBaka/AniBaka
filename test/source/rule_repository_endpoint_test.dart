import 'package:test/test.dart';

import 'package:baka/services/source/rule_repository_service.dart';

void main() {
  test('default Rule Hub subscription uses the AniBakaRule accelerator', () {
    final uri = Uri.parse(RuleRepositoryService.remoteSubscription);

    expect(uri.scheme, 'https');
    expect(uri.host, 'gh.dpik.top');
    expect(
      uri.path,
      '/https://raw.githubusercontent.com/AniBakaBaka/AniBakaRule/main/index.json',
    );
    expect(
      RuleRepositoryService.defaultSubscription,
      RuleRepositoryService.acceleratedSubscription,
    );
    expect(
      RuleRepositoryService.jsDelivrSubscription,
      'https://cdn.jsdelivr.net/gh/AniBakaBaka/AniBakaRule@main/index.json',
    );
    expect(
      RuleRepositoryService.directSubscription,
      'https://raw.githubusercontent.com/AniBakaBaka/AniBakaRule/main/index.json',
    );
    expect(
      RuleRepositoryService.resolveRuleUrl(
        RuleRepositoryService.remoteSubscription,
        '7sefun.json',
      ),
      'https://gh.dpik.top/https://raw.githubusercontent.com/'
      'AniBakaBaka/AniBakaRule/main/7sefun.json',
    );
  });
}
