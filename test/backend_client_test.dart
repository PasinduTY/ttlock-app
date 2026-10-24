// Unit tests for BackendClient. They run on this PC with a fake HTTP client,
// so no server and no phone are needed, and the server can be made to answer
// in ways that are hard to arrange for real (a 409, a dropped connection).

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ttlock_app/backend_client.dart';

const _mac = 'AA:BB:CC:DD:EE:01';

/// A fake client that answers each request with the next canned response,
/// and records every request so tests can check what was actually sent.
({BackendClient client, List<http.Request> sent}) _fake(
  List<http.Response> responses,
) {
  final sent = <http.Request>[];
  final queue = [...responses];
  final mock = MockClient((request) async {
    sent.add(request);
    return queue.removeAt(0);
  });
  return (
    client: BackendClient(client: mock, baseUrl: 'http://test'),
    sent: sent,
  );
}

Future<BackendResult<void>> _upload(BackendClient client) => client.uploadLock(
  mac: _mac,
  name: 'Door',
  lockData: 'FAKE',
  lockVersion: '{}',
);

void main() {
  test('listLocks parses the lock list', () async {
    final (:client, :sent) = _fake([
      http.Response(
        jsonEncode([
          {
            'mac': _mac,
            'name': 'Door',
            'lockData': 'FAKE',
            'lockVersion': '{}',
            'createdAt': '2026-10-24T12:00:00Z',
            'updatedAt': '2026-10-24T12:00:00Z',
          },
        ]),
        200,
      ),
    ]);

    final result = await client.listLocks();

    expect(result, isA<BackendOk<List<RemoteLock>>>());
    final locks = (result as BackendOk<List<RemoteLock>>).value;
    expect(locks.single.mac, _mac);
    expect(locks.single.updatedAt.isUtc, isTrue);
    expect(sent.single.url.toString(), 'http://test/locks');
  });

  test('uploadLock: a new lock is a single POST', () async {
    final (:client, :sent) = _fake([http.Response('{}', 201)]);

    expect(await _upload(client), isA<BackendOk<void>>());
    expect(sent.map((r) => r.method), ['POST']);
  });

  test('uploadLock: a 409 is followed by a PUT that replaces it', () async {
    final (:client, :sent) = _fake([
      http.Response('"already registered"', 409),
      http.Response('{}', 200),
    ]);

    expect(await _upload(client), isA<BackendOk<void>>());
    expect(sent.map((r) => r.method), ['POST', 'PUT']);

    final put = sent[1];
    // Colons percent-encoded, so they can't be misread as URL structure.
    expect(put.url.path, '/locks/AA%3ABB%3ACC%3ADD%3AEE%3A01');
    expect(jsonDecode(put.body), {
      'name': 'Door',
      'lockData': 'FAKE',
      'lockVersion': '{}',
    });
  });

  test('uploadLock: a validation error does not fall back to PUT', () async {
    final (:client, :sent) = _fake([http.Response('{}', 400)]);

    expect(await _upload(client), isA<BackendError<void>>());
    expect(sent.map((r) => r.method), ['POST']);
  });

  test('deleteLock: 404 counts as success, so retries are safe', () async {
    final (:client, sent: _) = _fake([http.Response('', 404)]);

    expect(await client.deleteLock(_mac), isA<BackendOk<void>>());
  });

  test('no answer is reported as unreachable, not as an error', () async {
    final client = BackendClient(
      client: MockClient((_) async => throw http.ClientException('refused')),
      baseUrl: 'http://test',
    );

    expect(
      await client.listLocks(),
      isA<BackendUnreachable<List<RemoteLock>>>(),
    );
    expect(await _upload(client), isA<BackendUnreachable<void>>());
    expect(await client.deleteLock(_mac), isA<BackendUnreachable<void>>());
  });
}
