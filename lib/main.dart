import 'dart:async';

import 'package:flutter/material.dart';
import 'package:ttlock_flutter/ttlock.dart';

import 'ble_permissions.dart';

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

  @override
  Widget build(BuildContext context) {
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
          if (_message != null) _buildMessage(),
          Expanded(child: _buildBody()),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _onScanPressed,
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
        return ListTile(
          leading: Icon(
            lock.isInited ? Icons.lock : Icons.lock_open,
            color: lock.isInited ? Colors.grey : Colors.indigo,
          ),
          title: Text(lock.lockName),
          subtitle: Text(
            '${lock.lockMac}\n'
            '${lock.isInited ? "Already initialised" : "In setting mode — ready to initialise"}',
          ),
          isThreeLine: true,
          trailing: Text('${lock.rssi} dBm'),
        );
      },
    );
  }
}
