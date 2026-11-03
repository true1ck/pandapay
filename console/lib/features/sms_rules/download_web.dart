import 'dart:async';
import 'dart:js_interop';

@JS('Blob')
extension type _Blob._(JSObject _) implements JSObject {
  external factory _Blob(JSArray<JSString> content, JSObject options);
}
@JS('document.createElement')
external _Anchor _createElement(String tag);
extension type _Anchor._(JSObject _) implements JSObject {
  external set href(String value);
  external set download(String value);
  external void click();
}
@JS('URL.createObjectURL')
external String _createUrl(JSObject value);
@JS('URL.revokeObjectURL')
external void _revoke(String value);

void downloadJson(String filename, String content) {
  final blob = _Blob(
    [content.toJS].toJS,
    {'type': 'application/json'}.jsify()! as JSObject,
  );
  final url = _createUrl(blob);
  _createElement('a')
    ..href = url
    ..download = filename
    ..click();
  Timer(const Duration(seconds: 1), () => _revoke(url));
}
