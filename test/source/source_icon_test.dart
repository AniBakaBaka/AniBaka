import 'package:baka/widgets/source/source_widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('source website icon prefers an explicit icon', () {
    expect(
      sourceWebsiteIconUrl(
        iconUrl: 'https://cdn.example/icon.png',
        baseUrl: 'https://site.example/path',
      ),
      'https://cdn.example/icon.png',
    );
  });

  test('source website icon fills a missing icon from the website origin', () {
    expect(
      sourceWebsiteIconUrl(baseUrl: 'https://site.example:8443/path?q=1'),
      'https://site.example:8443/favicon.ico',
    );
    expect(sourceWebsiteIconUrl(baseUrl: 'not a website'), isNull);
  });
}
