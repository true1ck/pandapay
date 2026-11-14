import 'package:flutter/material.dart';

import 'design/app_theme.dart';

/// Shared "required field" UX. Pattern for every form:
///
/// 1. `bool _submitted = false;` in the State.
/// 2. Label required inputs with [requiredLabel] (red asterisk).
/// 3. Text inputs: `errorText: requiredError(_submitted, controller.text)`
///    (the theme's errorBorder paints the red border).
/// 4. Non-text inputs (dropdowns, pickers, chips, toggles groups): wrap in
///    [RequiredBox] with `invalid: _submitted && <missing>`.
/// 5. The submit button stays ENABLED. On tap: `setState(() => _submitted = true);`
///    then return early if anything required is missing.

/// Label text followed by a red `*`. Use as `InputDecoration(label: ...)`
/// or as a section heading.
Widget requiredLabel(String text, {TextStyle? style}) => Text.rich(
      TextSpan(
        text: text,
        style: style,
        children: const [
          TextSpan(
            text: ' *',
            style: TextStyle(
              color: BambooInk.clayInk,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );

/// `'Required'` once the user has tried to submit and [value] is blank.
String? requiredError(bool submitted, String? value,
        {String message = 'Required'}) =>
    submitted && (value == null || value.trim().isEmpty) ? message : null;

/// Red outline (+ message) around a non-text input that is missing.
class RequiredBox extends StatelessWidget {
  const RequiredBox({
    super.key,
    required this.invalid,
    required this.child,
    this.message = 'Required',
    this.radius = 14,
  });

  final bool invalid;
  final Widget child;
  final String message;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        DecoratedBox(
          position: DecorationPosition.foreground,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(radius),
            border: invalid
                ? Border.all(color: BambooInk.clay, width: 1.5)
                : null,
          ),
          child: child,
        ),
        if (invalid)
          Padding(
            padding: const EdgeInsets.only(left: 12, top: 4),
            child: Text(
              message,
              style: const TextStyle(color: BambooInk.clayInk, fontSize: 12),
            ),
          ),
      ],
    );
  }
}
