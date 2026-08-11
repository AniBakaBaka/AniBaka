import 'package:baka/instance.dart';
import 'package:baka/widgets/home/swiper_banner.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    Instances.sp = await SharedPreferences.getInstance();
  });

  testWidgets('banner uses the infinite Flutter carousel', (tester) async {
    final swiperData = <Map>[
      {
        'title': 'First banner',
        'bannerImageUrl': 'https://example.invalid/first.jpg',
      },
      {
        'title': 'Second banner',
        'bannerImageUrl': 'https://example.invalid/second.jpg',
      },
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 800,
            height: 320,
            child: SwiperBanner(swiperData: swiperData),
          ),
        ),
      ),
    );
    await tester.pump();

    final carousel = tester.widget<CarouselView>(find.byType(CarouselView));
    expect(carousel.infinite, isTrue);
    expect(carousel.itemSnapping, isTrue);
    expect(find.text('First banner'), findsOneWidget);

    await tester.drag(find.byType(CarouselView), const Offset(-700, 0));
    await tester.pumpAndSettle();

    expect(find.text('Second banner'), findsOneWidget);
  });
}
