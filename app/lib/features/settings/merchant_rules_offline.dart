import 'dart:convert';

import '../../app/providers.dart'
    show
        cacheNamespaceProvider,
        commandOutboxProvider,
        merchantCategoryRulesRepositoryProvider,
        responseCacheProvider;
import '../../data/local_first/command_outbox.dart';
import '../../data/merchant_category_rules_repository.dart';
import '../account/account_local_first.dart';

/// WP-C11: the future merchant rules list is saved on the phone and edits made
/// offline are queued with the rule's expected version.
String _key(dynamic ref) => '${ref.read(cacheNamespaceProvider)}:merchant_future_rules';

Future<List<MerchantCategoryRule>?> readRulesCache(dynamic ref) async {
  try {
    final cache = await ref.read(responseCacheProvider.future);
    final raw = await cache.get(_key(ref)) as String?;
    if (raw == null) return null;
    return [
      for (final m in jsonDecode(raw) as List)
        MerchantCategoryRule.fromJson(Map<String, dynamic>.from(m as Map)),
    ];
  } catch (_) {
    return null;
  }
}

Future<void> writeRulesCache(dynamic ref, List<MerchantCategoryRule> rules) async {
  try {
    final cache = await ref.read(responseCacheProvider.future);
    await cache.put(_key(ref), jsonEncode([for (final r in rules) r.toJson()]));
  } catch (_) {}
}

/// Rule ids that have an edit waiting to be sent.
Future<Set<String>> pendingRuleIds(dynamic ref) async {
  try {
    final commands = await ref.read(commandOutboxProvider.future) as CommandOutbox;
    return {
      for (final c in commands.pendingOf({
        AccountCommand.merchantRuleUpdate,
        AccountCommand.merchantRuleDisable,
      }))
        c.payload['ruleId'] as String,
    };
  } catch (_) {
    return {};
  }
}

/// Queue handlers. A version conflict re-fetches the list (so the next view
/// shows the server's rule) and then fails permanently: the command is parked
/// with the "changed on another device" message instead of overwriting.
Map<String, CommandHandler> merchantRuleHandlers(dynamic ref) {
  Future<void> guarded(
    Future<void> Function(MerchantCategoryRulesRepository) run,
  ) async {
    final repo =
        ref.read(merchantCategoryRulesRepositoryProvider)
            as MerchantCategoryRulesRepository?;
    if (repo == null) throw StateError('Sign in to send this');
    try {
      await run(repo);
    } on MerchantRuleConflictException {
      try {
        await writeRulesCache(ref, await repo.fetchRules());
      } catch (_) {}
      rethrow;
    }
  }

  return {
    AccountCommand.merchantRuleUpdate: (p) => guarded(
      (repo) => repo.update(
        p['ruleId'] as String,
        categoryId: p['categoryId'] as String?,
        userCategoryId: p['userCategoryId'] as String?,
        isActive: p['isActive'] as bool?,
        expectedVersion: (p['expectedVersion'] as num?)?.toInt(),
      ),
    ),
    AccountCommand.merchantRuleDisable: (p) => guarded(
      (repo) => repo.disable(
        p['ruleId'] as String,
        expectedVersion: (p['expectedVersion'] as num?)?.toInt(),
      ),
    ),
  };
}
