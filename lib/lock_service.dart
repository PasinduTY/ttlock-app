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

/// Outcome of asking a lock to open.
sealed class UnlockResult {
  const UnlockResult();
}

/// The lock opened.
class UnlockSuccess extends UnlockResult {
  const UnlockSuccess({
    required this.lockTime,
    required this.batteryPercent,
    required this.uniqueId,
    required this.updatedLockData,
  });

  /// The lock's own clock when it opened, in milliseconds since the epoch.
  /// It can differ from the phone's clock — the lock has no internet.
  final int lockTime;

  /// Battery remaining, as a percentage.
  final int batteryPercent;

  /// Identifier of the operation record the lock stored for this unlock.
  final int uniqueId;

  /// A refreshed credential, or null when the SDK returned nothing new.
  ///
  /// Opening a lock can advance its internal state, and the SDK hands back
  /// updated `lockData` reflecting that. **Persist it.** Keeping the old
  /// string can leave the app out of sync with the lock.
  final String? updatedLockData;
}

class UnlockFailure extends UnlockResult {
  const UnlockFailure(this.errorCode, this.message);

  final TTLockError errorCode;
  final String message;
}

/// Opens the lock that [lockData] authorises, over BLE.
///
/// The lock must be awake and in range. No scan is needed first — [lockData]
/// carries everything required to find and authenticate to it.
Future<UnlockResult> unlockLock(String lockData) {
  final completer = Completer<UnlockResult>();

  TTLock.controlLock(
    lockData,
    TTControlAction.unlock,
    (lockTime, electricQuantity, uniqueId, newLockData) => completer.complete(
      UnlockSuccess(
        lockTime: lockTime,
        batteryPercent: electricQuantity,
        uniqueId: uniqueId,
        // The SDK sends an empty string when nothing changed; normalise that
        // to null so callers cannot accidentally store a blank credential.
        updatedLockData: newLockData.isEmpty ? null : newLockData,
      ),
    ),
    (errorCode, errorMsg) =>
        completer.complete(UnlockFailure(errorCode, errorMsg)),
  );

  return completer.future;
}

/// Outcome of resetting a lock back to setting mode.
sealed class ResetLockResult {
  const ResetLockResult();
}

/// The lock is unbound and advertising in setting mode again. The `lockData`
/// used to reset it is now dead and should be deleted.
class ResetLockSuccess extends ResetLockResult {
  const ResetLockSuccess();
}

class ResetLockFailure extends ResetLockResult {
  const ResetLockFailure(this.errorCode, this.message);

  final TTLockError errorCode;
  final String message;
}

/// Factory resets the lock that [lockData] authorises, over BLE.
///
/// The lock does not need to be scanned first: everything needed to find and
/// authenticate to it is encoded in [lockData]. It does need to be awake and
/// in range, so touch its keypad before calling.
///
/// This is the software equivalent of holding the reset button inside the
/// battery compartment. It only works while [lockData] is still valid — once
/// a lock is reset or re-initialised elsewhere, only the physical button will
/// bring it back.
Future<ResetLockResult> resetLock(String lockData) {
  final completer = Completer<ResetLockResult>();

  TTLock.resetLock(
    lockData,
    () => completer.complete(const ResetLockSuccess()),
    (errorCode, errorMsg) =>
        completer.complete(ResetLockFailure(errorCode, errorMsg)),
  );

  return completer.future;
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
