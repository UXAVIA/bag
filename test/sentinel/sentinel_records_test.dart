/// The records, watch-map builder and alert copy Sentinel shares between its
/// Android foreground service and the iOS background run
/// (`lib/services/sentinel_records.dart`). The JSON keys are the stored
/// format of two encrypted blobs, and the copy is what users already read in
/// their notifications, so both are pinned here.
library;

import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:bag/core/constants/app_constants.dart';
import 'package:bag/services/sentinel_records.dart';
import 'package:bag/services/wallet/biometric_storage_service.dart';
import 'package:bag/services/wallet/wallet_engine.dart';
import 'package:bag/services/wallet/wallet_scanner.dart';

// BIP84 test vector (account 0 of the "abandon … about" mnemonic).
const _bip84Zpub =
    'zpub6rFR7y4Q2AijBEqTUquhVz398htDFrtymD9xYYfG1m4wAcvPhXNfE3EfH1r1ADqtfSdVCToUG868RvUUkgDKf31mGDtKsAYz2oz2AGutZYs';
const _xpub1 =
    'xpub661MyMwAqRbcFtXgS5sYJABqqG9YLmC4Q1Rdap9gSE8NqtwybGhePY2gZ29ESFjqJoCu1Rupje8YtGqsefD265TMg7usUDFdp6W1EGMcet8';
const _xpub2 =
    'xpub661MyMwAqRbcFW31YEwpkMuc5THy2PSt5bDMsktWQcFF8syAmRUapSCGu8ED9W6oDMSgv6Zz8idoc4a6mr8BDzTJY47LJhkJ8UB7WEGuduB';

WalletBalance _balance({
  List<String> utxoAddresses = const [],
  int nextExternalIndex = 0,
  int nextChangeIndex = 0,
}) => WalletBalance(
  totalSats: 1000,
  usedAddressCount: 1,
  lastExternalIndex: 0,
  lastChangeIndex: 0,
  nextExternalIndex: nextExternalIndex,
  nextChangeIndex: nextChangeIndex,
  utxoAddresses: utxoAddresses,
);

SentinelAlert _alert(
  SentinelAlertKind kind, {
  int sats = 100000,
  bool incoming = true,
  int count = 0,
}) => SentinelAlert(
  kind: kind,
  walletLabel: 'Cold',
  sats: sats,
  notifId: 7,
  incoming: incoming,
  count: count,
);

/// In-memory secure storage whose next [failReads] reads throw, as a keystore
/// error would.
class _FlakyReads extends TestFlutterSecureStoragePlatform {
  _FlakyReads(super.data);

  int failReads = 0;

  @override
  Future<String?> read({
    required String key,
    required Map<String, String> options,
  }) async {
    if (failReads > 0) {
      failReads--;
      throw PlatformException(code: 'keystore', message: 'unavailable');
    }
    return super.read(key: key, options: options);
  }
}

void main() {
  group('SentinelSeenTx', () {
    test('seen tx JSON keeps the stored keys', () {
      final tx = SentinelSeenTx(
        walletId: 'w1',
        walletLabel: 'Cold',
        dir: 'in',
        sats: 1234,
        seenAt: DateTime.utc(2026, 11, 26, 9),
        notifId: 99,
      );
      expect(tx.toJson().keys.toSet(), {
        'wid',
        'wlabel',
        'dir',
        'sats',
        'seenAt',
        'nid',
        'conf',
      });

      final back = SentinelSeenTx.fromJson(tx.toJson());
      expect(back.walletId, 'w1');
      expect(back.walletLabel, 'Cold');
      expect(back.dir, 'in');
      expect(back.sats, 1234);
      expect(back.seenAt, DateTime.utc(2026, 11, 26, 9));
      expect(back.notifId, 99);
      expect(back.confirmedAlerted, isFalse);
    });

    test('a record stored without conf reads as not yet confirmed', () {
      final json = {
        'wid': 'w1',
        'wlabel': 'Cold',
        'dir': 'out',
        'sats': 5,
        'seenAt': DateTime.utc(2026, 11, 26).toIso8601String(),
        'nid': 1,
      };
      expect(SentinelSeenTx.fromJson(json).confirmedAlerted, isFalse);
    });

    test('copyWith sets confirmedAlerted and keeps everything else', () {
      final tx = SentinelSeenTx(
        walletId: 'w1',
        walletLabel: 'Cold',
        dir: 'out',
        sats: 5,
        seenAt: DateTime.utc(2026, 11, 26),
        notifId: 1,
      );
      final confirmed = tx.copyWith(confirmedAlerted: true);
      expect(confirmed.confirmedAlerted, isTrue);
      expect(confirmed.toJson()..remove('conf'), tx.toJson()..remove('conf'));
    });
  });

  group('SentinelWatchEntry', () {
    test('JSON keys are wid and wlabel', () {
      const entry = SentinelWatchEntry(walletId: 'w1', walletLabel: 'Cold');
      expect(entry.toJson(), {'wid': 'w1', 'wlabel': 'Cold'});
      final back = SentinelWatchEntry.fromJson(entry.toJson());
      expect(back.walletId, 'w1');
      expect(back.walletLabel, 'Cold');
    });

    test('a live entry has no retiredAt, so the stored format Android '
        'writes and reads is unchanged (R31)', () {
      const entry = SentinelWatchEntry(walletId: 'w1', walletLabel: 'Cold');
      expect(entry.retiredAt, isNull);
      expect(entry.isRetired, isFalse);
      expect(entry.toJson().keys, ['wid', 'wlabel']);

      final back = SentinelWatchEntry.fromJson({'wid': 'w1', 'wlabel': 'Cold'});
      expect(back.retiredAt, isNull);
      expect(back.isRetired, isFalse);
    });

    test('a retired entry stores retiredAt in UTC and reads it back', () {
      final at = DateTime.utc(2026, 11, 20, 8, 30);
      final entry = SentinelWatchEntry(
        walletId: 'w1',
        walletLabel: 'Cold',
        retiredAt: at.toLocal(),
      );
      final json = entry.toJson();
      expect(json, {
        'wid': 'w1',
        'wlabel': 'Cold',
        'retiredAt': '2026-11-20T08:30:00.000Z',
      });

      final back = SentinelWatchEntry.fromJson(
        jsonDecode(jsonEncode(json)) as Map<String, dynamic>,
      );
      expect(back.isRetired, isTrue);
      expect(back.retiredAt!.isAtSameMomentAs(at), isTrue);
    });

    test('a retired entry expires once kept 30 days, not before', () {
      final now = DateTime.utc(2026, 11, 26, 12);
      SentinelWatchEntry retired(Duration ago) => SentinelWatchEntry(
        walletId: 'w1',
        walletLabel: 'Cold',
        retiredAt: now.subtract(ago),
      );
      expect(iosSentinelSeenMaxAge, const Duration(days: 30));
      expect(retired(const Duration(days: 29)).expiredAt(now), isFalse);
      expect(retired(const Duration(days: 30)).expiredAt(now), isFalse);
      expect(
        retired(const Duration(days: 30, seconds: 1)).expiredAt(now),
        isTrue,
      );
      const live = SentinelWatchEntry(walletId: 'w1', walletLabel: 'Cold');
      expect(live.expiredAt(now), isFalse);
    });
  });

  group('retireSentinelWatchEntries (R31)', () {
    final now = DateTime.utc(2026, 11, 26, 12);
    const label = 'Cold';
    SentinelWatchEntry live(String wid, [String l = label]) =>
        SentinelWatchEntry(walletId: wid, walletLabel: l);
    SentinelWatchEntry retiredSince(DateTime at, [String wid = 'w1']) =>
        SentinelWatchEntry(walletId: wid, walletLabel: label, retiredAt: at);

    test('an address the rescan no longer lists stays, retired since now',
        () {
      final map = {'spent': live('w1'), 'change': live('w1')};

      retireSentinelWatchEntries(
        map,
        walletId: 'w1',
        walletLabel: label,
        fresh: {'change': live('w1'), 'next': live('w1')},
        now: now,
      );

      expect(map.keys, unorderedEquals(['spent', 'change', 'next']));
      expect(map['spent']!.retiredAt, now);
      expect(map['change']!.isRetired, isFalse);
      expect(map['next']!.isRetired, isFalse);
    });

    test('an entry already retired keeps the time it was first dropped', () {
      final first = now.subtract(const Duration(days: 3));
      final map = {'spent': retiredSince(first)};

      retireSentinelWatchEntries(
        map,
        walletId: 'w1',
        walletLabel: label,
        fresh: {'next': live('w1')},
        now: now,
      );

      expect(map['spent']!.retiredAt, first);
    });

    test('a rescan that lists the address again makes it live', () {
      final map = {
        'back': retiredSince(now.subtract(const Duration(days: 3))),
      };

      retireSentinelWatchEntries(
        map,
        walletId: 'w1',
        walletLabel: label,
        fresh: {'back': live('w1')},
        now: now,
      );

      expect(map['back']!.isRetired, isFalse);
      expect(map['back']!.toJson().keys, ['wid', 'wlabel']);
    });

    test('a retired entry kept more than 30 days goes; one kept 30 days '
        'stays', () {
      final map = {
        'old': retiredSince(now.subtract(const Duration(days: 31))),
        'month': retiredSince(now.subtract(const Duration(days: 30))),
        'otherOld': retiredSince(
          now.subtract(const Duration(days: 31)),
          'w2',
        ),
      };

      retireSentinelWatchEntries(
        map,
        walletId: 'w1',
        walletLabel: label,
        fresh: {'next': live('w1')},
        now: now,
      );

      expect(map.keys, unorderedEquals(['month', 'next']));
    });

    test("other wallets' entries are left as they are, and the wallet's "
        'retired entries take its current label', () {
      final map = {
        'spent': live('w1', 'Old name'),
        'theirs': live('w2', 'Hot'),
        'theirsRetired': retiredSince(now, 'w2'),
      };

      retireSentinelWatchEntries(
        map,
        walletId: 'w1',
        walletLabel: 'New name',
        fresh: {'next': live('w1', 'New name')},
        now: now,
      );

      expect(map['spent']!.walletLabel, 'New name');
      expect(map['theirs']!.walletLabel, 'Hot');
      expect(map['theirs']!.isRetired, isFalse);
      expect(map['theirsRetired']!.retiredAt, now);
    });
  });

  group('sentinelWatchEntries', () {
    test('watch entries cover UTXOs and both frontiers', () {
      final source = ZpubAddressSource(parseZpub(_bip84Zpub));
      final utxos = [source.addressAt(0, 0), source.addressAt(1, 0)];
      final entries = sentinelWatchEntries(
        walletId: 'w1',
        walletLabel: 'Cold',
        source: source,
        balance: _balance(
          utxoAddresses: utxos,
          nextExternalIndex: 3,
          nextChangeIndex: 1,
        ),
      );

      // Receive index 0 and change index 0 are UTXO addresses, and neither
      // lies on a frontier (3..7 and 1..5), so nothing overlaps.
      expect(entries.length, 2 + 5 + 5);
      for (final a in utxos) {
        expect(entries, contains(a));
      }
      for (var i = 3; i <= 7; i++) {
        expect(entries, contains(source.addressAt(0, i)));
      }
      for (var i = 1; i <= 5; i++) {
        expect(entries, contains(source.addressAt(1, i)));
      }
      for (final e in entries.values) {
        expect(e.walletId, 'w1');
        expect(e.walletLabel, 'Cold');
      }
    });

    test('a receive-only source gets no change frontier', () {
      final source = DescriptorAddressSource(
        parseDescriptor('wsh(sortedmulti(2,$_xpub1/0/*,$_xpub2/0/*))'),
      );
      expect(source.hasChain(1), isFalse);
      final utxos = [source.addressAt(0, 0), source.addressAt(0, 1)];
      final entries = sentinelWatchEntries(
        walletId: 'w1',
        walletLabel: 'Multi',
        source: source,
        balance: _balance(
          utxoAddresses: utxos,
          nextExternalIndex: 2,
          nextChangeIndex: 0,
        ),
      );
      expect(entries.length, 2 + 5);
      for (var i = 2; i <= 6; i++) {
        expect(entries, contains(source.addressAt(0, i)));
      }
    });

    test('an empty wallet watches both frontiers from index 0', () {
      final source = ZpubAddressSource(parseZpub(_bip84Zpub));
      final entries = sentinelWatchEntries(
        walletId: 'w1',
        walletLabel: 'Cold',
        source: source,
        balance: _balance(),
      );
      expect(entries.length, 10);
      expect(entries, contains(source.addressAt(0, 0)));
      expect(entries, contains(source.addressAt(1, 0)));
    });
  });

  group('sentinelNotifId', () {
    test('notif id is the first 8 hex digits, masked', () {
      expect(sentinelNotifId('ffffffff${'a' * 56}'), 0x7FFFFFFF);
      expect(sentinelNotifId('00000001${'b' * 56}'), 1);
      expect(sentinelNotifId('1a2b3c4d${'0' * 56}'), 0x1a2b3c4d);
    });
  });

  group('sentinelFormatSats', () {
    test('trims trailing zeros and the dangling dot', () {
      expect(sentinelFormatSats(100000, '+'), '+₿0.001');
      expect(sentinelFormatSats(100000000, '+'), '+₿1');
      expect(sentinelFormatSats(1, '−'), '−₿0.00000001');
      expect(sentinelFormatSats(123456789, '+'), '+₿1.23456789');
    });
  });

  group('sentinelAlertCopy', () {
    test('alert copy matches Android', () {
      expect(sentinelAlertCopy(_alert(SentinelAlertKind.pendingIn)), (
        title: '⚡ Incoming — Cold',
        body: '+₿0.001 (unconfirmed)',
      ));

      final out = sentinelAlertCopy(_alert(SentinelAlertKind.pendingOut));
      expect(out.title, '🚨 Possible unauthorized spend — Cold');
      expect(out.body, '−₿0.001 (unconfirmed)');

      expect(sentinelAlertCopy(_alert(SentinelAlertKind.confirmed)), (
        title: '✅ Confirmed — Cold',
        body: '+₿0.001 received',
      ));
      expect(
        sentinelAlertCopy(_alert(SentinelAlertKind.confirmed, incoming: false)),
        (title: '✅ Confirmed — Cold', body: '−₿0.001 spent'),
      );

      expect(sentinelAlertCopy(_alert(SentinelAlertKind.received)), (
        title: '⬆ Received — Cold',
        body: '+₿0.001',
      ));
      expect(sentinelAlertCopy(_alert(SentinelAlertKind.sent)), (
        title: '⬇ Sent — Cold',
        body: '−₿0.001',
      ));

      expect(sentinelAlertCopy(_alert(SentinelAlertKind.summary, count: 4)), (
        title: '4 more transactions — Cold',
        body: 'Open Bag to see them.',
      ));
    });
  });

  group('cleanupSentinelSeen', () {
    SentinelSeenTx at(DateTime seenAt) => SentinelSeenTx(
      walletId: 'w1',
      walletLabel: 'Cold',
      dir: 'in',
      sats: 1,
      seenAt: seenAt,
      notifId: 1,
    );

    test('cleanup drops records older than 24 hours', () {
      final now = DateTime.utc(2026, 11, 26, 12);
      final seen = {
        'fresh': at(now.subtract(const Duration(hours: 23))),
        'stale': at(now.subtract(const Duration(hours: 25))),
      };
      expect(cleanupSentinelSeen(seen, now), isTrue);
      expect(seen.keys, ['fresh']);
    });

    test('cleanup takes another maximum age', () {
      final now = DateTime.utc(2026, 11, 26, 12);
      final seen = {
        'day': at(now.subtract(const Duration(hours: 25))),
        'month': at(now.subtract(const Duration(days: 31))),
      };
      expect(
        cleanupSentinelSeen(seen, now, maxAge: const Duration(days: 30)),
        isTrue,
      );
      expect(seen.keys, ['day']);
    });

    test('nothing to drop returns false', () {
      final now = DateTime.utc(2026, 11, 26, 12);
      final seen = {'fresh': at(now.subtract(const Duration(hours: 1)))};
      expect(cleanupSentinelSeen(seen, now), isFalse);
      expect(seen.keys, ['fresh']);
      expect(cleanupSentinelSeen({}, now), isFalse);
    });
  });

  group('watch-map replacement', () {
    const key = AppConstants.keySentinelWatchMap;

    SentinelWatchEntry entry(String wid, [String? label]) =>
        SentinelWatchEntry(walletId: wid, walletLabel: label ?? 'Wallet $wid');

    Future<void> seed(Map<String, SentinelWatchEntry> map) => writeSecureBlob(
      key,
      jsonEncode(map.map((k, v) => MapEntry(k, v.toJson()))),
    );

    /// The stored blob, decoded the way the Android service stores it.
    Future<Map<String, Map<String, dynamic>>> stored() async {
      final raw = await readSecureBlob(key);
      final decoded = jsonDecode(raw!) as Map<String, dynamic>;
      return decoded.map((k, v) => MapEntry(k, v as Map<String, dynamic>));
    }

    setUp(() {
      TestWidgetsFlutterBinding.ensureInitialized();
      FlutterSecureStorage.setMockInitialValues({});
      SharedPreferences.setMockInitialValues({});
    });

    test('a missing blob loads as an empty map', () async {
      expect(await loadSentinelWatchMap(), isEmpty);
    });

    test('the map loads the way the Android service stores it', () async {
      await seed({'bc1qa': entry('A'), 'bc1qb': entry('B')});

      final map = await loadSentinelWatchMap();

      expect(map.keys, unorderedEquals(['bc1qa', 'bc1qb']));
      expect(map['bc1qa']!.walletId, 'A');
      expect(map['bc1qb']!.walletLabel, 'Wallet B');
    });

    test('replacing a wallet\'s entries keeps other wallets', () async {
      await seed({
        'bc1qa1': entry('A'),
        'bc1qa2': entry('A'),
        'bc1qb1': entry('B'),
        'bc1qb2': entry('B'),
      });

      await replaceSentinelWatchEntries('A', {'bc1qanew': entry('A', 'Cold')});

      final blob = await stored();
      expect(blob.keys, unorderedEquals(['bc1qanew', 'bc1qb1', 'bc1qb2']));
      expect(blob['bc1qanew'], {'wid': 'A', 'wlabel': 'Cold'});
      expect(blob['bc1qb1'], {'wid': 'B', 'wlabel': 'Wallet B'});
    });

    test('replacing with no entries drops the wallet and nothing else', () async {
      await seed({'bc1qa1': entry('A'), 'bc1qb1': entry('B')});

      await replaceSentinelWatchEntries('A', {});

      expect((await stored()).keys, ['bc1qb1']);
    });

    test('a wallet with no entries yet is added to an existing map', () async {
      await seed({'bc1qb1': entry('B')});

      await replaceSentinelWatchEntries('A', {'bc1qa1': entry('A')});

      expect((await stored()).keys, unorderedEquals(['bc1qa1', 'bc1qb1']));
    });

    test('the first replacement creates the blob', () async {
      await replaceSentinelWatchEntries('A', {'bc1qa1': entry('A')});

      expect((await stored()).keys, ['bc1qa1']);
    });

    test('concurrent replacements keep both wallets', () async {
      await seed({'bc1qa0': entry('A'), 'bc1qb0': entry('B')});

      // Neither is awaited before the other starts: unchained, both would
      // read the seed and the later write would erase the earlier one.
      final a = replaceSentinelWatchEntries('A', {'bc1qa1': entry('A')});
      final b = replaceSentinelWatchEntries('B', {'bc1qb1': entry('B')});
      await Future.wait([a, b]);

      final blob = await stored();
      expect(blob.keys, unorderedEquals(['bc1qa1', 'bc1qb1']));
      expect(blob['bc1qa1']!['wid'], 'A');
      expect(blob['bc1qb1']!['wid'], 'B');
    });

    test('several concurrent replacements for one wallet end on the last',
        () async {
      final calls = [
        for (var i = 0; i < 5; i++)
          replaceSentinelWatchEntries('A', {'bc1qa$i': entry('A')}),
      ];
      await Future.wait(calls);

      expect((await stored()).keys, ['bc1qa4']);
    });

    test('a blob that is not a watch map reads as empty, like Android\'s '
        'service reads it', () async {
      await writeSecureBlob(key, 'not json');
      expect(await loadSentinelWatchMap(), isEmpty);

      await replaceSentinelWatchEntries('A', {'bc1qa1': entry('A')});
      expect((await stored()).keys, ['bc1qa1']);
    });

    group('when the keystore fails', () {
      late _FlakyReads storage;

      setUp(() {
        storage = _FlakyReads({
          key: jsonEncode({'bc1qb1': entry('B').toJson()}),
        });
        FlutterSecureStoragePlatform.instance = storage;
      });

      test('a read failure is rethrown, not read as an empty map', () async {
        storage.failReads = 1;

        await expectLater(
          loadSentinelWatchMap(),
          throwsA(isA<PlatformException>()),
        );
      });

      test('a replacement whose read fails writes nothing, so no wallet is '
          'lost', () async {
        storage.failReads = 1;

        await expectLater(
          replaceSentinelWatchEntries('A', {'bc1qa1': entry('A')}),
          throwsA(isA<PlatformException>()),
        );

        expect((await stored()).keys, ['bc1qb1']);
      });

      test('a failed replacement does not stall the ones after it', () async {
        storage.failReads = 1;

        final bad = replaceSentinelWatchEntries('A', {'bc1qa1': entry('A')});
        final good = replaceSentinelWatchEntries('C', {'bc1qc1': entry('C')});

        await expectLater(bad, throwsA(isA<PlatformException>()));
        await good;
        expect((await stored()).keys, unorderedEquals(['bc1qb1', 'bc1qc1']));
      });
    });
  });
}
