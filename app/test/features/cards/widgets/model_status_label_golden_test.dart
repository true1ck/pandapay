import 'package:alchemist/alchemist.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/design/app_theme.dart';
import 'package:pandapay/features/cards/widgets/model_status_label.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

/// Alchemist golden for [ModelStatusLabel]: the two labels, and the nothing
/// a Verified card (or a v1-feed card) gets.
void main() {
  setUpAll(() => BambooFonts.useSystemFontsForTests = true);
  tearDownAll(() => BambooFonts.useSystemFontsForTests = false);

  goldenTest(
    'ModelStatusLabel marks Partial and Basic, nothing for Verified',
    fileName: 'model_status_label',
    constraints: const BoxConstraints(maxWidth: 600),
    builder: () => GoldenTestGroup(
      columns: 2,
      children: [
        GoldenTestScenario(
          name: 'partial',
          child: const ModelStatusLabel(status: ModelStatus.partial),
        ),
        GoldenTestScenario(
          name: 'basic',
          child: const ModelStatusLabel(status: ModelStatus.basic),
        ),
        GoldenTestScenario(
          name: 'verified (nothing)',
          child: const SizedBox(
            width: 120,
            height: 24,
            child: ModelStatusLabel(status: ModelStatus.verified),
          ),
        ),
        GoldenTestScenario(
          name: 'no status, v1 feed (nothing)',
          child: const SizedBox(
            width: 120,
            height: 24,
            child: ModelStatusLabel(status: null),
          ),
        ),
      ],
    ),
  );
}
