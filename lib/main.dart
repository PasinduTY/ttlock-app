import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ttlock_flutter/ttlock.dart';

import 'ble_permissions.dart';
import 'lock_service.dart';
import 'lock_storage.dart';

void main() {
  runApp(const TTLockApp());
}

class TTLockApp extends StatelessWidget {
  const TTLockApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'TTLock',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
      ),
      home: const ScanPage(),
    );
  }
}

/// One row in the list: a lock we have saved, a lock we can currently see, or
/// both. [saved] carries the credential, [scan] proves it is in range now.
class _LockRow {
  const _LockRow({
    required this.mac,
    required this.name,
    this.saved,
    this.scan,
  });

  final String mac;
  final String name;
  final SavedLock? saved;
  final TTLockScanModel? scan;

  bool get isSaved => saved != null;
  bool get isInRange => scan != null;

  /// In setting mode and not yet ours, so it can be initialised.
  bool get canInitialise => scan != null && !scan!.isInited;
}

enum _SavedLockAction { reset, forget }

class ScanPage extends StatefulWidget {
  const ScanPage({super.key});

  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> {
  final LockStorage _storage = LockStorage();

  /// Locks we have initialised, keyed by MAC. Survives restarts.
  final Map<String, SavedLock> _savedLocks = {};

  /// Locks seen in the current scan, keyed by MAC. Cleared on each new scan.
  /// A map rather than a list, so repeat advertisements de-duplicate for free.
  final Map<String, TTLockScanModel> _scanned = {};

  bool _isScanning = false;

  /// MAC of the lock currently being initialised, or null when idle.
  /// Initialisation is a sustained BLE write, so only one may run at a time.
  String? _initialisingMac;

  /// True while a factory reset is in flight. Like initialisation, it holds a
  /// BLE connection and must not overlap with a scan.
  bool _isResetting = false;

  bool get _isBusy => _initialisingMac != null || _isResetting;

  /// Explanation shown when we could not start scanning.
  String? _message;

  /// True when [_message] is fixable only in system Settings.
  bool _needsSettings = false;

  @override
  void initState() {
    super.initState();
    // Makes the native SDK log its BLE traffic to logcat. Invaluable while
    // bringing this up; turn it off before release.
    TTLock.printLog = true;
    _loadSavedLocks();
  }

  @override
  void dispose() {
    // A BLE scan is a system-wide resource and keeps running even after this
    // screen is gone. Not stopping it drains the battery and eventually gets
    // the app throttled by Android for scanning too aggressively.
    TTLock.stopScanLock();
    super.dispose();
  }

  /// [initState] cannot be async, so the read is kicked off and lands later.
  Future<void> _loadSavedLocks() async {
    List<SavedLock> locks;
    try {
      locks = await _storage.loadAll();
    } catch (error) {
      // A Keystore that can no longer decrypt its own data (device restore,
      // key reset) fails here. Scanning and initialising must still work.
      debugPrint('Could not read saved locks: $error');
      return;
    }

    if (!mounted) return;

    setState(() {
      for (final lock in locks) {
        _savedLocks[lock.lockMac] = lock;
      }
    });
  }

  /// The SDK reports Bluetooth state through a callback. [Completer] adapts
  /// that into a Future so it can sit in a normal `await` chain.
  Future<TTBluetoothState> _bluetoothState() {
    final completer = Completer<TTBluetoothState>();
    TTLock.getBluetoothState(completer.complete);
    return completer.future;
  }

  Future<void> _onScanPressed() async {
    if (_isScanning) {
      _stopScan();
      return;
    }

    setState(() {
      _message = null;
      _needsSettings = false;
    });

    final permission = await requestBlePermissions();
    // Awaiting gave the user time to leave this screen; touching state after
    // that would throw.
    if (!mounted) return;

    switch (permission) {
      case BlePermissionResult.granted:
        break;
      case BlePermissionResult.denied:
        _showMessage(
          'Bluetooth permission is needed to find locks. '
          'Tap Scan to try again.',
        );
        return;
      case BlePermissionResult.permanentlyDenied:
        _showMessage(
          'Bluetooth permission was permanently denied. Enable Nearby devices '
          'in Settings to scan for locks.',
          needsSettings: true,
        );
        return;
    }

    final state = await _bluetoothState();
    if (!mounted) return;

    if (state != TTBluetoothState.turnOn) {
      _showMessage('Bluetooth is off. Turn it on and tap Scan again.');
      return;
    }

    _startScan();
  }

  void _showMessage(String text, {bool needsSettings = false}) {
    setState(() {
      _message = text;
      _needsSettings = needsSettings;
    });
  }

  void _startScan() {
    setState(() {
      _scanned.clear();
      _isScanning = true;
    });

    // Fires once per advertising packet, so the same lock arrives many times
    // per second. Only genuinely new locks trigger a rebuild.
    TTLock.startScanLock((scanModel) {
      if (!mounted) return;
      if (_scanned.containsKey(scanModel.lockMac)) return;

      setState(() => _scanned[scanModel.lockMac] = scanModel);
    });
  }

  void _stopScan() {
    TTLock.stopScanLock();
    setState(() => _isScanning = false);
  }

  /// Saved locks and scanned locks merged into one row per physical lock.
  List<_LockRow> _buildRows() {
    final macs = <String>{..._savedLocks.keys, ..._scanned.keys};

    final rows = macs.map((mac) {
      final saved = _savedLocks[mac];
      final scan = _scanned[mac];
      return _LockRow(
        mac: mac,
        // A live scan has the current name; fall back to what we stored.
        name: scan?.lockName ?? saved?.lockName ?? mac,
        saved: saved,
        scan: scan,
      );
    }).toList();

    // Actionable rows first: in range before out of range, ours before others.
    rows.sort((a, b) {
      if (a.isInRange != b.isInRange) return a.isInRange ? -1 : 1;
      if (a.isSaved != b.isSaved) return a.isSaved ? -1 : 1;
      return a.name.compareTo(b.name);
    });

    return rows;
  }

  /// Factory resets whichever lock [lockData] authorises, putting it back into
  /// setting mode. [knownMac] is the saved record to drop afterwards, if the
  /// reset came from one; the paste path has no record to clean up.
  Future<void> _resetWithLockData(String lockData, {String? knownMac}) async {
    if (_isScanning) _stopScan();

    setState(() {
      _message = null;
      _isResetting = true;
    });

    final result = await resetLock(lockData);
    if (!mounted) return;

    setState(() => _isResetting = false);

    switch (result) {
      case ResetLockSuccess():
        // The lockData just used is now dead. Keeping the record would leave
        // a saved lock that no longer answers to it.
        if (knownMac != null) {
          try {
            await _storage.delete(knownMac);
          } catch (error) {
            debugPrint(
              'Reset succeeded but deleting the record failed: $error',
            );
          }
          if (!mounted) return;
          setState(() {
            _savedLocks.remove(knownMac);
            _scanned.remove(knownMac);
          });
        }

        await _showInfoDialog(
          'Lock reset',
          'The lock is back in setting mode. Scan and tap it to initialise it '
              'again.',
        );
      case ResetLockFailure(:final errorCode, :final message):
        await _showInfoDialog(
          'Reset failed',
          '$message\n\n'
              'Error: ${errorCode.name}\n\n'
              'Wake the lock by touching its keypad, keep the phone close, and '
              'try again. If the lockData is no longer valid, only the physical '
              'reset button will work.',
        );
    }
  }

  /// Reset using a lockData string pasted by hand — the escape hatch for a
  /// lock that was initialised before this app stored anything.
  Future<void> _showResetByPasteDialog() async {
    final controller = TextEditingController();

    try {
      final lockData = await showDialog<String>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Reset with lockData'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Paste the lockData for the lock you want to reset. Wake the '
                'lock first and keep the phone close to it.',
              ),
              const SizedBox(height: 16),
              TextField(
                controller: controller,
                maxLines: 4,
                minLines: 2,
                autofocus: true,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  hintText: 'lockData',
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                final text = controller.text.trim();
                if (text.isEmpty) return;
                Navigator.pop(dialogContext, text);
              },
              child: const Text('Reset'),
            ),
          ],
        ),
      );

      if (!mounted || lockData == null) return;
      await _resetWithLockData(lockData);
    } finally {
      controller.dispose();
    }
  }

  Future<void> _showInfoDialog(String title, String body) {
    return showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Future<void> _onRowTapped(_LockRow row) async {
    if (_isBusy) return;

    if (row.canInitialise) {
      await _initialise(row.scan!);
      return;
    }

    if (row.isSaved) {
      await _showSavedLockDialog(row);
    }
  }

  Future<void> _initialise(TTLockScanModel lock) async {
    final confirmed = await _confirmInitialise(lock);
    if (!mounted || confirmed != true) return;

    // Scanning while connecting makes the connection unreliable, so the radio
    // is given over to the connection for the duration.
    if (_isScanning) _stopScan();

    setState(() {
      _message = null;
      _initialisingMac = lock.lockMac;
    });

    final result = await initialiseLock(lock);
    if (!mounted) return;

    setState(() => _initialisingMac = null);

    switch (result) {
      case InitLockSuccess(:final lockData):
        // Logged as a backup in case the dialog is dismissed before the
        // string is saved anywhere.
        debugPrint('lockData for ${lock.lockMac}: $lockData');

        final saved = SavedLock(
          lockMac: lock.lockMac,
          lockName: lock.lockName,
          lockData: lockData,
          lockVersion: lock.lockVersion,
          savedAt: DateTime.now(),
        );

        // Persist before showing the dialog: if the app dies while the dialog
        // is open, the record is already on disk.
        var saveFailed = false;
        try {
          await _storage.save(saved);
        } catch (error) {
          saveFailed = true;
          debugPrint('Failed to persist lockData: $error');
        }
        if (!mounted) return;

        setState(() {
          _savedLocks[saved.lockMac] = saved;
          lock.isInited = true;
        });

        await _showLockDataDialog(saved, saveFailed: saveFailed);
      case InitLockFailure(:final errorCode, :final message):
        await _showFailureDialog(errorCode, message);
    }
  }

  Future<bool?> _confirmInitialise(TTLockScanModel lock) {
    return showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Initialise this lock?'),
        content: Text(
          '${lock.lockName}\n${lock.lockMac}\n\n'
          'This writes new key material to the lock and binds it to this '
          'phone. It cannot be undone without a physical factory reset.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Initialise'),
          ),
        ],
      ),
    );
  }

  Future<void> _showLockDataDialog(SavedLock lock, {required bool saveFailed}) {
    return showDialog<void>(
      context: context,
      // Dismissing by tapping outside would be an easy way to lose the only
      // copy of lockData when the save failed.
      barrierDismissible: false,
      builder: (dialogContext) {
        // The dialog owns this flag, so it needs its own state.
        var copied = false;

        return StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            title: const Text('Lock initialised'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${lock.lockName} is now bound to this phone.'),
                  const SizedBox(height: 16),
                  Text(
                    saveFailed
                        ? 'Saving to secure storage FAILED. This screen holds '
                              'the only copy — copy it somewhere safe now.'
                        : 'Saved to secure storage on this phone. Keep a copy '
                              'elsewhere too until the backend exists.',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: saveFailed
                          ? Theme.of(context).colorScheme.error
                          : null,
                    ),
                  ),
                  const SizedBox(height: 12),
                  SelectableText(
                    lock.lockData,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: lock.lockData));
                  setDialogState(() => copied = true);
                },
                child: Text(copied ? 'Copied' : 'Copy'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Done'),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _showSavedLockDialog(_LockRow row) async {
    final saved = row.saved!;

    final action = await showDialog<_SavedLockAction>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(saved.lockName),
        content: Text(
          '${saved.lockMac}\n\n'
          'Saved ${saved.savedAt.toLocal()}\n'
          '${row.isInRange ? "In range now." : "Not currently in range."}\n\n'
          'Unlocking is not built yet.\n\n'
          'Reset puts the lock back into setting mode over Bluetooth and '
          'deletes the stored lockData. Forget deletes only our copy, leaving '
          'the lock bound and unusable — reset instead unless you know why you '
          'want that.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Close'),
          ),
          TextButton(
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () =>
                Navigator.pop(dialogContext, _SavedLockAction.forget),
            child: const Text('Forget'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(dialogContext, _SavedLockAction.reset),
            child: const Text('Reset'),
          ),
        ],
      ),
    );

    if (!mounted || action == null) return;

    switch (action) {
      case _SavedLockAction.reset:
        await _resetWithLockData(saved.lockData, knownMac: saved.lockMac);
      case _SavedLockAction.forget:
        await _storage.delete(saved.lockMac);
        if (!mounted) return;
        setState(() => _savedLocks.remove(saved.lockMac));
    }
  }

  Future<void> _showFailureDialog(TTLockError errorCode, String message) {
    return showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Initialisation failed'),
        content: Text(
          '$message\n\n'
          'Error: ${errorCode.name}\n\n'
          'The lock may be left partly configured. Wake it and try again; if '
          'it no longer appears in setting mode, factory reset it.',
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final rows = _buildRows();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Locks'),
        actions: [
          if (_isScanning)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            ),
          PopupMenuButton<void>(
            enabled: !_isBusy,
            itemBuilder: (context) => [
              PopupMenuItem<void>(
                onTap: _showResetByPasteDialog,
                child: const Text('Reset with lockData…'),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          if (_isBusy) const LinearProgressIndicator(),
          if (_message != null) _buildMessage(),
          Expanded(child: _buildBody(rows)),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        // Disabled mid-write: starting a scan would disturb the connection.
        onPressed: _isBusy ? null : _onScanPressed,
        icon: Icon(_isScanning ? Icons.stop : Icons.bluetooth_searching),
        label: Text(_isScanning ? 'Stop' : 'Scan'),
      ),
    );
  }

  Widget _buildMessage() {
    return Container(
      width: double.infinity,
      color: Theme.of(context).colorScheme.errorContainer,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_message!),
          if (_needsSettings)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: FilledButton.tonal(
                onPressed: openBlePermissionSettings,
                child: const Text('Open Settings'),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildBody(List<_LockRow> rows) {
    if (rows.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            _isScanning
                ? 'Scanning…\n\nTouch the lock keypad to wake it. A sleeping '
                      'lock does not advertise and cannot be found.'
                : 'No locks yet. Tap Scan to look for nearby locks.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    return ListView.separated(
      itemCount: rows.length,
      separatorBuilder: (context, index) => const Divider(height: 1),
      itemBuilder: (context, index) => _buildRow(rows[index]),
    );
  }

  Widget _buildRow(_LockRow row) {
    final theme = Theme.of(context);
    final isThisLockInitialising = _initialisingMac == row.mac;

    final String status;
    final IconData icon;
    final Color? iconColour;

    if (row.isSaved) {
      status = row.isInRange ? 'Saved · in range' : 'Saved · not nearby';
      icon = Icons.lock;
      iconColour = theme.colorScheme.primary;
    } else if (row.canInitialise) {
      status = 'In setting mode — tap to initialise';
      icon = Icons.lock_open;
      iconColour = theme.colorScheme.primary;
    } else {
      status = 'Initialised on another phone';
      icon = Icons.lock;
      iconColour = Colors.grey;
    }

    return ListTile(
      enabled: (row.canInitialise || row.isSaved) && !_isBusy,
      leading: Icon(icon, color: iconColour),
      title: Text(row.name),
      subtitle: Text('${row.mac}\n$status'),
      isThreeLine: true,
      trailing: isThisLockInitialising
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : row.isInRange
          ? Text('${row.scan!.rssi} dBm')
          : null,
      onTap: () => _onRowTapped(row),
    );
  }
}
