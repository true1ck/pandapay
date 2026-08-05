import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/error/error.dart' show ErrorSeverity;
import 'package:analyzer/error/listener.dart' show ErrorReporter;
import 'package:custom_lint_builder/custom_lint_builder.dart';

/// UA-0.1.3: financial figures must always render through a widget that
/// requires a [Confidence] (MoneyText in app/lib/main.dart) — a bare
/// `Text(money.format())` silently drops the confidence indicator ui-spec
/// depends on. Flags a `Text(...)` constructor call whose argument
/// contains a `.format()` call on an expression of static type `Money`,
/// either directly (`Text(amount.format())`) or inside a string
/// interpolation (`Text('₹${amount.format()}')`).
class NoBareMoneyText extends DartLintRule {
  NoBareMoneyText() : super(code: _code);

  static const _code = LintCode(
    name: 'no_bare_money_text',
    problemMessage:
        'Text(money.format()) drops the required Confidence indicator — use MoneyText instead (UA-0.1.3).',
    errorSeverity: ErrorSeverity.WARNING,
  );

  @override
  void run(
    CustomLintResolver resolver,
    ErrorReporter reporter,
    CustomLintContext context,
  ) {
    context.registry.addInstanceCreationExpression((node) {
      final typeName = node.constructorName.type.name2.lexeme;
      if (typeName != 'Text') return;
      if (node.argumentList.arguments.isEmpty) return;

      final firstArg = node.argumentList.arguments.first;
      if (_containsMoneyFormatCall(firstArg)) {
        reporter.atNode(node, _code);
      }
    });
  }

  bool _containsMoneyFormatCall(Expression expr) {
    final visitor = _MoneyFormatCallVisitor();
    expr.accept(visitor);
    return visitor.found;
  }
}

class _MoneyFormatCallVisitor extends RecursiveAstVisitor<void> {
  bool found = false;

  @override
  void visitMethodInvocation(MethodInvocation node) {
    if (node.methodName.name == 'format') {
      final targetType = node.target?.staticType;
      if (targetType != null && targetType.getDisplayString() == 'Money') {
        found = true;
      }
    }
    super.visitMethodInvocation(node);
  }
}
