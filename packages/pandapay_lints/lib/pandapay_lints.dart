import 'package:custom_lint_builder/custom_lint_builder.dart';

import 'src/no_datetime_now_outside_clock.dart';
import 'src/no_bare_money_text.dart';

PluginBase createPlugin() => _PandapayLints();

class _PandapayLints extends PluginBase {
  @override
  List<LintRule> getLintRules(CustomLintConfigs configs) => [
        NoDateTimeNowOutsideClock(),
        NoBareMoneyText(),
      ];
}
