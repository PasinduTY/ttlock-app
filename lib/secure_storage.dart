import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// The one secure storage configuration for the whole app.
///
/// Every reader and writer must use exactly these options. Two instances with
/// different Android options would read and write the same storage in two
/// incompatible formats and corrupt it, so nothing should construct its own.
const FlutterSecureStorage appSecureStorage = FlutterSecureStorage(
  // Off by default in 9.x. Without it the plugin falls back to an older
  // scheme; this opts into AES-256-GCM via androidx.security, with the key
  // held in the Android Keystore.
  aOptions: AndroidOptions(encryptedSharedPreferences: true),
);
