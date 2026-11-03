import 'dart:convert';
import 'dart:io';
import 'package:pandapay_domain/sms_v2.dart';
import 'package:pandapay_domain/src/sms_v2/evaluation/engine_stage.dart'
    as shared;

class EngineInterpreterStage extends shared.EngineInterpreterStage {
  EngineInterpreterStage(super.bundle, {super.appVersion});
  factory EngineInterpreterStage.fromFile(String path) {
    final json =
        jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
    return EngineInterpreterStage(RuleBundle.fromJson(json));
  }
}
