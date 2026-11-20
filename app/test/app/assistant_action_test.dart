import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/assistant_action.dart';

void main() {
  test('parses a period-specific spending request', () {
    final request = parseAssistantUri(
      Uri.parse('pandapay://assistant/spending?period=quarter'),
    );

    expect(request?.action, AssistantAction.spending);
    expect(request?.period, 'quarter');
  });

  test('defaults an unknown spending period to month', () {
    final request = parseAssistantUri(
      Uri.parse('pandapay://assistant/spending?period=tomorrow'),
    );

    expect(request?.period, 'month');
  });

  test('parses an add-spend request and decodes text parameters', () {
    final request = parseAssistantUri(
      Uri.parse(
        'pandapay://assistant/add-spend?amount=1%2C250.50&merchant=Goa%20Bazaar&category=Groceries',
      ),
    );

    expect(request?.action, AssistantAction.addSpend);
    expect(request?.amount, 1250.50);
    expect(request?.merchant, 'Goa Bazaar');
    expect(request?.category, 'Groceries');
  });

  test('allows the launcher add-spend shortcut to open a blank draft', () {
    final request = parseAssistantUri(
      Uri.parse('pandapay://assistant/add-spend'),
    );

    expect(request?.action, AssistantAction.addSpend);
    expect(request?.amount, isNull);
  });

  test('rejects invalid or foreign assistant URIs', () {
    expect(
      parseAssistantUri(Uri.parse('pandapay://assistant/add-spend?amount=-1')),
      isNull,
    );
    expect(
      parseAssistantUri(Uri.parse('https://pandapay.app/assistant/spending')),
      isNull,
    );
    expect(
      parseAssistantUri(Uri.parse('pandapay://assistant/unknown')),
      isNull,
    );
  });

  test('the exact links the iOS and Android widgets open both parse', () {
    expect(
      parseAssistantUri(
        Uri.parse('pandapay://assistant/spending?period=month'),
      )?.action,
      AssistantAction.spending,
    );
    expect(
      parseAssistantUri(Uri.parse('pandapay://assistant/best-card'))?.action,
      AssistantAction.bestCard,
    );
  });

  test('isAssistantUri matches the assistant host only', () {
    expect(isAssistantUri(Uri.parse('pandapay://assistant/best-card')), isTrue);
    // Unknown paths still count, so the router never shows its error page.
    expect(isAssistantUri(Uri.parse('pandapay://assistant/unknown')), isTrue);
    expect(isAssistantUri(Uri.parse('pandapay://i/ABC123')), isFalse);
    expect(isAssistantUri(Uri.parse('pandapay:///home')), isFalse);
    expect(isAssistantUri(Uri.parse('https://assistant/spending')), isFalse);
  });
}
