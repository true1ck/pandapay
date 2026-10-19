import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'catalogue_repository.dart';

const userCategoriesCacheKey = 'user_categories';

/// Stores categories created by the signed-in user in namespaced local
/// preferences. They intentionally remain separate from the public server
/// catalogue until the API has a user-category sync contract.
class UserCategoriesRepository {
  const UserCategoriesRepository();

  String _key(String namespace) => '$userCategoriesCacheKey:$namespace';

  List<SpendCategory> read(
    SharedPreferences preferences,
    String namespace,
  ) {
    final raw = preferences.getString(_key(namespace));
    if (raw == null) return const [];
    try {
      final decoded = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
      return decoded
          .map(SpendCategory.fromJson)
          .where((category) => category.isCustom)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<SpendCategory> add(
    SharedPreferences preferences,
    String namespace,
    String name,
  ) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) throw ArgumentError('Category name is required');
    if (trimmed.length > 40) {
      throw ArgumentError('Category name must be 40 characters or fewer');
    }
    final existing = read(preferences, namespace);
    final match = existing.where(
      (category) => category.name.toLowerCase() == trimmed.toLowerCase(),
    );
    if (match.isNotEmpty) return match.first;

    final category = SpendCategory(
      id: 'custom:${const Uuid().v4()}',
      slug: 'custom:${trimmed.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-')}',
      name: trimmed,
      isCustom: true,
    );
    await preferences.setString(
      _key(namespace),
      jsonEncode(
        [...existing, category].map((item) => item.toJson()).toList(),
      ),
    );
    return category;
  }
}
