import 'dart:convert';
import 'dart:io';
import 'package:pandapay_domain/src/sms_v2/evaluation/gates.dart';
export 'package:pandapay_domain/src/sms_v2/evaluation/gates.dart';

Map<String, Gate> loadGates(String path, String profile) => parseGates(
  (jsonDecode(File(path).readAsStringSync()) as Map).cast<String, dynamic>(),
  profile,
);
