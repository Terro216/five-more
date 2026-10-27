import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

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
        message: 'Эта возможность доступна в приложении на телефоне.',
      );
    }
    return channel.invokeMethod<T>(method, args);
  }

  static Future<String> version() async {
    if (!available) return 'Предпросмотр';
    try {
      return await call<String>('version') ?? 'Версия недоступна';
    } catch (_) {
      return 'Версия недоступна';
    }
  }
}
