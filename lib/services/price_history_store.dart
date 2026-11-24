/// Encrypted-at-rest cache of historical BTC prices (one per currency and
/// day).
///
/// The DCA sheet looks up the price on the day of each purchase, so the set
/// of cached dates is the set of days the user bought on: the same "when"
/// the encrypted DCA box exists to hide. These prices used to sit in the
/// plaintext `price_cache` box under `hist_<currency>_<yyyy-mm-dd>` keys.
///
/// Hive encrypts values only and writes keys in the clear, so the whole cache
/// is one JSON value under a single fixed key: no date ever appears in a key.
/// The box has its own AES key (same scheme as the DCA box, a separate
/// secure-storage entry), so nothing here can touch the DCA log's key.
///
/// It is a cache of public data: if the box can't be opened, historical
/// prices are simply fetched again and not stored anywhere.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../core/constants/app_constants.dart';
import 'dca_store.dart' show loadOrCreateHiveKey;

class PriceHistoryStore {
  PriceHistoryStore._();

  static const _keyName = 'price_hist_box_key';
  static const _entryKey = 'prices';
  static const _legacyPrefix = 'hist_';

  static Box<String>? _box;
  static Map<String, double> _prices = {};

  /// Whether the encrypted box is open. Without it nothing is cached.
  static bool get isOpen => _box?.isOpen ?? false;

  /// Opens the encrypted box and moves any legacy `hist_` entries out of the
  /// plaintext price box. Call from `main()` after the price box and the DCA
  /// box are open. Never throws: a failure leaves the cache off for this
  /// launch and the legacy entries in place for the next one.
  static Future<void> open() async {
    if (isOpen) return;
    try {
      final cipher = HiveAesCipher(await loadOrCreateHiveKey(_keyName));
      final box = await _openGuarded(cipher);
      _prices = _decode(box.get(_entryKey));
      _box = box;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[PriceHistory] box unavailable: ${e.runtimeType}');
      }
      return;
    }
    await _migrateLegacy();
  }

  /// Hive's `openBox` also fails a private future nobody listens to, which
  /// would surface as an uncaught error. Opened in a guarded zone, the
  /// failure reaches only the caller.
  static Future<Box<String>> _openGuarded(HiveCipher cipher) {
    final result = Completer<Box<String>>();
    runZonedGuarded(() async {
      try {
        result.complete(await Hive.openBox<String>(
          AppConstants.priceHistoryBox,
          encryptionCipher: cipher,
        ));
      } catch (e, s) {
        if (!result.isCompleted) result.completeError(e, s);
      }
    }, (_, __) {});
    return result.future;
  }

  /// The cached closing price of BTC in [currency] on [date], if any.
  static double? read(String currency, DateTime date) =>
      isOpen ? _prices[_key(currency, date)] : null;

  /// Caches [price] for [currency] on [date]. Does nothing when the box is
  /// not open: historical prices are never written anywhere in plaintext.
  static Future<void> write(String currency, DateTime date, double price) async {
    if (!isOpen) return;
    _prices[_key(currency, date)] = price;
    await _persist();
  }

  @visibleForTesting
  static void debugReset() {
    _box = null;
    _prices = {};
  }

  static String _key(String currency, DateTime date) =>
      '${currency.toLowerCase()}_${date.year}-'
      '${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';

  static Map<String, double> _decode(String? raw) {
    if (raw == null || raw.isEmpty) return {};
    try {
      return (jsonDecode(raw) as Map<String, dynamic>)
          .map((k, v) => MapEntry(k, (v as num).toDouble()));
    } catch (_) {
      return {};
    }
  }

  static Future<void> _persist() async {
    final box = _box!;
    await box.put(_entryKey, jsonEncode(_prices));
    await box.flush();
  }

  /// Copies `hist_<currency>_<date>` entries from the plaintext price box,
  /// flushes them, and only then deletes them there and compacts the file:
  /// Hive leaves a deleted value in the file until it is compacted.
  /// Idempotent, so a kill midway just repeats it on the next launch.
  static Future<void> _migrateLegacy() async {
    if (!Hive.isBoxOpen(AppConstants.priceBox)) return;
    final plain = Hive.box<String>(AppConstants.priceBox);
    final legacy = [
      for (final k in plain.keys)
        if (k is String && k.startsWith(_legacyPrefix)) k,
    ];
    if (legacy.isEmpty) return;
    try {
      for (final k in legacy) {
        final price = double.tryParse(plain.get(k) ?? '');
        if (price != null) {
          _prices.putIfAbsent(k.substring(_legacyPrefix.length), () => price);
        }
      }
      await _persist();
      await plain.deleteAll(legacy);
      await plain.compact();
      if (kDebugMode) {
        debugPrint('[PriceHistory] moved ${legacy.length} entries out of '
            'the plaintext box');
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[PriceHistory] migration failed: ${e.runtimeType}');
      }
    }
  }
}
