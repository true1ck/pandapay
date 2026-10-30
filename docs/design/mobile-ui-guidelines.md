# PandaPay mobile UI

Use the existing **Bamboo Ink** system for every new or changed mobile screen. Its source of truth is `app/lib/app/design/app_theme.dart` and `app/lib/app/design/widgets.dart`; this guide records those conventions rather than introducing another palette.

- Use `AppBackground` with transparent Scaffold/AppBar surfaces. Use `BambooFonts.heading` and `BambooFonts.ui`, `AppSpace` spacing, and `AppRadius` corners.
- Use paper/glass panels, hairline borders and ink text. Slate carries primary actions and progress; bamboo lime appears only on slate. Jade marks successful/connected states. Use the existing semantic ink colours for readable errors.
- Present one primary next action. Keep routine copy to a heading and a short explanation. Put setup instructions in a help sheet, advanced settings behind a disclosure, and per-record diagnostics in optional details.
- Use the existing `Pressable` behavior for interactive cards and rows, with accessible names and at least 44-point targets. Show progress without covering navigation or blocking the rest of the app.
- Make keyboard behavior deliberate: Done submits/dismisses, tapping outside dismisses, scrolling dismisses, and focused fields remain visible. Do not place the everyday action behind an open keyboard.
- Back must preserve the account, current form and import progress. Use explicit fallback destinations for root setup pages. Permission or import failures must offer a recoverable state.
- One Start action should carry out the selected work. Advance only from committed state; do not require a tap for each internal batch. Cancellation, errors, partial results, account changes and process interruption must stop or pause safely.
- Verify narrow screens, larger text, the keyboard, loading/error/empty/progress states and actual rendered screenshots before installing a redesign. UI tests must check interactions, not only text presence.

Review every new screen against this list. Do not use default Material colour, typography or component styling as a replacement for these tokens.
