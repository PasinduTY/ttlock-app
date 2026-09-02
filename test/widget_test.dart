// Smoke test for the scan screen.
//
// This runs on the host machine, not a phone, so it cannot exercise Bluetooth.
// It only checks that the screen builds and shows its starting state.

import 'package:flutter_test/flutter_test.dart';

import 'package:ttlock_app/main.dart';

void main() {
  testWidgets('Scan page starts empty with a Scan button', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const TTLockApp());

    expect(find.text('Scan'), findsOneWidget);
    expect(find.textContaining('No locks yet'), findsOneWidget);
  });
}
