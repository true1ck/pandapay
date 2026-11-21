import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:pandapay_domain/sms_v2.dart' show uploadSenderBrand;
import 'package:pandapay_domain/sms_v2_template.dart';

import '../../../data/local/sms_intake_repository.dart';
import '../../sms_import/sms_background_queue.dart' show QueuedSms;
import '../storage/outbox_store.dart';
import '../storage/sync_state_store.dart';
import '../storage/template_origin_store.dart';

/// Whether the wording of a message (the message as it is, only its numbers made up) goes next to the layout, for the
/// AI to read. The owner chose this on 15 Nov 2026. NOTE: the consent text and privacy policy still say that only
/// layouts are shared (section 12 of docs/SMS_AI_PIPELINE_REDESIGN_PLAN_2026-11-15.md).
const bool smsShareWording = true;

/// Unknown templates enter this queue only with current sharing consent.
class TemplateUpload {
  TemplateUpload({
    required this.intake,
    required this.queue,
    required this.client,
    required this.baseUri,
    required this.headers,
    required this.hasConsent,
    this.consentWithdrawn,
    required this.accountIsCurrent,
    this.shareWording = smsShareWording,
    DateTime Function()? clock,
  }) : clock = clock ?? DateTime.now;

  final SmsIntakeRepository intake;
  final OutboxStore queue;
  final http.Client client;
  final Uri baseUri;
  final Future<Map<String, String>> Function() headers;
  final Future<bool> Function() hasConsent;

  /// True only when the server clearly says sharing is withdrawn. [hasConsent]
  /// is also false when the lookup failed, which must not erase the AI answers
  /// this phone holds. Null (callers that do not know the difference) keeps the
  /// old behaviour: any "no" erases.
  final Future<bool> Function()? consentWithdrawn;
  final bool Function() accountIsCurrent;
  final bool shareWording;
  final DateTime Function() clock;

  /// When consent was last confirmed during this drain. A pass checks it before
  /// every batch and again after the answer; each check is a call to the server
  /// (a slow, busy one on a bad day), so 36 calls went out for 16 batches.
  /// Within ten seconds of a confirmation the answer stands; a "no" is never
  /// remembered, and a new drain always asks again.
  Stopwatch? _consentConfirmed;

  Future<bool> _canShare() async {
    if (!accountIsCurrent()) return false;
    final confirmed = _consentConfirmed;
    if (confirmed != null && confirmed.elapsed < const Duration(seconds: 10)) {
      return true;
    }
    final bool consent;
    try {
      consent = await hasConsent();
    } catch (_) {
      return false;
    }
    if (!accountIsCurrent()) return false;
    if (!consent) {
      _consentConfirmed = null;
      final gone = consentWithdrawn == null || await consentWithdrawn!();
      if (!accountIsCurrent()) return false;
      if (gone) forgetSharedState(queue);
    } else {
      _consentConfirmed = Stopwatch()..start();
    }
    return consent;
  }

  /// Consent is gone: drop everything that came from sharing, including the
  /// drafts, this phone's verdicts on them and any report still waiting.
  static void forgetSharedState(OutboxStore queue) {
    queue.db.execute('SAVEPOINT sms_v2_template_revoke');
    try {
      queue.db.execute(
        "DELETE FROM v2_sync_state WHERE namespace=? AND (key LIKE 'ai:%' OR key LIKE 'template:sent:%' OR key LIKE 'template:origins:%' OR key LIKE 'template:scanned:%' OR key LIKE 'template:refused:%' OR key='template:resend:at' OR key LIKE 'draft:%')",
        [queue.namespace],
      );
      queue.db.execute(
        "DELETE FROM v2_outbox WHERE namespace=? AND kind IN ('template','draft_rejection')",
        [queue.namespace],
      );
      // Written down so a phone that lost its answers can say when and why.
      SyncStateStore(queue.db, namespace: queue.namespace).put(
        'wipe:ai:at',
        DateTime.now().toUtc().toIso8601String(),
      );
      queue.db.execute('RELEASE sms_v2_template_revoke');
    } catch (_) {
      queue.db.execute('ROLLBACK TO sms_v2_template_revoke');
      queue.db.execute('RELEASE sms_v2_template_revoke');
      rethrow;
    }
  }

  bool _validUpload(Map<String, Object?> item) {
    final brand = item['senderBrand'], body = item['redactedBody'];
    return brand is String &&
        _brandShape.hasMatch(brand) &&
        body is String &&
        body.isNotEmpty &&
        body.length <= 20000 &&
        !_unsafe.hasMatch(body) &&
        // The sample is optional; when there is one it is short and holds no link or address.
        (item['sample'] == null ||
            (item['sample'] is String &&
                (item['sample'] as String).length <= 2000 &&
                !_sampleUnsafe.hasMatch(item['sample'] as String))) &&
        item['templateHash'] == smsTemplateHash(brand, body);
  }

  static final _brandShape = RegExp(r'^[A-Z0-9]{1,32}$');
  static final _sampleUnsafe = RegExp(r'@|https?://|www\.', caseSensitive: false);

  static final _unsafe = RegExp(
    r'\d{6,}|https?://|www\.|[\w.+-]+@[\w.-]+|\b[a-z0-9-]+\.(?:com|in|co|io|ly|me|net|org)(?:\b|/)',
    caseSensitive: false,
  );

  /// Layouts per request. The server allows 50 a day per person and refuses a
  /// whole request that would pass it, so a big batch can fail for ever once a
  /// few have been sent; small ones always fit what is left.
  static const _batchSize = 10;

  /// Flat wait after a failure that is the session's or the server's, not the layout's.
  static const _transientRetry = Duration(seconds: 60);

  /// How long to wait after a 5xx: the server's Retry-After when it sent one
  /// (a paused intake says an hour), never under a minute, never over an hour.
  static Duration _serverWait(http.Response response) => Duration(
    seconds: (int.tryParse(response.headers['retry-after'] ?? '') ?? 60).clamp(
      60,
      3600,
    ),
  );

  /// Earlier builds held the whole queue for up to six hours after a 429 and
  /// pushed a failed layout's next try out to 30 minutes by doubling. A phone
  /// that updates would keep honouring those waits, so layouts that were
  /// already waiting would still sit unsent. Once per account, after the
  /// update, make them due now and forget the old hold.
  void _clearWaitsLeftByOlderBuilds() {
    final state = SyncStateStore(queue.db, namespace: queue.namespace);
    const marker = 'template:waits:cleared:v2';
    if (state.get(marker) != null) return;
    queue.db.execute(
      "UPDATE v2_outbox SET next_attempt_at=0 WHERE namespace=? AND kind='template'",
      [queue.namespace],
    );
    queue.db.execute(
      "DELETE FROM v2_sync_state WHERE namespace=? AND key='template:wait'",
      [queue.namespace],
    );
    state.put(marker, clock().toUtc().toIso8601String());
  }

  /// Messages redacted by this isolate's uploads so far (tests and measurements read it).
  static int messagesRedacted = 0;

  /// New messages read per pass. Reading one (redacting it for the layout and the wording) costs about 0.65 ms on a
  /// desktop and runs on the UI isolate, and the server takes 50 new layouts a day per person, so a backlog of
  /// thousands has nothing to gain from being read in one go: 3,000 messages took 1.9 s in one pass, now at most
  /// this many per pass, the rest at the next pass (each sync, and every few minutes while answers are awaited).
  static const maxScannedPerPass = 250;

  /// Messages read per transaction (and per hand-back of the thread): one commit per message was most of the cost.
  static const _scanChunk = 25;

  /// What a message that can never be uploaded is marked with, so it is not read again at every pass: a layout the
  /// server would refuse (too many name slots), one that fails the checks below, one whose origin cannot be kept.
  /// Bump the version when what may be uploaded changes, and they are looked at once more.
  static const _skipMark = 'skip:v1';

  static final Random _random = Random.secure();

  /// A layout the server refuses (400) is retried after this, then four times as long, up to a week: it is never
  /// lost (a refusal can be the server's fault) and never costs more than one request a week once it is known.
  static Duration _refusedWait(int refusals) {
    final hours = 6 * pow(4, (refusals - 1).clamp(0, 3)).toInt();
    return Duration(hours: hours.clamp(6, 7 * 24));
  }

  Future<void> drain() async {
    _consentConfirmed = null; // every pass asks the server afresh
    // One layout the server refuses (400) must not hold up the ones behind it:
    // after a 400 the next requests carry one layout each until it is found.
    var singly = false;
    var refused = 0;
    if (!await _canShare()) return;
    _clearWaitsLeftByOlderBuilds();
    // The server told us to wait (HTTP 429): hold the whole queue until then.
    final holdUntil = DateTime.tryParse(
      SyncStateStore(
            queue.db,
            namespace: queue.namespace,
          ).get('template:wait') ??
          '',
    );
    if (holdUntil != null && clock().isBefore(holdUntil)) return;
    // Previous builds queued the original hash with a different redacted body.
    // Rebuild those entries from the retained local capture before retrying.
    for (final row in queue.db.select(
      "SELECT id,payload FROM v2_outbox WHERE namespace=? AND kind='template'",
      [queue.namespace],
    )) {
      var valid = false;
      try {
        valid = _validUpload(
          (jsonDecode(row['payload'] as String) as Map).cast<String, Object?>(),
        );
      } catch (_) {
        // A malformed old queue entry cannot be uploaded.
      }
      if (!valid) {
        queue.db.execute('DELETE FROM v2_outbox WHERE namespace=? AND id=?', [
          queue.namespace,
          row['id'],
        ]);
      }
    }
    final state = SyncStateStore(queue.db, namespace: queue.namespace);
    await _scanOpenItems(state);
    // Layouts this phone sent that the server refused, and how many times: they are sent alone (see below).
    final refusals = <String, int>{
      for (final row in queue.db.select(
        "SELECT key,value FROM v2_sync_state WHERE namespace=? AND key LIKE 'template:refused:%'",
        [queue.namespace],
      ))
        (row['key'] as String).substring('template:refused:'.length): int.tryParse(row['value'] as String) ?? 1,
    };
    String hashOf(OutboxRecord record) => '${record.json['templateHash']}';
    while (accountIsCurrent()) {
      if (!await _canShare()) return;
      // Only layouts, chosen in SQL; a few more than a batch, so that the ones already refused (a handful at most)
      // cannot fill the window and keep the others out of it.
      final waiting = queue.due(clock(), limit: _batchSize + refusals.length, kind: 'template');
      if (waiting.isEmpty) return;
      // A layout the server has refused is never put in a batch with others: its failed request would carry them
      // too, and charge the person's daily allowance for all of them. It goes alone, after the rest.
      final clean = waiting.where((record) => !refusals.containsKey(hashOf(record))).toList();
      final records = clean.isNotEmpty ? clean.take(singly ? 1 : _batchSize).toList() : [waiting.first];
      try {
        final admission = await headers();
        if (!await _canShare()) return;
        final response = await client
            .post(
              baseUri.resolve('/sms/v2/unknown-templates'),
              headers: {...admission, 'Content-Type': 'application/json'},
              body: jsonEncode({
                'items': [
                  for (final record in records)
                    {
                      for (final key in [
                        'templateHash',
                        'senderBrand',
                        'redactedBody',
                        'observedAt',
                        'sample',
                      ])
                        key: ?record.json[key],
                    },
                ],
              }),
            )
            .timeout(const Duration(seconds: 30));
        if (!await _canShare()) return;
        if (response.statusCode == 429) {
          // A limit the server applies (counted phones have none unless the
          // owner sets one): try again within a couple of minutes, whatever
          // Retry-After says. It can be a whole day, and waiting that long left
          // a backlog of formats unsent for hours.
          final wait = Duration(
            seconds:
                (int.tryParse(response.headers['retry-after'] ?? '') ?? 60)
                    .clamp(30, 120),
          );
          for (final record in records) {
            queue.retry(record, clock(), after: wait);
          }
          SyncStateStore(
            queue.db,
            namespace: queue.namespace,
          ).put('template:wait', clock().add(wait).toUtc().toIso8601String());
          return;
        }
        if (response.statusCode == 400) {
          // The server refused the request as invalid. With several layouts in
          // it, send them one at a time to find the one it dislikes; a single
          // refused layout is set aside (not lost, and it blocks nothing): six
          // hours, then four times as long each time it is refused again, to a
          // week. The rest carry on in tens again, and the refused one is never
          // sent in a batch with them.
          // A server that refuses everything is not one bad layout: after six
          // refusals in a pass, stop and leave the rest for the next pass.
          if (++refused >= 6) return;
          if (records.length > 1) {
            singly = true;
            continue;
          }
          final hash = hashOf(records.single);
          final times = (refusals[hash] ?? 0) + 1;
          refusals[hash] = times;
          state.put('template:refused:$hash', '$times');
          queue.retry(records.single, clock(), after: _refusedWait(times));
          singly = false;
          continue;
        }
        if (response.statusCode == 401 ||
            response.statusCode == 408 ||
            response.statusCode >= 500) {
          // The session or the server is the problem, not the layout: try again
          // soon at a flat pace (or when the server said). The usual doubling
          // back-off pushed the next try out to 30 minutes.
          final wait = response.statusCode >= 500
              ? _serverWait(response)
              : _transientRetry;
          for (final record in records) {
            queue.retry(record, clock(), after: wait);
          }
          return;
        }
        if (response.statusCode != 200 && response.statusCode != 202) {
          throw const FormatException('Template upload failed');
        }
        final accepted =
            ((jsonDecode(response.body) as Map)['accepted'] as List).toSet();
        for (final record in records) {
          if (accepted.contains(record.json['templateHash'])) {
            if (queue.acknowledge(record)) {
              queue.db.execute(
                'INSERT INTO v2_sync_state(namespace,key,value) VALUES(?,?,?) ON CONFLICT(namespace,key) DO UPDATE SET value=excluded.value',
                [
                  queue.namespace,
                  'template:sent:${record.json['templateHash']}',
                  clock().toUtc().toIso8601String(),
                ],
              );
              if (refusals.remove(hashOf(record)) != null) {
                queue.db.execute('DELETE FROM v2_sync_state WHERE namespace=? AND key=?', [
                  queue.namespace,
                  'template:refused:${hashOf(record)}',
                ]);
              }
            }
          } else {
            queue.retry(record, clock());
          }
        }
        if (accepted.isEmpty) return;
      } catch (error) {
        // A timeout or a dropped connection says nothing about the layout either.
        final transient = error is TimeoutException || error is http.ClientException;
        for (final record in records) {
          queue.retry(record, clock(), after: transient ? _transientRetry : null);
        }
        return;
      }
    }
  }

  /// Reads the open Needs-review messages that have not been looked at yet, at most [maxScannedPerPass] of them,
  /// and queues the layouts that can go up. A message already queued, sent or marked as never uploadable is skipped
  /// with no redaction at all, whatever the size of the backlog: three small queries up front, then no query per
  /// message for those. Messages are read in chunks of [_scanChunk] inside one transaction each, with the thread
  /// handed back between chunks.
  Future<void> _scanOpenItems(SyncStateStore state) async {
    final db = queue.db;
    final origins = TemplateOriginStore(state);
    final scannedMarks = <String, String>{
      for (final row in db.select(
        "SELECT key,value FROM v2_sync_state WHERE namespace=? AND key LIKE 'template:scanned:%'",
        [queue.namespace],
      ))
        (row['key'] as String).substring('template:scanned:'.length): row['value'] as String,
    };
    final sentHashes = <String>{
      for (final row in db.select(
        "SELECT key FROM v2_sync_state WHERE namespace=? AND key LIKE 'template:sent:%'",
        [queue.namespace],
      ))
        (row['key'] as String).substring('template:sent:'.length),
    };
    final queuedIds = <String>{
      for (final row in db.select(
        "SELECT id FROM v2_outbox WHERE namespace=? AND kind='template'",
        [queue.namespace],
      ))
        row['id'] as String,
    };
    var read = 0;
    var inChunk = 0;
    void openChunk() => db.execute('SAVEPOINT sms_v2_template_scan');
    void closeChunk() => db.execute('RELEASE sms_v2_template_scan');
    openChunk();
    try {
      for (final row in db.select(
        "SELECT payload FROM v2_review_items WHERE namespace=? AND kind='template' AND status='open'",
        [queue.namespace],
      )) {
        final review = jsonDecode(row['payload'] as String) as Map;
        final key = review['sourceKey'];
        if (key is! String) continue;
        // Waiting for history, or already read by it: no rule can be drafted.
        if (review['aiHold'] != null) continue;
        // Already queued or sent on an earlier pass, or never uploadable: skip the redaction, which is the costly
        // part. The marker holds the layout's hash; if its sent mark and its queue entry are both gone (a re-send, a
        // cleaned-up entry), the item is processed afresh.
        final scanned = scannedMarks[key];
        if (scanned != null &&
            (scanned == _skipMark ||
                sentHashes.contains(scanned) ||
                queuedIds.contains('template:$scanned'))) {
          continue;
        }
        if (read >= maxScannedPerPass) break; // the rest waits for the next pass
        final message = intake.capturedById(queue.namespace, key)?.message;
        if (message == null) continue;
        read++;
        final upload = _layoutOf(message);
        if (upload == null ||
            !origins.remember(
              remoteHash: upload.hash,
              localHash: smsTemplateHash(upload.localBrand, smsSkeleton(message.body)),
              senderBrand: upload.brand,
              localBrand: upload.localBrand,
            )) {
          // Not a layout the server takes, or one whose origin cannot be kept (a different brand under the same
          // hash, or more wordings than an origin holds): marked, so it is not read again at every sync.
          state.put('template:scanned:$key', _skipMark);
          scannedMarks[key] = _skipMark;
        } else {
          if (!sentHashes.contains(upload.hash) && !queuedIds.contains('template:${upload.hash}')) {
            queue.enqueue('template', upload.hash, upload.payload);
            queuedIds.add('template:${upload.hash}');
          }
          state.put('template:scanned:$key', upload.hash);
          scannedMarks[key] = upload.hash;
        }
        // Hand the thread back every few items so a long backlog never freezes the screen.
        if (++inChunk >= _scanChunk) {
          inChunk = 0;
          closeChunk();
          await Future<void>.delayed(Duration.zero); // perf-ok: a chunk is 25 messages (~16 ms) and a pass reads at most 250
          openChunk();
        }
      }
      closeChunk();
    } catch (_) {
      db.execute('ROLLBACK TO sms_v2_template_scan');
      db.execute('RELEASE sms_v2_template_scan');
      rethrow;
    }
  }

  /// The layout of [message] as it goes up, or null when it is not one the server takes: more name slots than the
  /// matcher allows (it refuses such a layout only after the upload has used one of the person's 50 a day), or
  /// something that fails the checks of [_validUpload].
  ({String hash, String brand, String localBrand, Map<String, Object?> payload})? _layoutOf(QueuedSms message) {
    messagesRedacted++;
    final salt = base64UrlEncode(List.generate(32, (_) => _random.nextInt(256)));
    // One pass over the message makes the layout (names hidden) and the wording for the AI (the message as it is
    // with only its numbers made up; null, the layout alone goes, when an original number could survive). The same
    // salt gives the same made-up numbers in both.
    final pair = redactSmsPair(
      sender: message.sender,
      body: message.body,
      observedAt: message.receivedAt,
      options: SmsRedactionOptions(salt: salt),
    );
    // Cleaned before it is hashed: a bare @handle and a long mixed ID never leave the phone, and the server (which refuses any
    // `@`) can read the format.
    final safe = smsCleanLayout(smsSkeleton(pair.layout.body));
    // Name slots with fixed text after them cost the server nothing extra, so up to 12 are sent; 4 where none follows.
    if (smsLayoutWildcards(safe) > smsMaxAnchoredLayoutWildcards ||
        smsLayoutUnanchoredWildcards(safe) > smsMaxLayoutWildcards ||
        smsLayoutLooseRun(safe) > smsMaxAdjacentLooseSlots) {
      return null;
    }
    final sample = shareWording ? smsSample(original: message.body, redacted: pair.sample.body) : null;
    // The brand the server files the layout under: letters and digits only (SBI-UPI is SBIUPI), as it files facts.
    // The phone's own hashes and rules still use the header as the engine reads it.
    final localBrand = smsTemplateBrand(message.sender);
    final brand = uploadSenderBrand(localBrand);
    // Not a brand a rule can ever attach to (a phone number, or no letters at all): nothing to learn, nothing to send.
    if ((brand == 'UNKNOWN' || brand == 'NUMBER') && localBrand != brand) return null;
    final hash = smsTemplateHash(brand, safe);
    final payload = <String, Object?>{
      'templateHash': hash,
      'senderBrand': brand,
      'redactedBody': safe,
      'observedAt': message.receivedAt.toUtc().toIso8601String(),
      'sample': ?sample,
    };
    if (!_validUpload(payload)) return null;
    return (hash: hash, brand: brand, localBrand: localBrand, payload: payload);
  }
}
