/// Readers for the bank statement layouts the app can import (SBI and ICICI
/// style), from the text of a statement to `StatementRow`s that
/// `verifyStatement` can prove. Bank layouts live here, outside `sms_v2`, because
/// reading a bank's own table is bank-specific by nature; SMS classification
/// under `sms_v2` stays data-driven.
library;

export 'src/statements/bank_layouts.dart';
