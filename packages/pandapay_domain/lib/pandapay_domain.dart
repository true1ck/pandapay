/// Shared domain code for PandaPay's user app and console: Money, Confidence,
/// Clock, and (later) the card-rule model and recommendation engine — one
/// implementation both apps depend on by path.
library;

export 'src/money/money.dart';
export 'src/confidence/confidence.dart';
export 'src/clock/clock.dart';
export 'src/card_rules/card_rules.dart';
export 'src/card_rules/card_rules_json.dart';
export 'src/engine/engine.dart';
export 'src/engine/acquisition_engine.dart';
export 'src/engine/calculators.dart';
export 'src/engine/historical_comparison.dart';
export 'src/engine/urgency.dart';
export 'src/engine/milestone_marginal_rate.dart';
export 'src/geo/geo.dart';
export 'src/geo/best_card_for_widget.dart';
export 'src/upi/upi_qr.dart';
