import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'generated/app_localizations.dart';

export 'generated/app_localizations.dart' show AppLocalizations;

class AppLanguage extends ValueNotifier<Locale?> {
  AppLanguage._() : super(null);

  static final instance = AppLanguage._();
  static const _channel = MethodChannel('five_more/language');
  static const _preference = 'five_more.language';

  bool get _android =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  bool get usesIosSettings =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  Future<void> load() async {
    if (usesIosSettings) return;
    final code = _android
        ? await _channel.invokeMethod<String>('get')
        : (await SharedPreferences.getInstance()).getString(_preference);
    value = code == 'en' || code == 'ru' ? Locale(code!) : null;
  }

  Future<void> select(Locale? locale) async {
    if (_android) {
      await _channel.invokeMethod<void>('set', locale?.languageCode ?? '');
    } else {
      final prefs = await SharedPreferences.getInstance();
      if (!await prefs.setString(_preference, locale?.languageCode ?? '')) {
        throw StateError('Language preference could not be saved');
      }
    }
    value = locale;
  }

  Future<void> openIosSettings() =>
      const MethodChannel('five_more/extras').invokeMethod('languageSettings');

  Locale resolve(List<Locale>? preferences) {
    final supported = basicLocaleListResolution(
      preferences,
      AppLocalizations.supportedLocales,
    );
    final region = WidgetsBinding.instance.platformDispatcher.locales
        .where((locale) => locale.languageCode == supported.languageCode)
        .firstOrNull;
    return region ?? supported;
  }

  Locale get effective => resolve(
    value == null
        ? WidgetsBinding.instance.platformDispatcher.locales
        : [value!],
  );
}

final _catalogs = {
  for (final locale in AppLocalizations.supportedLocales)
    locale.languageCode: lookupAppLocalizations(locale),
};

// Models and native operation results also need strings before a widget exists.
AppLocalizations get appStrings =>
    _catalogs[AppLanguage.instance.effective.languageCode]!;

extension AppStringsContext on BuildContext {
  AppLocalizations get strings =>
      Localizations.of<AppLocalizations>(this, AppLocalizations) ?? appStrings;
}

bool _dateSymbolsReady = false;

String get formatLocale {
  // Intl installs its bundled date symbols synchronously, including offline.
  if (!_dateSymbolsReady) {
    unawaited(initializeDateFormatting());
    _dateSymbolsReady = true;
  }
  final locale = AppLanguage.instance.effective;
  return Intl.verifiedLocale(locale.toString(), DateFormat.localeExists) ??
      locale.languageCode;
}

int get firstWeekdayIndex =>
    DateFormat.E(formatLocale).dateSymbols.FIRSTDAYOFWEEK;

String appDecimal(num value) => NumberFormat('0.0', formatLocale).format(value);

String appFullDate(DateTime date) {
  final text = DateFormat.MMMMEEEEd(formatLocale).format(date);
  return text[0].toUpperCase() + text.substring(1);
}

String appDate(DateTime date) => DateFormat.yMd(formatLocale).format(date);

String appShortDate(DateTime date) => DateFormat.Md(formatLocale).format(date);

bool get localeUsesDayPeriod =>
    DateFormat.jm(formatLocale).pattern!.contains('a');

String appClock(int hour, int minute) {
  final locale = formatLocale;
  final clock = WidgetsBinding.instance.platformDispatcher.alwaysUse24HourFormat
      ? DateFormat.Hm(locale)
      : DateFormat.jm(locale);
  return clock.format(DateTime(2000, 1, 1, hour, minute));
}

String appClockMinute(int minute) => appClock(minute ~/ 60, minute % 60);

String appDateTime(DateTime date) =>
    '${appDate(date)} · ${appClock(date.hour, date.minute)}';
