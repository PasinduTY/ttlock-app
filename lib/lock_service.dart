import 'dart:async';

import 'package:ttlock_flutter/ttlock.dart';

/// Outcome of initialising a lock.
///
/// Sealed so a `switch` over it must handle every case; adding a third
/// outcome later becomes a compile error at each call site rather than a
/// silent fall-through.
sealed class InitLockResult {
  const InitLockResult();
}

/// The lock is now bound to us, and [lockData] is the proof.
///
/// This string is the only thing that can control the lock from here on.
/// Losing it means the lock must be factory reset before it can be used
/// again, so it has to be persisted before the app forgets it.
class InitLockSuccess extends InitLockResult {
  const InitLockSuccess(this.lockData);

  final String lockData;
}

/// The lock was not initialised. Its state is unchanged, or partially
/// written — either way a factory reset returns it to setting mode.
class InitLockFailure extends InitLockResult {
  const InitLockFailure(this.errorCode, this.message);

  final TTLockError errorCode;
  final String message;
}

/// Binds [scanModel]'s lock to this phone and returns its `lockData`.
///
/// The lock must be in setting mode: check `scanModel.isInited == false`
/// before calling. Requires a sustained BLE connection, so the lock has to
/// stay awake and in range for several seconds.
///
/// [scanModel] must come from a live scan. `lockVersion` is a JSON string
/// that the native SDK parses into a protocol descriptor, so it cannot be
/// reconstructed from a stored MAC address.
///
/// Stop scanning before calling this. Scanning and connecting at the same
/// time makes the connection unreliable.
Future<InitLockResult> initialiseLock(TTLockScanModel scanModel) {
  final completer = Completer<InitLockResult>();

  // Key names are dictated by the native SDK, not by us.
  final params = {
    'lockMac': scanModel.lockMac,
    'lockVersion': scanModel.lockVersion,
    'isInited': scanModel.isInited,
  };

  TTLock.initLock(
    params,
    (lockData) => completer.complete(InitLockSuccess(lockData)),
    (errorCode, errorMsg) =>
        completer.complete(InitLockFailure(errorCode, errorMsg)),
  );

  return completer.future;
}
