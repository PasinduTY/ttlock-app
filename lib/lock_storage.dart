import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// A lock this phone has initialised, with everything needed to talk to it
/// again after a restart.
class SavedLock {
  const SavedLock({
    required this.lockMac,
    required this.lockName,
    required this.lockData,
    required this.lockVersion,
    required this.savedAt,
  });

  factory SavedLock.fromJson(Map<String, dynamic> json) => SavedLock(
    lockMac: json['lockMac'] as String,
    lockName: json['lockName'] as String,
    lockData: json['lockData'] as String,
    lockVersion: json['lockVersion'] as String,
    savedAt: DateTime.parse(json['savedAt'] as String),
  );

  /// Identity of the lock, and the key this record is stored under.
  final String lockMac;

  final String lockName;

  /// The credential that authorises every command to this lock. Losing it
  /// means the lock must be factory reset.
  final String lockData;

  /// Protocol descriptor the native SDK needs alongside [lockData]. It is a
  /// JSON string produced by the SDK and cannot be derived from the MAC, so
  /// it has to be stored rather than rebuilt.
  final String lockVersion;

  final DateTime savedAt;

  Map<String, dynamic> toJson() => {
    'lockMac': lockMac,
    'lockName': lockName,
    'lockData': lockData,
    'lockVersion': lockVersion,
    'savedAt': savedAt.toIso8601String(),
  };
}

/// Persists [SavedLock] records in Android Keystore-backed storage.
///
/// One entry per lock, keyed by MAC. Storing them separately rather than as
/// one blob means a write for one lock can never corrupt another, and there
/// is no read-modify-write step to get wrong.
class LockStorage {
  LockStorage({FlutterSecureStorage? storage})
    : _storage =
          storage ??
          const FlutterSecureStorage(
            // Off by default in 9.x. Without it the plugin falls back to an
            // older scheme; this opts into AES-256-GCM via androidx.security,
            // with the key held in the Android Keystore.
            aOptions: AndroidOptions(encryptedSharedPreferences: true),
          );

  final FlutterSecureStorage _storage;

  /// Namespaces our entries so [loadAll] can pick them out of shared storage.
  static const String _keyPrefix = 'lock/';

  Future<void> save(SavedLock lock) => _storage.write(
    key: '$_keyPrefix${lock.lockMac}',
    value: jsonEncode(lock.toJson()),
  );

  Future<SavedLock?> load(String lockMac) async {
    final raw = await _storage.read(key: '$_keyPrefix$lockMac');
    if (raw == null) return null;
    return _decode(raw);
  }

  Future<List<SavedLock>> loadAll() async {
    final entries = await _storage.readAll();

    final locks = <SavedLock>[];
    for (final entry in entries.entries) {
      if (!entry.key.startsWith(_keyPrefix)) continue;

      final lock = _decode(entry.value);
      if (lock != null) locks.add(lock);
    }

    locks.sort((a, b) => a.lockName.compareTo(b.lockName));
    return locks;
  }

  Future<void> delete(String lockMac) =>
      _storage.delete(key: '$_keyPrefix$lockMac');

  /// Returns null instead of throwing on a damaged record. One unreadable
  /// entry should not make every other lock inaccessible.
  SavedLock? _decode(String raw) {
    try {
      return SavedLock.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }
}
