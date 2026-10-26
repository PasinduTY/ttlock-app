import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'session_store.dart';

/// Where the backend lives.
///
/// The default reaches the PC over USB via `adb reverse tcp:5007 tcp:5007`.
/// Point a build somewhere else without touching code:
///
///     flutter run --dart-define=BACKEND_URL=https://example.com
const String backendBaseUrl = String.fromEnvironment(
  'BACKEND_URL',
  defaultValue: 'http://localhost:5007',
);

/// Outcome of asking the backend whether it is up.
sealed class HealthResult {
  const HealthResult();
}

class HealthOk extends HealthResult {
  const HealthOk(this.serverTime);

  /// The server's clock, in UTC. Handy for spotting a phone with a wrong clock.
  final DateTime serverTime;
}

/// Nothing answered: server not running, `adb reverse` missing, wrong
/// address, or no network.
class HealthUnreachable extends HealthResult {
  const HealthUnreachable(this.reason);

  final String reason;
}

/// Something answered, but not the way our backend does. Usually the wrong
/// address, or a server error.
class HealthBadResponse extends HealthResult {
  const HealthBadResponse(this.reason);

  final String reason;
}

/// A lock as the backend holds it.
class RemoteLock {
  const RemoteLock({
    required this.mac,
    required this.name,
    required this.lockData,
    required this.lockVersion,
    required this.updatedAt,
  });

  factory RemoteLock.fromJson(Map<String, dynamic> json) => RemoteLock(
    mac: json['mac'] as String,
    name: json['name'] as String,
    lockData: json['lockData'] as String,
    lockVersion: json['lockVersion'] as String,
    updatedAt: DateTime.parse(json['updatedAt'] as String),
  );

  final String mac;
  final String name;
  final String lockData;
  final String lockVersion;
  final DateTime updatedAt;
}

/// Outcome of a call to the `/locks` endpoints. [T] is what a success
/// carries: a list of locks, or nothing at all for upload and delete.
sealed class BackendResult<T> {
  const BackendResult();
}

class BackendOk<T> extends BackendResult<T> {
  const BackendOk(this.value);

  final T value;
}

/// The request never got an answer. Worth retrying later.
class BackendUnreachable<T> extends BackendResult<T> {
  const BackendUnreachable(this.reason);

  final String reason;
}

/// The server answered, but with a refusal or something unexpected.
/// Retrying the same request will not help.
class BackendError<T> extends BackendResult<T> {
  const BackendError(this.reason);

  final String reason;
}

/// HTTP 401. Outside of login, it means the token is missing, expired, or
/// belongs to an account that was removed: the user has to log in again.
/// From [BackendClient.login], it means a wrong username or password.
class BackendUnauthorized<T> extends BackendResult<T> {
  const BackendUnauthorized();
}

/// Every call to our backend goes through here, the way every SDK call goes
/// through `lock_service.dart`. Widgets never build URLs or parse JSON.
class BackendClient {
  BackendClient({http.Client? client, String baseUrl = backendBaseUrl})
    : _client = client ?? http.Client(),
      _baseUrl = baseUrl.endsWith('/')
          ? baseUrl.substring(0, baseUrl.length - 1)
          : baseUrl;

  final http.Client _client;
  final String _baseUrl;

  /// The current login token, sent with every request while set. The app
  /// sets it after logging in or loading a saved session, and clears it on
  /// logout or when the backend answers 401.
  String? token;

  /// Without this, a request to a machine that never answers can hang for
  /// well over a minute before failing.
  static const Duration _timeout = Duration(seconds: 5);

  String get baseUrl => _baseUrl;

  /// Logs in. A [BackendUnauthorized] result means a wrong username or
  /// password; the backend deliberately doesn't say which.
  ///
  /// Does not set [token]: the caller saves the session first, then sets it,
  /// so a crash between the two can't leave a login that isn't remembered.
  Future<BackendResult<Session>> login(String username, String password) async {
    final http.Response response;
    final request = _send(
      () => _client.post(
        Uri.parse('$_baseUrl/auth/login'),
        headers: const {'Content-Type': 'application/json'},
        body: jsonEncode({'username': username, 'password': password}),
      ),
    );
    switch (await request) {
      case BackendOk(:final value):
        response = value;
      case BackendUnreachable(:final reason):
        return BackendUnreachable(reason);
      case BackendError(:final reason):
        return BackendError(reason);
      case BackendUnauthorized():
        return const BackendUnauthorized();
    }

    if (response.statusCode != 200) {
      return BackendError('Login failed: HTTP ${response.statusCode}.');
    }

    try {
      return BackendOk(
        Session.fromJson(jsonDecode(response.body) as Map<String, dynamic>),
      );
    } catch (_) {
      return const BackendError(
        'The login reply was not in the expected format.',
      );
    }
  }

  Future<HealthResult> checkHealth() async {
    final http.Response response;
    try {
      response = await _client
          .get(Uri.parse('$_baseUrl/health'))
          .timeout(_timeout);
    } on TimeoutException {
      return HealthUnreachable('No answer within ${_timeout.inSeconds} s.');
    } on http.ClientException catch (error) {
      // Connection refused, unknown host, no network.
      return HealthUnreachable(error.message);
    }

    if (response.statusCode != 200) {
      return HealthBadResponse('HTTP ${response.statusCode}.');
    }

    try {
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      return HealthOk(DateTime.parse(body['time'] as String));
    } catch (_) {
      return const HealthBadResponse('The reply was not what /health sends.');
    }
  }

  /// Every lock the backend holds.
  Future<BackendResult<List<RemoteLock>>> listLocks() async {
    final http.Response response;
    switch (await _send(() => _client.get(_locksUri(), headers: _headers()))) {
      case BackendOk(:final value):
        response = value;
      case BackendUnreachable(:final reason):
        return BackendUnreachable(reason);
      case BackendError(:final reason):
        return BackendError(reason);
      case BackendUnauthorized():
        return const BackendUnauthorized();
    }

    if (response.statusCode != 200) {
      return BackendError('Listing locks failed: HTTP ${response.statusCode}.');
    }

    try {
      final list = jsonDecode(response.body) as List<dynamic>;
      return BackendOk([
        for (final item in list)
          RemoteLock.fromJson(item as Map<String, dynamic>),
      ]);
    } catch (_) {
      return const BackendError(
        'The lock list was not in the expected format.',
      );
    }
  }

  /// Makes the backend hold exactly this lock, creating or replacing it.
  ///
  /// Tries POST first. A 409 means the backend already has this MAC, and the
  /// copy being uploaded wins: it comes from an initialisation on this phone,
  /// which wrote new key material and made any older lockData dead.
  Future<BackendResult<void>> uploadLock({
    required String mac,
    required String name,
    required String lockData,
    required String lockVersion,
  }) async {
    final http.Response createResponse;
    final create = _send(
      () => _client.post(
        _locksUri(),
        headers: _headers(json: true),
        body: jsonEncode({
          'mac': mac,
          'name': name,
          'lockData': lockData,
          'lockVersion': lockVersion,
        }),
      ),
    );
    switch (await create) {
      case BackendOk(:final value):
        createResponse = value;
      case BackendUnreachable(:final reason):
        return BackendUnreachable(reason);
      case BackendError(:final reason):
        return BackendError(reason);
      case BackendUnauthorized():
        return const BackendUnauthorized();
    }

    if (createResponse.statusCode == 201) return const BackendOk(null);
    if (createResponse.statusCode != 409) {
      return BackendError(
        'Uploading the lock failed: HTTP ${createResponse.statusCode}.',
      );
    }

    final http.Response replaceResponse;
    final replace = _send(
      () => _client.put(
        _locksUri(mac),
        headers: _headers(json: true),
        body: jsonEncode({
          'name': name,
          'lockData': lockData,
          'lockVersion': lockVersion,
        }),
      ),
    );
    switch (await replace) {
      case BackendOk(:final value):
        replaceResponse = value;
      case BackendUnreachable(:final reason):
        return BackendUnreachable(reason);
      case BackendError(:final reason):
        return BackendError(reason);
      case BackendUnauthorized():
        return const BackendUnauthorized();
    }

    return replaceResponse.statusCode == 200
        ? const BackendOk(null)
        : BackendError(
            'Replacing the lock failed: HTTP ${replaceResponse.statusCode}.',
          );
  }

  /// Removes a lock from the backend.
  ///
  /// A 404 counts as success: the goal is "the backend no longer has it", and
  /// it doesn't. That makes retrying a delete safe, which tombstones rely on.
  Future<BackendResult<void>> deleteLock(String mac) async {
    final http.Response response;
    switch (await _send(
      () => _client.delete(_locksUri(mac), headers: _headers()),
    )) {
      case BackendOk(:final value):
        response = value;
      case BackendUnreachable(:final reason):
        return BackendUnreachable(reason);
      case BackendError(:final reason):
        return BackendError(reason);
      case BackendUnauthorized():
        return const BackendUnauthorized();
    }

    return response.statusCode == 204 || response.statusCode == 404
        ? const BackendOk(null)
        : BackendError(
            'Deleting the lock failed: HTTP ${response.statusCode}.',
          );
  }

  /// Headers for a `/locks` request. The one place the token is attached,
  /// so no request can forget it.
  Map<String, String> _headers({bool json = false}) => {
    if (json) 'Content-Type': 'application/json',
    if (token case final token?) 'Authorization': 'Bearer $token',
  };

  /// `/locks`, or `/locks/<mac>`. The MAC is percent-encoded so its colons
  /// can never be misread as part of the URL's structure.
  Uri _locksUri([String? mac]) => Uri.parse(
    mac == null
        ? '$_baseUrl/locks'
        : '$_baseUrl/locks/${Uri.encodeComponent(mac)}',
  );

  /// Runs one request, turning "no answer" into [BackendUnreachable] and a
  /// 401 into [BackendUnauthorized], so each caller only has to think about
  /// the answers specific to it.
  Future<BackendResult<http.Response>> _send(
    Future<http.Response> Function() request,
  ) async {
    try {
      final response = await request().timeout(_timeout);
      if (response.statusCode == 401) return const BackendUnauthorized();
      return BackendOk(response);
    } on TimeoutException {
      return BackendUnreachable('No answer within ${_timeout.inSeconds} s.');
    } on http.ClientException catch (error) {
      return BackendUnreachable(error.message);
    }
  }

  /// Releases the connection pool. Call when the owner is disposed.
  void close() => _client.close();
}
