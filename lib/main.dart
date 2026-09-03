import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ttlock_flutter/ttlock.dart';

import 'ble_permissions.dart';
import 'lock_service.dart';

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

class ScanPage extends StatefulWidget {
  const ScanPage({super.key});

  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> {
  /// Locks discovered so far, de-duplicated by MAC address.
  final List<TTLockScanModel> _locks = [];

  bool _isScanning = false;

  /// MAC of the lock currently being initialised, or null when idle.
  /// Initialisation is a sustained BLE write, so only one may run at a time.
  String? _initialisingMac;

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
  }

  @override
  void dispose() {
    // A BLE scan is a system-wide resource and keeps running even after this
    // screen is gone. Not stopping it drains the battery and eventually gets
    // the app throttled by Android for scanning too aggressively.
    TTLock.stopScanLock();
    super.dispose();
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
      _locks.clear();
      _isScanning = true;
    });

    // Fires once per advertising packet, so the same lock arrives many times
    // per second. Only genuinely new locks trigger a rebuild.
    TTLock.startScanLock((scanModel) {
      if (!mounted) return;

      final alreadyFound = _locks.any(
        (lock) => lock.lockMac == scanModel.lockMac,
      );
      if (alreadyFound) return;

      setState(() => _locks.add(scanModel));
    });
  }

  void _stopScan() {
    TTLock.stopScanLock();
    setState(() => _isScanning = false);
  }

  Future<void> _onLockTapped(TTLockScanModel lock) async {
    // Already-bound locks cannot be initialised, and only one write at a time.
    if (lock.isInited || _initialisingMac != null) return;

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
        setState(() => lock.isInited = true);
        await _showLockDataDialog(lock, lockData);
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
          'phone. It cannot be undone without a physical factory reset.\n\n'
          'Keep the lockData you get back — it is the only thing that can '
          'control this lock afterwards.',
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

  Future<void> _showLockDataDialog(TTLockScanModel lock, String lockData) {
    return showDialog<void>(
      context: context,
      // Dismissing by tapping outside would be an easy way to lose the only
      // copy of lockData.
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
                  const Text(
                    'Save this lockData now. Without it the lock cannot be '
                    'controlled and must be factory reset.',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 12),
                  SelectableText(
                    lockData,
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
                  await Clipboard.setData(ClipboardData(text: lockData));
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
    final isInitialising = _initialisingMac != null;

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
        ],
      ),
      body: Column(
        children: [
          if (isInitialising) const LinearProgressIndicator(),
          if (_message != null) _buildMessage(),
          Expanded(child: _buildBody()),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        // Disabled mid-write: starting a scan would disturb the connection.
        onPressed: isInitialising ? null : _onScanPressed,
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

  Widget _buildBody() {
    if (_locks.isEmpty) {
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
      itemCount: _locks.length,
      separatorBuilder: (context, index) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final lock = _locks[index];
        final isThisLockInitialising = _initialisingMac == lock.lockMac;

        return ListTile(
          enabled: !lock.isInited && _initialisingMac == null,
          leading: Icon(
            lock.isInited ? Icons.lock : Icons.lock_open,
            color: lock.isInited ? Colors.grey : Colors.indigo,
          ),
          title: Text(lock.lockName),
          subtitle: Text(
            '${lock.lockMac}\n'
            '${lock.isInited ? "Already initialised" : "In setting mode — tap to initialise"}',
          ),
          isThreeLine: true,
          trailing: isThisLockInitialising
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text('${lock.rssi} dBm'),
          onTap: () => _onLockTapped(lock),
        );
      },
    );
  }
}
