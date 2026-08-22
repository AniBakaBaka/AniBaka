import 'package:baka/app_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('AppUser parses the documented login user contract', () {
    final user = AppUser.fromJson({
      'id': 7,
      'name': 'baka',
      'pwd': 'server-marker',
      'level': 2,
      'qq': '123456',
      'sign': 'hello',
    });

    expect(user.id, 7);
    expect(user.name, 'baka');
    expect(user.level, 2);
    expect(user.hasPassword, isTrue);
    expect(user.toJson()['qq'], '123456');
  });

  test('AppUser retains only the password marker after profile updates', () {
    final user = AppUser.fromJson({
      'id': 7,
      'name': 'new',
      'level': 2,
      'qq': '123456',
      'sign': 'hello',
    }, retainedPasswordMarker: '');

    expect(user.hasPassword, isTrue);
    expect(user.passwordMarker, isEmpty);
  });
}
