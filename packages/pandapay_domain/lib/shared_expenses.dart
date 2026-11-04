/// Pure exact shared-expense previews and source identities. These helpers do
/// not authorize a source, post a journal, accept a claim or confirm a payment.
library;

export 'src/shared_expenses/domain.dart';
export 'src/shared_expenses/source_reference.dart';
export 'src/shared_expenses/journal.dart';
export 'src/shared_expenses/validation.dart' show SharedExpenseException;
