/// SMS pipeline v2, tier 2: the evidence solver and its pack.
///
/// Kept in its own library so tier 1 (`sms_v2.dart`) is untouched while the
/// solver runs in shadow mode.
library;

export 'src/sms_v2/solver/evidence_solver.dart';
export 'src/sms_v2/solver/solver_pack.dart';
export 'src/sms_v2/solver/solver_text.dart'
    show
        SolverText,
        Tok,
        TokKind,
        Phrase,
        PhraseHit,
        SolverDate,
        parseSolverDate;
export 'src/sms_v2/solver/solver_facts.dart';
export 'src/sms_v2/solver/bill_history.dart';
