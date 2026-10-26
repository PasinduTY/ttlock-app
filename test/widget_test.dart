// Widget tests for start-up. These run on the host machine, not a phone, so
// they cannot exercise Bluetooth; they check what the user sees first.

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ttlock_app/main.dart';

void main() {
  // Nothing stored: as on a fresh install.
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  testWidgets('a fresh start offers the login screen', (tester) async {
    await tester.pumpWidget(const TTLockApp());
    await tester.pumpAndSettle();

    expect(find.text('Username'), findsOneWidget);
    expect(find.text('Password'), findsOneWidget);
    expect(find.textContaining('still unlock without signing in'), findsOne);
  });

  testWidgets('backing out of login leaves a working lock list', (
    tester,
  ) async {
    await tester.pumpWidget(const TTLockApp());
    await tester.pumpAndSettle();

    await tester.pageBack();
    await tester.pumpAndSettle();

    expect(find.text('Scan'), findsOneWidget);
    expect(find.textContaining('No locks yet'), findsOneWidget);
    expect(find.textContaining('Not signed in'), findsOneWidget);
  });
}
