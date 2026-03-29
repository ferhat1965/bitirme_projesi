// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bitirme/main.dart';

void main() {
  testWidgets('App shows main tab bar', (WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: RoadGuardApp()));

    expect(find.text('Kamera'), findsOneWidget);
    expect(find.text('Harita'), findsOneWidget);
    expect(find.text('Kayıtlar'), findsOneWidget);
    expect(find.text('Profil'), findsOneWidget);
  });
}
