import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

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

  /// Without this, a request to a machine that never answers can hang for
  /// well over a minute before failing.
  static const Duration _timeout = Duration(seconds: 5);

  String get baseUrl => _baseUrl;

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

  /// Releases the connection pool. Call when the owner is disposed.
  void close() => _client.close();
}
