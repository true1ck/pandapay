import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'catalogue_repository.dart';
import 'local/app_database.dart';
import 'local/sync_queue.dart';

const userCategoriesCacheKey = 'user_categories';

/// Local-first storage for categories created by one signed-in account.
///
/// The SQLite row is written before the sync request is attempted. The queue
/// then retries the same stable UUID until the server accepts it, so airplane
/// mode and process death cannot lose a category. SharedPreferences is read
/// only as a migration source for categories created by the first local-only
/// implementation.
class UserCategoriesRepository {
  const UserCategoriesRepository();

  String _key(String namespace) => '$userCategoriesCacheKey:$namespace';

  List<SpendCategory> readLegacy(
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

  List<SpendCategory> readLocal(AppDatabase database, String namespace) {
    final rows = database.db.select(
      'SELECT id, name, slug FROM user_categories WHERE namespace=? ORDER BY created_at, name COLLATE NOCASE',
      [namespace],
    );
    return rows
        .map(
          (row) => SpendCategory(
            id: row['id'] as String,
            slug: row['slug'] as String,
            name: row['name'] as String,
            isCustom: true,
          ),
        )
        .toList();
  }

  Future<void> migrateLegacy(
    AppDatabase database,
    SyncQueue queue,
    SharedPreferences preferences,
    String namespace,
  ) async {
    final legacy = readLegacy(preferences, namespace);
    if (legacy.isEmpty) return;
    for (final category in legacy) {
      final id = userCategoryIdForServer(category.id) ?? const Uuid().v4();
      final localId = 'custom:$id';
      final exists = database.db.select(
        'SELECT 1 FROM user_categories WHERE namespace=? AND id=?',
        [namespace, localId],
      );
      if (exists.isNotEmpty) continue;
      _insertLocal(database, namespace, localId, category.name, category.slug);
      queue.enqueueInsert(
        entity: 'user_categories',
        entityId: id,
        fields: {'name': category.name, 'slug': category.slug},
      );
    }
    await preferences.remove(_key(namespace));
  }

  Future<SpendCategory> add({
    required AppDatabase database,
    required SyncQueue queue,
    required String namespace,
    required String name,
  }) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) throw ArgumentError('Category name is required');
    if (trimmed.length > 40) {
      throw ArgumentError('Category name must be 40 characters or fewer');
    }
    final existing = readLocal(database, namespace);
    final match = existing.where(
      (category) => category.name.toLowerCase() == trimmed.toLowerCase(),
    );
    if (match.isNotEmpty) return match.first;

    final id = const Uuid().v4();
    final category = SpendCategory(
      id: 'custom:$id',
      slug: 'custom:${trimmed.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-')}',
      name: trimmed,
      isCustom: true,
    );
    _insertLocal(database, namespace, category.id, category.name, category.slug);
    queue.enqueueInsert(
      entity: 'user_categories',
      entityId: id,
      fields: {'name': category.name, 'slug': category.slug},
    );
    return category;
  }

  void upsertRemote(
    AppDatabase database,
    String namespace,
    SpendCategory category,
  ) {
    _insertLocal(
      database,
      namespace,
      'custom:${category.id}',
      category.name,
      category.slug,
    );
  }

  void _insertLocal(
    AppDatabase database,
    String namespace,
    String id,
    String name,
    String slug,
  ) {
    final now = DateTime.now().millisecondsSinceEpoch;
    database.db.execute(
      '''INSERT INTO user_categories(namespace,id,name,slug,created_at,updated_at)
         VALUES(?,?,?,?,?,?)
         ON CONFLICT(namespace,id) DO UPDATE SET name=excluded.name, slug=excluded.slug, updated_at=excluded.updated_at''',
      [namespace, id, name, slug, now, now],
    );
  }
}
