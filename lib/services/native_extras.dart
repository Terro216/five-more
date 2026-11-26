import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../l10n/strings.dart';

/// Optional features never own or stop alarm playback.
class NativeExtras {
  static const channel = MethodChannel('five_more/extras');
  static bool get available =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);
  static Future<T?> call<T>(
    String method, [
    Map<String, Object?> args = const {},
  ]) async {
    if (!available) {
      throw PlatformException(
        code: 'preview',
        message: appStrings.thisFeatureIsAvailableInTheMobile,
      );
    }
    return channel.invokeMethod<T>(method, args);
  }

  static Future<String> version() async {
    if (!available) return appStrings.preview;
    try {
      return await call<String>('version') ?? appStrings.versionUnavailable;
    } catch (_) {
      return appStrings.versionUnavailable;
    }
  }
}
