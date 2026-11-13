import 'package:flutter/material.dart';

/// The one sentence for "kept on this phone, will send later" (WP-C12b).
const savedOfflineCopy = "Saved on this phone. It will sync when you're online.";

/// Shows [savedOfflineCopy] (or "[what] saved on this phone..." when [what]
/// is given, e.g. `what: 'Note'`).
void showSavedOfflineSnack(BuildContext context, {String? what}) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(
        what == null
            ? savedOfflineCopy
            : '$what saved on this phone. It will sync when you\'re online.',
      ),
    ),
  );
}
