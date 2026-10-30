import 'dart:convert';
import 'dart:js_interop';

@JS('pandaPayAdminPasskey')
external JSPromise<JSString> _passkey(JSString options, JSBoolean register);

Future<Map<String, dynamic>> useAdminPasskey(
  Map<String, dynamic> options, {
  required bool register,
}) async {
  final value = await _passkey(jsonEncode(options).toJS, register.toJS).toDart;
  return (jsonDecode(value.toDart) as Map).cast<String, dynamic>();
}
