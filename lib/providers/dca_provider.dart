import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:uuid/uuid.dart';

import '../core/constants/app_constants.dart';
import '../models/dca_entry.dart';

final dcaProvider = NotifierProvider<DcaNotifier, List<DcaEntry>>(
  DcaNotifier.new,
);

class DcaNotifier extends Notifier<List<DcaEntry>> {
  static const _uuid = Uuid();

  Box<String> get _box => Hive.box<String>(AppConstants.dcaBoxEncrypted);

  @override
  List<DcaEntry> build() {
    return _loadEntries();
  }

  List<DcaEntry> _loadEntries() {
    return _box.values
        .map((s) => DcaEntry.fromJsonString(s))
        .toList()
      ..sort((a, b) => b.date.compareTo(a.date)); // newest first
  }

  Future<void> addEntry({
    required double btcAmount,
    required double pricePerBtc,
    required String currency,
    required DateTime date,
    String? note,
  }) async {
    await _put(DcaEntry(
      id: _uuid.v4(),
      btcAmount: btcAmount,
      pricePerBtc: pricePerBtc,
      currency: currency,
      date: date,
      note: _normalizeNote(note),
    ));
  }

  /// Rewrites every field of the entry with [id]; a blank [note] clears it.
  Future<void> updateEntry({
    required String id,
    required double btcAmount,
    required double pricePerBtc,
    required String currency,
    required DateTime date,
    String? note,
  }) async {
    await _put(DcaEntry(
      id: id,
      btcAmount: btcAmount,
      pricePerBtc: pricePerBtc,
      currency: currency,
      date: date,
      note: _normalizeNote(note),
    ));
  }

  Future<void> removeEntry(String id) async {
    await _box.delete(id);
    state = _loadEntries();
  }

  Future<void> _put(DcaEntry entry) async {
    await _box.put(entry.id, entry.toJsonString());
    state = _loadEntries();
  }

  static String? _normalizeNote(String? note) {
    final trimmed = note?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }
}
