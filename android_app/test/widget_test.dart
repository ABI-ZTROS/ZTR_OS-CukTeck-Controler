import 'package:flutter_test/flutter_test.dart';

import 'package:cuktech_controller/main.dart';

void main() {
  testWidgets('App smoke test', (WidgetTester tester) async {
    // Build our app and trigger a frame.
    await tester.pumpWidget(const CukTechControllerApp());

    // Verify that the app renders without crashing.
    expect(find.byType(CukTechControllerApp), findsOneWidget);
  });
}
