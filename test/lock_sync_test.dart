// Unit tests for LockSync, against an in-memory fake of the backend.
// Each test sets up both sides, runs a sync, and checks what each side holds.

import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ttlock_app/backend_client.dart';
import 'package:ttlock_app/lock_storage.dart';
import 'package:ttlock_app/lock_sync.dart';

const _mac = 'B0:94:A1:E1:31:8F';
const _otherMac = 'AA:BB:CC:DD:EE:01';

/// Behaves like the real /locks endpoints, keeping locks in a map.
class _FakeServer {
  final Map<String, Map<String, dynamic>> locks = {};

  /// When true, every request fails as if the server were switched off.
  bool down = false;

  /// When true, POST answers 400, as if the server rejected the upload.
  bool rejectUploads = false;

  /// Called whenever the lock list is requested, before answering.
  Future<void> Function()? onList;

  void put(String mac, String lockData, {String name = 'Door'}) =>
      locks[mac] = {
        'mac': mac,
        'name': name,
        'lockData': lockData,
        'lockVersion': '{}',
        'createdAt': '2026-10-24T12:00:00Z',
        'updatedAt': '2026-10-24T12:00:00Z',
      };

  BackendClient client() => BackendClient(
    baseUrl: 'http://test',
    client: MockClient((request) async {
      if (down) throw http.ClientException('connection refused');

      final segments = request.url.pathSegments; // already percent-decoded
      final mac = segments.length > 1 ? segments[1] : null;

      switch (request.method) {
        case 'GET':
          await onList?.call();
          return http.Response(jsonEncode(locks.values.toList()), 200);
        case 'POST':
          if (rejectUploads) return http.Response('{}', 400);
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          if (locks.containsKey(body['mac'])) return http.Response('""', 409);
          put(body['mac'] as String, body['lockData'] as String);
          return http.Response('{}', 201);
        case 'PUT':
          if (!locks.containsKey(mac)) return http.Response('', 404);
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          put(mac!, body['lockData'] as String);
          return http.Response('{}', 200);
        case 'DELETE':
          return http.Response('', locks.remove(mac) == null ? 404 : 204);
      }
      return http.Response('', 405);
    }),
  );
}

SavedLock _local(String lockData, {String mac = _mac, bool backedUp = false}) =>
    SavedLock(
      lockMac: mac,
      lockName: 'Door',
      lockData: lockData,
      lockVersion: '{}',
      savedAt: DateTime.utc(2026, 10, 24),
      backedUp: backedUp,
    );

void main() {
  late _FakeServer server;
  late LockStorage storage;
  late LockSync sync;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    server = _FakeServer();
    storage = LockStorage();
    sync = LockSync(storage: storage, backend: server.client());
  });

  test(
    'uploads a lock that is not backed up, then marks it backed up',
    () async {
      await storage.save(_local('MINE'));

      final report = await sync.run();

      expect(report.uploaded, 1);
      expect(server.locks[_mac]!['lockData'], 'MINE');
      expect((await storage.load(_mac))!.backedUp, isTrue);
    },
  );

  test('pulls a lock the phone does not have', () async {
    server.put(_mac, 'FROM-SERVER');

    final report = await sync.run();

    expect(report.pulled, 1);
    final pulled = (await storage.load(_mac))!;
    expect(pulled.lockData, 'FROM-SERVER');
    expect(pulled.backedUp, isTrue);
  });

  test('never deletes a local lock the backend does not have', () async {
    // As if the backend's database had been wiped.
    await storage.save(_local('MINE', backedUp: true));

    await sync.run();

    expect((await storage.load(_mac))!.lockData, 'MINE');
  });

  test(
    'a tombstone deletes on the backend, and the lock is not pulled back',
    () async {
      server.put(_mac, 'DEAD-AFTER-RESET');
      await storage.addTombstone(_mac);

      final report = await sync.run();

      expect(report.deleted, 1);
      expect(server.locks, isEmpty);
      expect(await storage.loadTombstones(), isEmpty);
      expect(await storage.load(_mac), isNull);
    },
  );

  test(
    'with the backend down, nothing is lost and the tombstone stays',
    () async {
      await storage.save(_local('MINE', mac: _otherMac));
      await storage.addTombstone(_mac);
      server.down = true;

      final report = await sync.run();

      expect(report.reachedBackend, isFalse);
      expect(await storage.loadTombstones(), {_mac});
      final mine = (await storage.load(_otherMac))!;
      expect(mine.lockData, 'MINE');
      expect(mine.backedUp, isFalse, reason: 'still waiting to be uploaded');
    },
  );

  test('a backed-up copy is replaced by a newer backend version', () async {
    // Another admin re-initialised the lock, so the backend has new lockData.
    await storage.save(_local('OLD', backedUp: true));
    server.put(_mac, 'NEW-FROM-OTHER-ADMIN');

    final report = await sync.run();

    expect(report.refreshed, 1);
    expect((await storage.load(_mac))!.lockData, 'NEW-FROM-OTHER-ADMIN');
  });

  test(
    'a copy not yet backed up is never overwritten by the backend',
    () async {
      // This phone has newer data the backend refused to take.
      await storage.save(_local('NEWEST-ON-PHONE'));
      server.put(_mac, 'OLDER-ON-SERVER');
      server.rejectUploads = true;

      final report = await sync.run();

      expect(report.problems, isNotEmpty);
      final mine = (await storage.load(_mac))!;
      expect(mine.lockData, 'NEWEST-ON-PHONE');
      expect(mine.backedUp, isFalse);
    },
  );

  test(
    'a lock saved mid-sync is uploaded by an extra pass, not missed',
    () async {
      // While the first pass is pulling (its upload step already done), a new
      // lock is initialised and another sync is requested.
      var firstList = true;
      server.onList = () async {
        if (!firstList) return;
        firstList = false;
        await storage.save(_local('JUST-INITIALISED', mac: _otherMac));
        sync.run();
      };

      await sync.run();

      expect(server.locks[_otherMac]!['lockData'], 'JUST-INITIALISED');
    },
  );
}
