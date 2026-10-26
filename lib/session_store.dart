import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'secure_storage.dart';

/// Being logged in: the token the backend issued, and what it says about it.
class Session {
  const Session({
    required this.token,
    required this.username,
    required this.expiresAt,
  });

  factory Session.fromJson(Map<String, dynamic> json) => Session(
    token: json['token'] as String,
    username: json['username'] as String,
    expiresAt: DateTime.parse(json['expiresAt'] as String),
  );

  /// Sent as `Authorization: Bearer <token>` with every backend request.
  /// Anyone holding it can act as this admin until it expires, so it lives
  /// in secure storage and is never logged.
  final String token;

  final String username;

  /// When the backend stops accepting [token]. Checked here too, so an
  /// expired session goes straight to the login screen without a wasted
  /// request. The backend's own check is the one that actually counts.
  final DateTime expiresAt;

  bool get isExpired => !DateTime.now().isBefore(expiresAt);

  Map<String, dynamic> toJson() => {
    'token': token,
    'username': username,
    'expiresAt': expiresAt.toUtc().toIso8601String(),
  };
}

/// Keeps the [Session] across app restarts.
class SessionStore {
  SessionStore({FlutterSecureStorage? storage})
    : _storage = storage ?? appSecureStorage;

  final FlutterSecureStorage _storage;

  /// Deliberately outside the `lock/` and `tombstone/` prefixes, so it can
  /// never be mistaken for a lock or a pending delete.
  static const String _key = 'session';

  Future<void> save(Session session) =>
      _storage.write(key: _key, value: jsonEncode(session.toJson()));

  /// The saved session, or null if there is none or it is unreadable.
  /// An expired session is still returned; the caller decides what to do.
  Future<Session?> load() async {
    final raw = await _storage.read(key: _key);
    if (raw == null) return null;
    try {
      return Session.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  /// Logs out on this phone. Touches only the session, never the locks:
  /// logging out must not delete the credentials that open doors.
  Future<void> clear() => _storage.delete(key: _key);
}
