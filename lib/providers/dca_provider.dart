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

  Box<String> get _box => Hive.box<String>(AppConstants.dcaBox);

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
    final entry = DcaEntry(
      id: _uuid.v4(),
      btcAmount: btcAmount,
      pricePerBtc: pricePerBtc,
      currency: currency,
      date: date,
      note: note?.trim().isEmpty == true ? null : note?.trim(),
    );
    await _box.put(entry.id, entry.toJsonString());
    state = _loadEntries();
  }

  Future<void> removeEntry(String id) async {
    await _box.delete(id);
    state = _loadEntries();
  }

  Future<void> updateEntry(DcaEntry updated) async {
    await _box.put(updated.id, updated.toJsonString());
    state = _loadEntries();
  }
}
