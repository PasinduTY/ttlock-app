import 'backend_client.dart';
import 'lock_storage.dart';

/// What one sync achieved, for showing to the user and for tests.
class SyncReport {
  const SyncReport({
    this.uploaded = 0,
    this.pulled = 0,
    this.refreshed = 0,
    this.deleted = 0,
    this.problems = const [],
    this.unreachableReason,
  });

  /// Locks this phone had that the backend didn't, now backed up.
  final int uploaded;

  /// Locks the backend had that this phone didn't, now saved locally.
  final int pulled;

  /// Local copies replaced by a newer version from the backend.
  final int refreshed;

  /// Pending deletes (tombstones) the backend has now carried out.
  final int deleted;

  /// Requests the backend refused. These will not fix themselves on retry.
  final List<String> problems;

  /// Set when the backend stopped answering; the sync stopped there.
  final String? unreachableReason;

  bool get reachedBackend => unreachableReason == null;
}

/// Keeps this phone's locks and the backend's in agreement.
///
/// The rules, in the order they run:
///
/// 1. Retry pending deletes first, so step 3 cannot bring back a lock that
///    was reset on this phone.
/// 2. Upload every lock not yet backed up, before reading anything, so this
///    phone's newest data reaches the backend first.
/// 3. Pull: save locks this phone lacks, and replace local copies the backend
///    has a newer version of. Tombstoned MACs are skipped.
///
/// And one rule about what never happens: a local lock is **never deleted**
/// because the backend doesn't have it. If the backend lost its data, that
/// rule is what stops every phone deleting every lock. Only the phone that
/// resets a lock removes it.
class LockSync {
  LockSync({required this._storage, required this._backend});

  final LockStorage _storage;
  final BackendClient _backend;

  /// The sync currently running, if any.
  Future<SyncReport>? _current;

  /// Set when [run] is called during a sync, so one more pass follows it.
  bool _runAgain = false;

  /// Runs a sync. Safe to call at any time and from anywhere.
  ///
  /// Only one sync runs at once. A call that arrives mid-sync does not start
  /// a second one in parallel (they would race over the same records);
  /// instead it asks for one more pass, and waits for that pass to finish.
  /// That matters right after initialising: the new lock must not be missed
  /// just because a sync had already passed the upload step.
  Future<SyncReport> run() {
    final current = _current;
    if (current != null) {
      _runAgain = true;
      return current;
    }
    return _current = _runUntilSettled();
  }

  Future<SyncReport> _runUntilSettled() async {
    try {
      SyncReport report;
      do {
        _runAgain = false;
        report = await _runOnce();
      } while (_runAgain && report.reachedBackend);
      return report;
    } finally {
      _current = null;
    }
  }

  Future<SyncReport> _runOnce() async {
    var uploaded = 0, pulled = 0, refreshed = 0, deleted = 0;
    final problems = <String>[];

    SyncReport stopped(String reason) => SyncReport(
      uploaded: uploaded,
      pulled: pulled,
      refreshed: refreshed,
      deleted: deleted,
      problems: problems,
      unreachableReason: reason,
    );

    // 1. Pending deletes.
    for (final mac in await _storage.loadTombstones()) {
      switch (await _backend.deleteLock(mac)) {
        case BackendOk():
          await _storage.removeTombstone(mac);
          deleted++;
        case BackendUnreachable(:final reason):
          return stopped(reason);
        case BackendError(:final reason):
          problems.add('$mac: $reason');
      }
    }

    // 2. Uploads.
    for (final lock in await _storage.loadAll()) {
      if (lock.backedUp) continue;

      final upload = _backend.uploadLock(
        mac: lock.lockMac,
        name: lock.lockName,
        lockData: lock.lockData,
        lockVersion: lock.lockVersion,
      );
      switch (await upload) {
        case BackendOk():
          await _storage.save(lock.copyWith(backedUp: true));
          uploaded++;
        case BackendUnreachable(:final reason):
          return stopped(reason);
        case BackendError(:final reason):
          problems.add('${lock.lockName}: $reason');
      }
    }

    // 3. Pull.
    final List<RemoteLock> remoteLocks;
    switch (await _backend.listLocks()) {
      case BackendOk(:final value):
        remoteLocks = value;
      case BackendUnreachable(:final reason):
        return stopped(reason);
      case BackendError(:final reason):
        problems.add(reason);
        remoteLocks = const [];
    }

    // MACs compared upper-cased: the backend always stores them that way,
    // and one physical lock must never become two records.
    final local = {
      for (final lock in await _storage.loadAll())
        lock.lockMac.toUpperCase(): lock,
    };
    final tombstoned = {
      for (final mac in await _storage.loadTombstones()) mac.toUpperCase(),
    };

    for (final remote in remoteLocks) {
      final mac = remote.mac.toUpperCase();
      if (tombstoned.contains(mac)) continue;

      final mine = local[mac];
      final fromBackend = SavedLock(
        lockMac: mine?.lockMac ?? remote.mac,
        lockName: remote.name,
        lockData: remote.lockData,
        lockVersion: remote.lockVersion,
        savedAt: DateTime.now(),
        backedUp: true,
      );

      if (mine == null) {
        await _storage.save(fromBackend);
        pulled++;
      } else if (mine.backedUp && _differs(mine, remote)) {
        // backedUp means the backend once held exactly our version. It now
        // holds a different one, so someone changed it since: theirs is newer.
        // A copy that is NOT backed up is never replaced: it is this phone's
        // newest data, and the upload above simply hasn't succeeded yet.
        await _storage.save(fromBackend);
        refreshed++;
      }
    }

    return SyncReport(
      uploaded: uploaded,
      pulled: pulled,
      refreshed: refreshed,
      deleted: deleted,
      problems: problems,
    );
  }

  static bool _differs(SavedLock mine, RemoteLock remote) =>
      mine.lockData != remote.lockData ||
      mine.lockVersion != remote.lockVersion ||
      mine.lockName != remote.name;
}
