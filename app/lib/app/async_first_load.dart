import 'package:flutter_riverpod/flutter_riverpod.dart';

/// True only while nothing has been loaded yet.
///
/// `isLoading` is also true while a provider that already holds data is
/// refreshed (after a save, a sync, a pull-to-refresh). A screen or a combining
/// provider that swaps its content for a spinner on `isLoading` therefore
/// flashes on every refresh. Use this where the old data should stay on screen
/// until the new data replaces it.
extension AsyncFirstLoad<T> on AsyncValue<T> {
  bool get isFirstLoad => isLoading && !hasValue;
}
