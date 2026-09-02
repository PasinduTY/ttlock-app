import 'package:permission_handler/permission_handler.dart';

/// What happened when we asked the user for BLE access.
///
/// Android has more than a yes/no answer here, and the difference matters:
/// [denied] can be retried, [permanentlyDenied] cannot.
enum BlePermissionResult {
  /// We may scan and connect.
  granted,

  /// The user said no this time. Asking again is allowed.
  denied,

  /// The OS will no longer show our dialog. Only a trip to system
  /// Settings can change this.
  permanentlyDenied,
}

/// Everything the TTLock SDK needs to reach a lock over Bluetooth.
///
/// Requested together on purpose: Android shows a single dialog for the
/// whole Bluetooth permission group instead of two back to back.
const List<Permission> _blePermissions = [
  Permission.bluetoothScan,
  Permission.bluetoothConnect,
];

/// Asks for Bluetooth scan and connect access, prompting the user if needed.
///
/// Safe to call repeatedly: permissions already granted do not re-prompt.
Future<BlePermissionResult> requestBlePermissions() async {
  final statuses = await _blePermissions.request();

  if (statuses.values.every((status) => status.isGranted)) {
    return BlePermissionResult.granted;
  }

  // Checked before plain denial: if any permission is permanently denied,
  // retrying is pointless and the user must be sent to Settings.
  if (statuses.values.any((status) => status.isPermanentlyDenied)) {
    return BlePermissionResult.permanentlyDenied;
  }

  return BlePermissionResult.denied;
}

/// Opens this app's page in system Settings.
///
/// The only way out of [BlePermissionResult.permanentlyDenied].
Future<void> openBlePermissionSettings() => openAppSettings();
