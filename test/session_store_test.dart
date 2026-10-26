// Unit tests for SessionStore, with an in-memory stand-in for the Keystore.

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ttlock_app/lock_storage.dart';
import 'package:ttlock_app/session_store.dart';

Session _session({DateTime? expiresAt}) => Session(
  token: 'abc.def.ghi',
  username: 'pasindu',
  expiresAt: expiresAt ?? DateTime.now().toUtc().add(const Duration(days: 30)),
);

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test('a saved session survives a save and load', () async {
    final store = SessionStore();
    final original = _session(expiresAt: DateTime.utc(2026, 11, 25, 8));

    await store.save(original);
    final loaded = (await store.load())!;

    expect(loaded.token, original.token);
    expect(loaded.username, original.username);
    expect(loaded.expiresAt, original.expiresAt);
  });

  test('no saved session loads as null', () async {
    expect(await SessionStore().load(), isNull);
  });

  test('logging out clears the session but never touches the locks', () async {
    final store = SessionStore();
    final locks = LockStorage();
    await store.save(_session());
    await locks.save(
      SavedLock(
        lockMac: 'B0:94:A1:E1:31:8F',
        lockName: 'Spare lock',
        lockData: 'FAKE',
        lockVersion: '{}',
        savedAt: DateTime.utc(2026, 9, 3),
      ),
    );
    await locks.addTombstone('AA:BB:CC:DD:EE:01');

    await store.clear();

    expect(await store.load(), isNull);
    expect((await locks.loadAll()).single.lockData, 'FAKE');
    expect(await locks.loadTombstones(), {'AA:BB:CC:DD:EE:01'});
  });

  test('the session never shows up as a lock or a tombstone', () async {
    await SessionStore().save(_session());

    expect(await LockStorage().loadAll(), isEmpty);
    expect(await LockStorage().loadTombstones(), isEmpty);
  });

  test('isExpired tells past from future', () {
    expect(_session(expiresAt: DateTime.utc(2000)).isExpired, isTrue);
    expect(_session().isExpired, isFalse);
  });

  test('a damaged session loads as null instead of crashing', () async {
    FlutterSecureStorage.setMockInitialValues({'session': 'not json'});

    expect(await SessionStore().load(), isNull);
  });
}
