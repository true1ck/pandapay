import 'package:flutter/material.dart';

import '../../app/design/app_theme.dart' show BambooInk;

/// Uses the app's inherited typography, with no font/network work at file pick.
class ImportFilePrompt extends StatelessWidget {
  final IconData icon;
  final String title;
  final String message;
  final Widget action;
  const ImportFilePrompt({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    required this.action,
  });
  @override
  Widget build(BuildContext context) => Center(
    child: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: BambooInk.paperMuted,
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: BambooInk.hairlineOnPaper),
            ),
            child: Icon(
              icon,
              size: 34,
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
          const SizedBox(height: 20),
          Text(
            title,
            style: Theme.of(context).textTheme.titleLarge,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(message, textAlign: TextAlign.center),
          const SizedBox(height: 20),
          action,
        ],
      ),
    ),
  );
}
