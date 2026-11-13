import 'dart:convert';
import 'dart:io';

import 'package:pandapay_domain/sms_v2.dart';

/// Installs the owner vocabulary the rulebook ships (`params.ownerIdentity` of
/// `rules/sms/solver/pack.json`), as the app does when it activates a bundle.
void installRepoOwnerVocabulary() {
  final pack =
      jsonDecode(File('../rules/sms/solver/pack.json').readAsStringSync())
          as Map<String, dynamic>;
  OwnerVocabulary.installFromPackParams(pack['params']);
}
