/// `PriceData.fetchedAt` in the Hive cache (review round 1, I3).
///
/// It used to be stored as a local wall-clock time with no offset. Read
/// after a westward time-zone change, or with the clock set back, that time
/// lay in the future: the cache never looked stale (no refresh for hours),
/// and the widget took a refused request's cached data for one fetched
/// during the attempt. It is now stored as UTC and read back as local time.
/// An entry written before keeps parsing as local, exactly as it did.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:bag/models/price_data.dart';

PriceData _at(DateTime fetchedAt) => PriceData(
  prices: const {'usd': 100000, 'chf': 90000},
  changes24h: const {'usd': 1.5},
  fetchedAt: fetchedAt,
  staleCurrencies: const {'chf'},
);

void main() {
  final t = DateTime(2026, 11, 23, 9, 41, 7, 123);

  test('stored as UTC, with its offset', () {
    final stored = _at(t).toJson()['fetchedAt'] as String;

    expect(stored, t.toUtc().toIso8601String());
    expect(stored, endsWith('Z'));
    // The string names the instant, so the zone it is read in doesn't move
    // it.
    expect(DateTime.parse(stored).isUtc, isTrue);
    expect(
      DateTime.parse(stored).millisecondsSinceEpoch,
      t.millisecondsSinceEpoch,
    );
  });

  test('a round trip keeps the instant and reads back local time', () {
    final back = PriceData.fromJsonString(_at(t).toJsonString());

    expect(back.fetchedAt, t);
    expect(back.fetchedAt.isUtc, isFalse);
    expect(back.prices, {'usd': 100000, 'chf': 90000});
    expect(back.changes24h, {'usd': 1.5});
    expect(back.staleCurrencies, {'chf'});
  });

  test('a UTC time handed in is stored and read back as the same instant', () {
    final utc = DateTime.utc(2026, 11, 23, 8, 41, 7);

    final back = PriceData.fromJsonString(_at(utc).toJsonString());

    expect(back.fetchedAt.isAtSameMomentAs(utc), isTrue);
    expect(back.fetchedAt.isUtc, isFalse);
  });

  test('an entry written before (local time, no offset) reads exactly as '
      'it did: no migration', () {
    const old =
        '{"prices":{"usd":100000.0},"changes24h":{},'
        '"fetchedAt":"2026-11-23T09:41:07.123"}';

    final p = PriceData.fromJsonString(old);

    expect(p.fetchedAt, DateTime.parse('2026-11-23T09:41:07.123'));
    expect(p.fetchedAt, t);
    expect(p.fetchedAt.isUtc, isFalse);
  });

  test('isStale from a stored entry: fresh at 9 min, stale at 11', () {
    PriceData stored(Duration age) => PriceData.fromJsonString(
      _at(DateTime.now().subtract(age)).toJsonString(),
    );

    expect(stored(const Duration(minutes: 9)).isStale, isFalse);
    expect(stored(const Duration(minutes: 11)).isStale, isTrue);
  });
}
