// Regression test for the "BOTTOM OVERFLOWED BY 29 PIXELS" bug on the
// Active Ride screen's searching-for-driver map pin.
//
// The old inline pin stacked a 30px icon + a text chip (~47px) inside a
// 48x48 marker box — a guaranteed 29px RenderFlex overflow while a ride was
// unclaimed. _SearchingPin pins every row height (34 + 4 + 20 = 58 <= 64)
// and scales its text down, so it must lay out clean at any text scale.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:birr5/features/user/user_active_ride_screen.dart';
void main() {
  // The pin renders inside a Marker of width 96 / height 64.
  Future<void> pumpPin(WidgetTester tester, {required bool claimed}) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 96,
              height: 64,
              child: SearchingPin(claimed: claimed),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('searching pin fits its marker box (no overflow)',
      (tester) async {
    await pumpPin(tester, claimed: false);
    expect(tester.takeException(), isNull);
    // The chip text must still be visible on screen.
    expect(find.text('Searching for a driver…'), findsOneWidget);
  });

  testWidgets('waiting pin fits its marker box (no overflow)',
      (tester) async {
    await pumpPin(tester, claimed: true);
    expect(tester.takeException(), isNull);
    expect(find.text('Waiting for driver location…'), findsOneWidget);
  });

  testWidgets('searching pin fits with large accessibility text scale',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2.0)),
          child: Scaffold(
            body: Center(
              child: SizedBox(
                width: 96,
                height: 64,
                child: SearchingPin(claimed: false),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
