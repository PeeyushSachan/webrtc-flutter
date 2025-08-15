// lib/permissions.dart
import 'package:permission_handler/permission_handler.dart';

/// Requests microphone (and camera if [video] = true).
/// Returns true only if all requested permissions are granted.
Future<bool> ensureAvPermissions({bool video = true}) async {
  final req = <Permission>[Permission.microphone, if (video) Permission.camera];
  final results = await req.request();
  for (final p in req) {
    if (results[p] != PermissionStatus.granted) return false;
  }
  return true;
}
