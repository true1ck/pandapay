import 'package:flutter/material.dart';

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
          Icon(icon, size: 48, color: Theme.of(context).colorScheme.primary),
          const SizedBox(height: 16),
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
