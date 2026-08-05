import 'package:analyzer/error/error.dart' show ErrorSeverity;
import 'package:analyzer/error/listener.dart' show ErrorReporter;
import 'package:custom_lint_builder/custom_lint_builder.dart';

/// UA-0.1.3: `DateTime.now()` is banned everywhere except the injectable
/// `Clock` abstraction itself (`packages/pandapay_domain/lib/src/clock`) —
/// calling it directly anywhere else means tests can't control time and
/// production code silently depends on the wall clock. Flags any
/// `DateTime.now()` call whose containing file path does not contain
/// `/clock/` (matches both the clock implementation and its tests).
class NoDateTimeNowOutsideClock extends DartLintRule {
  NoDateTimeNowOutsideClock() : super(code: _code);

  static const _code = LintCode(
    name: 'no_datetime_now_outside_clock',
    problemMessage:
        'DateTime.now() is banned outside core/clock — inject a Clock instead so time is testable (UA-0.1.3).',
    errorSeverity: ErrorSeverity.WARNING,
  );

  @override
  void run(
    CustomLintResolver resolver,
    ErrorReporter reporter,
    CustomLintContext context,
  ) {
    final path = resolver.source.fullName;
    if (path.contains('/clock/')) return;

    // DateTime.now() is a named *constructor* (`factory DateTime.now()`),
    // not a static method — it parses as InstanceCreationExpression, not
    // MethodInvocation, even without an explicit `new`/`const`.
    context.registry.addInstanceCreationExpression((node) {
      final constructorName = node.constructorName;
      if (constructorName.type.name2.lexeme != 'DateTime') return;
      if (constructorName.name?.name != 'now') return;
      reporter.atNode(node, _code);
    });
  }
}
