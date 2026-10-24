// Unit tests for LockStorage. setMockInitialValues swaps the Android Keystore
// for an in-memory map, so these run on this PC.

import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ttlock_app/lock_storage.dart';

const _mac = 'B0:94:A1:E1:31:8F';

SavedLock _lock({String mac = _mac, bool backedUp = false}) => SavedLock(
  lockMac: mac,
  lockName: 'Spare lock',
  lockData: 'FAKE',
  lockVersion: '{}',
  savedAt: DateTime.utc(2026, 9, 3),
  backedUp: backedUp,
);

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test(
    'a record saved before backedUp existed loads as not backed up',
    () async {
      // Exactly what the phone stored before this change: no backedUp field.
      FlutterSecureStorage.setMockInitialValues({
        'lock/$_mac': jsonEncode({
          'lockMac': _mac,
          'lockName': 'Spare lock',
          'lockData': 'FAKE',
          'lockVersion': '{}',
          'savedAt': '2026-09-03T00:00:00.000Z',
        }),
      });

      final loaded = await LockStorage().load(_mac);

      expect(loaded, isNotNull);
      expect(loaded!.backedUp, isFalse);
      expect(loaded.lockData, 'FAKE');
    },
  );

  test('backedUp survives a save and load', () async {
    final storage = LockStorage();
    await storage.save(_lock(backedUp: true));

    expect((await storage.load(_mac))!.backedUp, isTrue);
  });

  test('copyWith changes only what it is given', () {
    final original = _lock();
    final copy = original.copyWith(backedUp: true);

    expect(copy.backedUp, isTrue);
    expect(copy.lockMac, original.lockMac);
    expect(copy.lockData, original.lockData);
    expect(copy.savedAt, original.savedAt);
  });

  test('tombstones can be added and removed', () async {
    final storage = LockStorage();

    await storage.addTombstone(_mac);
    expect(await storage.loadTombstones(), {_mac});

    await storage.removeTombstone(_mac);
    expect(await storage.loadTombstones(), isEmpty);
  });

  test('tombstones and locks never appear in each other\'s lists', () async {
    final storage = LockStorage();
    await storage.save(_lock());
    await storage.addTombstone('AA:BB:CC:DD:EE:01');

    expect((await storage.loadAll()).map((l) => l.lockMac), [_mac]);
    expect(await storage.loadTombstones(), {'AA:BB:CC:DD:EE:01'});
  });

  test('one damaged record does not hide the others', () async {
    FlutterSecureStorage.setMockInitialValues({
      'lock/AA:BB:CC:DD:EE:01': 'not json at all',
      'lock/$_mac': jsonEncode(_lock().toJson()),
    });

    expect((await LockStorage().loadAll()).map((l) => l.lockMac), [_mac]);
  });
}
