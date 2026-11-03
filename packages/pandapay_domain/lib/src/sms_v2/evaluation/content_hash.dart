import 'dart:convert';
import 'package:crypto/crypto.dart';
import '../contract/json_util.dart';

/// Same content identity checked by the server before publishing a candidate.
String evaluationContentHash(Map<String, dynamic> candidate) {
  final body = Map<String, dynamic>.from(candidate);
  for (final field in [
    'signature',
    'bundleVersion',
    'createdAt',
    'expiresAt',
  ]) {
    body.remove(field);
  }
  return sha256.convert(utf8.encode(canonicalJson(body))).toString();
}
