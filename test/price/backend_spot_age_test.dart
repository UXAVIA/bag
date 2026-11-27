/// bitbag.app's spot answer carries the time its cron fetched the prices
/// (`fetchedAt`). One older than [AppConstants.backendSpotMaxAge] is skipped,
/// so a stalled cron falls through to the next source instead of showing a
/// frozen price as fresh (backend audit, 2.0.1).
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:bag/core/constants/app_constants.dart';
import 'package:bag/services/price_service.dart';

void main() {
  final now = DateTime.utc(2026, 11, 25, 18, 0);

  test('the limit is 15 minutes', () {
    expect(AppConstants.backendSpotMaxAge, const Duration(minutes: 15));
  });

  test('a fresh answer is not stale', () {
    expect(isBackendSpotStale('2026-11-25T17:54:00.000Z', now), isFalse);
    expect(isBackendSpotStale('2026-11-25T17:45:00.000Z', now), isFalse);
  });

  test('an answer older than 15 minutes is stale', () {
    expect(isBackendSpotStale('2026-11-25T17:44:59.000Z', now), isTrue);
    expect(isBackendSpotStale('2026-11-25T14:18:10.000Z', now), isTrue);
  });

  test('a missing or unreadable time is not treated as stale', () {
    expect(isBackendSpotStale(null, now), isFalse);
    expect(isBackendSpotStale('', now), isFalse);
    expect(isBackendSpotStale('yesterday', now), isFalse);
    expect(isBackendSpotStale(1795600000, now), isFalse);
  });

  test('a time in the future (a slow device clock) is not stale', () {
    expect(isBackendSpotStale('2026-11-25T18:20:00.000Z', now), isFalse);
  });

  test('the comparison is in UTC whatever the device time zone', () {
    expect(
      isBackendSpotStale('2026-11-25T17:50:00.000Z', now.toLocal()),
      isFalse,
    );
  });
}
