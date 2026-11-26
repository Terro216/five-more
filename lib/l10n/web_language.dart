import 'dart:js_interop';

@JS('setFiveMoreLanguage')
external JSFunction? get _setPageLanguage;

void updateWebLanguage(String language) =>
    _setPageLanguage?.callAsFunction(null, language.toJS);
