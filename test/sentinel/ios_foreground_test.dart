/// iOS Sentinel Lite in the foreground (spec D3, D6, D8): the app keeps the
/// encrypted watch map up to date after each wallet scan, and turning
/// Sentinel on or off asks for notification permission, rescans and updates
/// the background schedule, with no foreground service. Android's paths are
/// untouched.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bag/core/constants/app_constants.dart';
import 'package:bag/models/chain_analysis.dart';
import 'package:bag/models/network_route.dart';
import 'package:bag/models/wallet_entry.dart';
import 'package:bag/providers/esplora_client_provider.dart';
import 'package:bag/providers/network_settings_provider.dart';
import 'package:bag/providers/purchase_provider.dart';
import 'package:bag/providers/sentinel_provider.dart';
import 'package:bag/providers/shared_preferences_provider.dart';
import 'package:bag/providers/wallets_provider.dart';
import 'package:bag/services/network/route_gate.dart';
import 'package:bag/services/notification_service.dart';
import 'package:bag/services/sentinel_ios_check.dart';
import 'package:bag/services/sentinel_records.dart';
import 'package:bag/services/sentinel_service.dart';
import 'package:bag/services/wallet/biometric_storage_service.dart';
import 'package:bag/services/wallet/esplora_client.dart';
import 'package:bag/services/wallet/wallet_scanner.dart';
import 'package:bag/services/wallet/wallet_store.dart';
import 'package:bag/services/widget_service.dart';

// BIP84 test vector account key (m/84'/0'/0').
const _zpub =
    'zpub6rFR7y4Q2AijBEqTUquhVz398htDFrtymD9xYYfG1m4wAcvPhXNfE3EfH1r1ADqtfSdVCToUG868RvUUkgDKf31mGDtKsAYz2oz2AGutZYs';

/// An explorer where no address was ever used.
final class _EmptyEsplora extends EsploraClient {
  _EmptyEsplora()
    : super(
        baseUrl: AppConstants.explorerBlockstream,
        route: const DirectRoute(),
      );

  /// Run once, before the first lookup is answered.
  Future<void> Function()? onFirstRequest;

  @override
  Future<AddressStats> fetchAddress(String address) async {
    final hook = onFirstRequest;
    onFirstRequest = null;
    await hook?.call();
    return const AddressStats(hasTransactions: false, balanceSats: 0);
  }

  @override
  Future<List<RawUtxo>> fetchUtxos(String address) async => const [];
}

/// An explorer with scripted per-address answers for the foreground scan;
/// every other address was never used.
final class _ScriptedEsplora extends EsploraClient {
  _ScriptedEsplora()
    : super(
        baseUrl: AppConstants.explorerBlockstream,
        route: const DirectRoute(),
      );

  final Map<String, AddressStats> stats = {};

  @override
  Future<AddressStats> fetchAddress(String address) async =>
      stats[address] ??
      const AddressStats(hasTransactions: false, balanceSats: 0);

  @override
  Future<List<RawUtxo>> fetchUtxos(String address) async => const [];
}

/// The background check's explorer: scripted counts and mempool lists.
class _BackgroundExplorer implements SentinelExplorer {
  final Map<String, AddressStats> stats = {};
  final Map<String, List<MempoolTx>> mempool = {};
  final List<String> requested = [];

  @override
  Future<AddressStats> fetchAddress(String a) async {
    requested.add(a);
    return stats[a] ??
        const AddressStats(hasTransactions: false, balanceSats: 0);
  }

  @override
  Future<List<MempoolTx>> fetchMempoolTxs(String a) async => mempool[a] ?? [];

  @override
  Future<List<MempoolTx>> fetchRecentChainTxs(String a) async => const [];
}

/// In-memory secure storage whose deletes of [failKey] throw, as a keystore
/// error would.
class _DeleteFails extends TestFlutterSecureStoragePlatform {
  _DeleteFails(super.data, this.failKey);
  final String failKey;

  @override
  Future<void> delete({
    required String key,
    required Map<String, String> options,
  }) async {
    if (key == failKey) {
      throw PlatformException(code: 'keystore', message: 'secret detail');
    }
    return super.delete(key: key, options: options);
  }
}

/// Real prefs, except that removing [failKey] throws.
class _PrefsRemoveFails extends Fake implements SharedPreferences {
  _PrefsRemoveFails(this.real, this.failKey);
  final SharedPreferences real;
  final String failKey;

  @override
  bool? getBool(String key) => real.getBool(key);

  @override
  String? getString(String key) => real.getString(key);

  @override
  Object? get(String key) => real.get(key);

  @override
  bool containsKey(String key) => real.containsKey(key);

  @override
  Future<bool> setBool(String key, bool value) => real.setBool(key, value);

  @override
  Future<bool> remove(String key) async {
    if (key == failKey) {
      throw PlatformException(code: 'prefs', message: 'secret detail');
    }
    return real.remove(key);
  }
}

/// In-memory secure storage whose writes of the watch map throw, as a
/// keystore error would.
class _WatchMapWriteFails extends TestFlutterSecureStoragePlatform {
  _WatchMapWriteFails(super.data);

  @override
  Future<void> write({
    required String key,
    required String value,
    required Map<String, String> options,
  }) async {
    if (key == AppConstants.keySentinelWatchMap) {
      throw PlatformException(code: 'keystore', message: 'unavailable');
    }
    return super.write(key: key, value: value, options: options);
  }
}

class _ProUser extends ProUnlockedNotifier {
  @override
  bool build() => true;
}

class _FreeUser extends ProUnlockedNotifier {
  @override
  bool build() => false;
}

/// Records [scanAll] instead of scanning.
class _RecordingWallets extends WalletsNotifier {
  _RecordingWallets(this.calls);
  final List<String> calls;

  @override
  List<WalletEntry> build() => [WalletEntry(id: 'w', label: 'Cold')];

  @override
  Future<void> scanAll() async => calls.add('scanAll');
}

final _wallet = WalletEntry(id: 'w', label: 'Cold');

/// What an iOS scan of the empty-history test wallet should leave as its
/// watch entries: no UTXO addresses, the first 5 receive and change ones.
Map<String, SentinelWatchEntry> _expectedEntries() => sentinelWatchEntries(
  walletId: 'w',
  walletLabel: 'Cold',
  source: buildAddressSource(WalletKind.zpub, _zpub),
  balance: const WalletBalance(
    totalSats: 0,
    usedAddressCount: 0,
    lastExternalIndex: 0,
    lastChangeIndex: 0,
    nextExternalIndex: 0,
    nextChangeIndex: 0,
    utxoAddresses: [],
  ),
);

Map<String, Map<String, dynamic>> _asJson(
  Map<String, SentinelWatchEntry> m,
) => m.map((k, v) => MapEntry(k, v.toJson()));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<String> calls;

  setUp(() {
    calls = [];
    RouteGate.debugProbeOverride = (_) async => RouteStatus.available;
    SentinelService.debugIsAndroid = false;
    SentinelService.debugServiceCall = (c) => calls.add('service.$c');
    NotificationService.debugRequestPermission = () async {
      calls.add('permission');
      return true;
    };
    WidgetService.debugIosBackgroundFollows = () async =>
        calls.add('follows');
  });

  tearDown(() {
    RouteGate.debugProbeOverride = null;
    RouteGate.invalidateCache();
    SentinelService.debugIsAndroid = null;
    SentinelService.debugServiceCall = null;
    NotificationService.debugRequestPermission = null;
    WidgetService.debugIosBackgroundFollows = null;
  });

  Future<ProviderContainer> container({
    Map<String, Object> prefs = const {},
    Map<String, String> secure = const {},
    List<WalletEntry>? wallets,
    bool pro = true,
    List<Override> extra = const [],
    EsploraClient? esplora,
    SharedPreferences Function(SharedPreferences prefs)? wrapPrefs,
  }) async {
    FlutterSecureStorage.setMockInitialValues({
      'wallet_zpub_w': _zpub,
      ...secure,
    });
    SharedPreferences.setMockInitialValues(prefs);
    final p = await SharedPreferences.getInstance();
    final c = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(wrapPrefs?.call(p) ?? p),
        initialProxyConfigProvider.overrideWithValue(null),
        initialExplorerUrlProvider.overrideWithValue(''),
        initialWalletsProvider.overrideWithValue(wallets ?? [_wallet]),
        esploraClientProvider.overrideWithValue(esplora ?? _EmptyEsplora()),
        proUnlockedProvider.overrideWith(pro ? _ProUser.new : _FreeUser.new),
        ...extra,
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  group('watch map after a scan', () {
    test("an iOS scan with Sentinel on writes the wallet's watch entries",
        () async {
      final c = await container(
        prefs: {AppConstants.keySentinelEnabled: true},
      );

      await c.read(walletsProvider.notifier).scan('w');

      expect(c.read(walletsProvider).single.scanError, isNull);
      final map = await loadSentinelWatchMap();
      expect(map, isNotEmpty);
      expect(_asJson(map), _asJson(_expectedEntries()));
    });

    test('an iOS scan with Sentinel off writes no watch map', () async {
      final c = await container();

      await c.read(walletsProvider.notifier).scan('w');

      expect(c.read(walletsProvider).single.lastScanAt, isNotNull);
      expect(await readSecureBlob(AppConstants.keySentinelWatchMap), isNull);
    });

    test('an Android scan never writes the watch map', () async {
      SentinelService.debugIsAndroid = true;
      final c = await container(
        prefs: {AppConstants.keySentinelEnabled: true},
      );

      await c.read(walletsProvider.notifier).scan('w');

      expect(c.read(walletsProvider).single.lastScanAt, isNotNull);
      expect(await readSecureBlob(AppConstants.keySentinelWatchMap), isNull);
    });

    test("drops a removed wallet's entries and keeps the other wallets'",
        () async {
      const other = SentinelWatchEntry(walletId: 'w2', walletLabel: 'Hot');
      const gone = SentinelWatchEntry(walletId: 'gone', walletLabel: 'Old');
      final c = await container(
        prefs: {AppConstants.keySentinelEnabled: true},
        secure: {
          AppConstants.keySentinelWatchMap: jsonEncode({
            'bc1qother': other.toJson(),
            'bc1qgone': gone.toJson(),
          }),
        },
        wallets: [_wallet, WalletEntry(id: 'w2', label: 'Hot')],
      );

      await c.read(walletsProvider.notifier).scan('w');

      final map = await loadSentinelWatchMap();
      expect(map.containsKey('bc1qgone'), isFalse,
          reason: 'a wallet no longer stored is not watched');
      expect(map['bc1qother']?.walletId, 'w2');
      for (final addr in _expectedEntries().keys) {
        expect(map[addr]?.walletId, 'w');
      }
    });

    test('a scan of a wallet removed meanwhile writes none of its entries',
        () async {
      final esplora = _EmptyEsplora();
      final c = await container(
        prefs: {AppConstants.keySentinelEnabled: true},
        esplora: esplora,
      );
      final wallets = c.read(walletsProvider.notifier);
      var removed = false;
      esplora.onFirstRequest = () async {
        await wallets.removeWallet('w');
        removed = true;
      };

      await wallets.scan('w');

      expect(removed, isTrue);

      final map = await loadSentinelWatchMap();
      expect(map.values.where((e) => e.walletId == 'w'), isEmpty);
    });

    test('a wallet removed after its scan wrote the balance, before its '
        'watch entries are written, leaves none behind (R25)', () async {
      final c = await container(
        prefs: {AppConstants.keySentinelEnabled: true},
      );
      final wallets = c.read(walletsProvider.notifier);
      // Hold the watch-map queue so the scan's replacement waits in it.
      final hold = Completer<void>();
      final blocker = editSentinelWatchMap((_) => hold.future);

      final scan = wallets.scan('w');
      while (c.read(walletsProvider).single.lastScanAt == null) {
        await pumpEventQueue(times: 1);
      }
      // Balance written; the replacement is queued behind the blocker.
      final remove = wallets.removeWallet('w');
      await pumpEventQueue();
      hold.complete();
      await Future.wait([blocker, scan, remove]);

      final map = await loadSentinelWatchMap();
      expect(map.values.where((e) => e.walletId == 'w'), isEmpty);
    });

    test('a watch-map write that throws still leaves a successful scan',
        () async {
      final c = await container(
        prefs: {AppConstants.keySentinelEnabled: true},
      );
      FlutterSecureStoragePlatform.instance =
          _WatchMapWriteFails({'wallet_zpub_w': _zpub});

      await c.read(walletsProvider.notifier).scan('w');

      final w = c.read(walletsProvider).single;
      expect(w.scanError, isNull);
      expect(w.lastScanAt, isNotNull);
      expect(w.isScanning, isFalse);
    });
  });

  group('retired entries, through the real rescan (R31)', () {
    final source = buildAddressSource(WalletKind.zpub, _zpub);
    // Receive index 0: funded with 100 000, then spent.
    final a = source.addressAt(0, 0);
    // Change index 0: the spend's change.
    final c = source.addressAt(1, 0);
    const funded = AddressStats(
      hasTransactions: true,
      balanceSats: 100000,
      chainTxCount: 1,
    );
    const elsewhere = 'bc1qelsewhere';

    /// A background run as `_iosSentinelPart` makes it: the watch map as
    /// stored, checked by the engine.
    Future<IosSentinelResult> backgroundRun(
      _BackgroundExplorer explorer,
      IosSentinelState state, {
      Map<String, SentinelSeenTx> seen = const {},
    }) async => runIosSentinelCheck(
      explorer: explorer,
      watchMap: await loadSentinelWatchMap(),
      seen: seen,
      state: state,
      mayStart: () => true,
      stillOnRoute: () async => true,
      concurrency: 2,
    );

    /// Scan 1 (A holds the UTXO), then a background run that baselines
    /// every watched address.
    Future<
      ({
        WalletsNotifier wallets,
        _ScriptedEsplora esplora,
        IosSentinelResult run1,
      })
    >
    fundedAndBaselined() async {
      final esplora = _ScriptedEsplora()..stats[a] = funded;
      final ct = await container(
        prefs: {AppConstants.keySentinelEnabled: true},
        esplora: esplora,
      );
      final wallets = ct.read(walletsProvider.notifier);
      await wallets.scan('w');
      expect((await loadSentinelWatchMap()).keys, containsAll([a, c]));

      final explorer = _BackgroundExplorer()..stats[a] = funded;
      final run1 = await backgroundRun(explorer, IosSentinelState.empty);
      expect(run1.alerts, isEmpty);
      expect(run1.state.counts[a], (chain: 1, mempool: 0));
      expect(run1.state.counts[c], (chain: 0, mempool: 0));
      return (wallets: wallets, esplora: esplora, run1: run1);
    }

    test('a spend met through its change after the rescan dropped the '
        'input: one pending spend of 70 000, not incoming change', () async {
      final (:wallets, :esplora, :run1) = await fundedAndBaselined();

      // The user spends 70 000 from A, 30 000 change to C, and opens Bag.
      final spend = MempoolTx(
        txid: 'aaaaaaaa${'0' * 56}',
        inputs: [(address: a, sats: 100000)],
        outputs: [
          (address: c, sats: 30000),
          (address: elsewhere, sats: 69000),
        ],
      );
      esplora
        ..stats[a] = const AddressStats(
          hasTransactions: true,
          balanceSats: 0,
          chainTxCount: 1,
          mempoolTxCount: 1,
        )
        ..stats[c] = const AddressStats(
          hasTransactions: true,
          balanceSats: 30000,
          mempoolTxCount: 1,
        );
      await wallets.scan('w');

      final map = await loadSentinelWatchMap();
      expect(map[a]?.isRetired, isTrue,
          reason: 'the spent input stays watched, retired');
      expect(map[c]?.isRetired, isFalse);

      // Run 2 meets the spend through C only.
      final explorer = _BackgroundExplorer()
        ..stats[a] = funded
        ..stats[c] = const AddressStats(
          hasTransactions: true,
          balanceSats: 30000,
          mempoolTxCount: 1,
        )
        ..mempool[c] = [spend];
      final run2 = await backgroundRun(explorer, run1.state, seen: run1.seen);

      expect(run2.alerts.map((x) => (x.kind, x.sats)), [
        (SentinelAlertKind.pendingOut, 70000),
      ]);
    });

    test('a sweep with no change, after the rescan dropped its input, is '
        'alerted through the retired input', () async {
      final (:wallets, :esplora, :run1) = await fundedAndBaselined();

      final sweep = MempoolTx(
        txid: 'bbbbbbbb${'0' * 56}',
        inputs: [(address: a, sats: 100000)],
        outputs: [(address: elsewhere, sats: 99000)],
      );
      const swept = AddressStats(
        hasTransactions: true,
        balanceSats: 0,
        chainTxCount: 1,
        mempoolTxCount: 1,
      );
      esplora.stats[a] = swept;
      await wallets.scan('w');
      expect((await loadSentinelWatchMap())[a]?.isRetired, isTrue);

      final explorer = _BackgroundExplorer()
        ..stats[a] = swept
        ..mempool[a] = [sweep];
      final run2 = await backgroundRun(explorer, run1.state, seen: run1.seen);

      expect(explorer.requested, contains(a));
      expect(run2.alerts.map((x) => (x.kind, x.sats)), [
        (SentinelAlertKind.pendingOut, 100000),
      ]);
    });

    test('a rescan that finds a UTXO on the retired address again makes it '
        'live', () async {
      final (:wallets, :esplora, run1: _) = await fundedAndBaselined();
      esplora.stats[a] = const AddressStats(
        hasTransactions: true,
        balanceSats: 0,
        chainTxCount: 2,
      );
      await wallets.scan('w');
      expect((await loadSentinelWatchMap())[a]?.isRetired, isTrue);

      esplora.stats[a] = const AddressStats(
        hasTransactions: true,
        balanceSats: 5000,
        chainTxCount: 3,
      );
      await wallets.scan('w');

      final raw = jsonDecode(
        (await readSecureBlob(AppConstants.keySentinelWatchMap))!,
      ) as Map<String, dynamic>;
      expect(raw[a], {'wid': 'w', 'wlabel': 'Cold'});
    });

    test("removing the wallet drops its retired entries with its live ones",
        () async {
      final (:wallets, :esplora, run1: _) = await fundedAndBaselined();
      esplora.stats[a] = const AddressStats(
        hasTransactions: true,
        balanceSats: 0,
        chainTxCount: 2,
      );
      await wallets.scan('w');
      expect((await loadSentinelWatchMap())[a]?.isRetired, isTrue);

      await wallets.removeWallet('w');

      expect(await loadSentinelWatchMap(), isEmpty);
    });

    test("a rescan drops the retired entries of a wallet no longer stored, "
        'and those retired more than 30 days ago', () async {
      final now = DateTime.now();
      final recent = now.subtract(const Duration(days: 29));
      final c0 = await container(
        prefs: {AppConstants.keySentinelEnabled: true},
        secure: {
          AppConstants.keySentinelWatchMap: jsonEncode({
            'bc1qgone': SentinelWatchEntry(
              walletId: 'gone',
              walletLabel: 'Old',
              retiredAt: now.subtract(const Duration(days: 1)),
            ).toJson(),
            'bc1qexpired': SentinelWatchEntry(
              walletId: 'w',
              walletLabel: 'Cold',
              retiredAt: now.subtract(const Duration(days: 31)),
            ).toJson(),
            'bc1qrecent': SentinelWatchEntry(
              walletId: 'w',
              walletLabel: 'Cold',
              retiredAt: recent,
            ).toJson(),
          }),
        },
      );

      await c0.read(walletsProvider.notifier).scan('w');

      final map = await loadSentinelWatchMap();
      expect(map.containsKey('bc1qgone'), isFalse);
      expect(map.containsKey('bc1qexpired'), isFalse);
      expect(map['bc1qrecent']!.retiredAt!.isAtSameMomentAs(recent), isTrue);
    });
  });

  group('nothing left to watch (R35)', () {
    final manual = WalletEntry(
      id: 'm',
      label: 'Exchange',
      kind: WalletKind.manual,
      lastSats: 1000,
    );

    setUp(() {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const widgetChannel = MethodChannel('home_widget');
      messenger.setMockMethodCallHandler(widgetChannel, (_) async => true);
      addTearDown(
        () => messenger.setMockMethodCallHandler(widgetChannel, null),
      );
    });

    test('on iOS, removing the last watch-only wallet with a typed-in '
        'balance left turns Sentinel Lite off', () async {
      final c = await container(
        prefs: {
          AppConstants.keySentinelEnabled: true,
          AppConstants.keyProUnlocked: true,
        },
        wallets: [_wallet, manual],
      );
      expect(c.read(sentinelProvider), isA<SentinelEnabled>());

      await c.read(walletsProvider.notifier).removeWallet('w');
      await pumpEventQueue();

      expect(c.read(sentinelProvider), isA<SentinelDisabled>());
      final p = c.read(sharedPreferencesProvider);
      expect(p.getBool(AppConstants.keySentinelEnabled), isFalse);
      expect(calls, contains('follows'));
    });

    test('on iOS, a watch-only wallet left keeps it on', () async {
      final c = await container(
        prefs: {
          AppConstants.keySentinelEnabled: true,
          AppConstants.keyProUnlocked: true,
        },
        secure: {'wallet_zpub_w2': _zpub},
        wallets: [_wallet, WalletEntry(id: 'w2', label: 'Hot'), manual],
      );
      expect(c.read(sentinelProvider), isA<SentinelEnabled>());

      await c.read(walletsProvider.notifier).removeWallet('w');
      await pumpEventQueue();

      expect(c.read(sentinelProvider), isA<SentinelEnabled>());
    });

    test('on Android, a typed-in balance left keeps Sentinel on, as before',
        () async {
      SentinelService.debugIsAndroid = true;
      final c = await container(
        prefs: {
          AppConstants.keySentinelEnabled: true,
          AppConstants.keyProUnlocked: true,
        },
        wallets: [_wallet, manual],
      );
      expect(c.read(sentinelProvider), isA<SentinelEnabled>());

      await c.read(walletsProvider.notifier).removeWallet('w');
      await pumpEventQueue();

      expect(c.read(sentinelProvider), isA<SentinelEnabled>());
      expect(calls, isNot(contains('service.stop')));
    });
  });

  group('enable and disable on iOS', () {
    test('enabling on iOS asks permission, scans and schedules', () async {
      final c = await container(
        prefs: {AppConstants.keyProUnlocked: true},
        extra: [walletsProvider.overrideWith(() => _RecordingWallets(calls))],
      );
      WidgetService.debugIosBackgroundFollows = () async {
        final on = c
            .read(sharedPreferencesProvider)
            .getBool(AppConstants.keySentinelEnabled);
        if (on == true) calls.add('flag set');
        calls.add('follows');
      };

      await c.read(sentinelProvider.notifier).enable();
      await pumpEventQueue();

      expect(calls, containsAll(['permission', 'scanAll', 'follows']));
      expect(calls.indexOf('flag set'), lessThan(calls.indexOf('follows')),
          reason: 'the schedule reads the flag');
      expect(calls.indexOf('permission'), lessThan(calls.indexOf('follows')));
      expect(calls.where((x) => x.startsWith('service.')), isEmpty,
          reason: 'no foreground service on iOS');
      final p = c.read(sharedPreferencesProvider);
      expect(p.getBool(AppConstants.keySentinelEnabled), isTrue);
      expect(c.read(sentinelProvider), isA<SentinelEnabled>());
    });

    test('enabling on iOS deletes stale activity counts first', () async {
      final c = await container(
        prefs: {AppConstants.keyProUnlocked: true},
        secure: {AppConstants.keySentinelIosActivity: '{"bc1q":{}}'},
        extra: [walletsProvider.overrideWith(() => _RecordingWallets(calls))],
      );

      await c.read(sentinelProvider.notifier).enable();

      expect(
        await readSecureBlob(AppConstants.keySentinelIosActivity),
        isNull,
      );
    });

    test('enabling on iOS deletes the last check time of an earlier run too '
        '(R34)', () async {
      final c = await container(
        prefs: {
          AppConstants.keyProUnlocked: true,
          AppConstants.keySentinelLastScan: '2026-11-01T10:00:00.000',
        },
        extra: [walletsProvider.overrideWith(() => _RecordingWallets(calls))],
      );

      await c.read(sentinelProvider.notifier).enable();

      final p = c.read(sharedPreferencesProvider);
      expect(p.containsKey(AppConstants.keySentinelLastScan), isFalse);
      final state = c.read(sentinelProvider);
      expect(state, isA<SentinelEnabled>());
      expect((state as SentinelEnabled).lastScanAt, isNull);
    });

    for (final (what, failing) in [
      ('the activity counts', 'secure'),
      ('the last check time', 'prefs'),
    ]) {
      test('a delete of $what that throws leaves Sentinel Lite off: enable '
          'returns, only the type is logged, nothing scheduled or scanned '
          '(R34)', () async {
        final logs = <String>[];
        final print = debugPrint;
        debugPrint = (String? m, {int? wrapWidth}) => logs.add(m ?? '');
        addTearDown(() => debugPrint = print);
        final c = await container(
          prefs: {
            AppConstants.keyProUnlocked: true,
            AppConstants.keySentinelLastScan: '2026-11-01T10:00:00.000',
          },
          secure: {AppConstants.keySentinelIosActivity: '{"bc1q":{}}'},
          extra: [
            walletsProvider.overrideWith(() => _RecordingWallets(calls)),
          ],
          wrapPrefs: failing == 'prefs'
              ? (p) => _PrefsRemoveFails(p, AppConstants.keySentinelLastScan)
              : null,
        );
        if (failing == 'secure') {
          FlutterSecureStoragePlatform.instance = _DeleteFails({
            'wallet_zpub_w': _zpub,
            AppConstants.keySentinelIosActivity: '{"bc1q":{}}',
          }, AppConstants.keySentinelIosActivity);
        }

        await expectLater(
          c.read(sentinelProvider.notifier).enable(),
          completes,
        );

        expect(c.read(sentinelProvider), isA<SentinelDisabled>());
        final p = c.read(sharedPreferencesProvider);
        expect(p.getBool(AppConstants.keySentinelEnabled), isNot(isTrue));
        expect(calls, isNot(contains('follows')));
        expect(calls, isNot(contains('scanAll')));
        expect(logs.where((l) => l.contains('PlatformException')), isNotEmpty);
        expect(logs.join('\n'), isNot(contains('secret detail')));
      });
    }

    test('a permission request that throws does not stop enabling', () async {
      NotificationService.debugRequestPermission = () async =>
          throw PlatformException(code: 'denied');
      final c = await container(
        prefs: {AppConstants.keyProUnlocked: true},
        extra: [walletsProvider.overrideWith(() => _RecordingWallets(calls))],
      );

      await c.read(sentinelProvider.notifier).enable();
      await pumpEventQueue();

      expect(c.read(sentinelProvider), isA<SentinelEnabled>());
      expect(calls, containsAll(['scanAll', 'follows']));
    });

    test('enabling without Pro does nothing', () async {
      final c = await container(
        pro: false,
        extra: [walletsProvider.overrideWith(() => _RecordingWallets(calls))],
      );

      await c.read(sentinelProvider.notifier).enable();
      await pumpEventQueue();

      expect(calls, isEmpty);
      final p = c.read(sharedPreferencesProvider);
      expect(p.getBool(AppConstants.keySentinelEnabled), isNull);
      expect(c.read(sentinelProvider), isA<SentinelDisabled>());
    });

    test('disabling on iOS deletes the activity blob and reschedules',
        () async {
      final c = await container(
        pro: false, // R-B2g: a free user can always switch it off
        prefs: {AppConstants.keySentinelEnabled: true},
        secure: {AppConstants.keySentinelIosActivity: '{"bc1q":{}}'},
        extra: [walletsProvider.overrideWith(() => _RecordingWallets(calls))],
      );
      expect(c.read(sentinelProvider), isA<SentinelEnabled>());
      // The widget's Sentinel Lite status (Task 7, R24).
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const widgetChannel = MethodChannel('home_widget');
      messenger.setMockMethodCallHandler(widgetChannel, (call) async {
        final args = call.arguments is Map ? call.arguments as Map : const {};
        // Writes and redraws only; a read elsewhere answers nothing.
        switch (call.method) {
          case 'saveWidgetData':
            calls.add('widget.save:${args['id']}=${args['data']}');
          case 'updateWidget':
            calls.add('widget.reload');
          case 'getWidgetData':
            return null;
        }
        return true;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(widgetChannel, null),
      );

      await c.read(sentinelProvider.notifier).disable();

      expect(calls.toSet(), {
        'widget.save:${AppConstants.keyWidgetSentinelOk}=null',
        'widget.save:${AppConstants.keyWidgetSentinelCheckedAt}=null',
        'widget.reload',
        'follows',
      });
      expect(calls.where((c) => c == 'widget.reload'), hasLength(1));
      expect(calls.last, 'follows');
      expect(
        await readSecureBlob(AppConstants.keySentinelIosActivity),
        isNull,
      );
      final p = c.read(sharedPreferencesProvider);
      expect(p.getBool(AppConstants.keySentinelEnabled), isFalse);
      expect(c.read(sentinelProvider), isA<SentinelDisabled>());
    });

    test('Android enable and disable still use the foreground service',
        () async {
      SentinelService.debugIsAndroid = true;
      final c = await container(
        prefs: {AppConstants.keyProUnlocked: true},
        extra: [walletsProvider.overrideWith(() => _RecordingWallets(calls))],
      );

      await c.read(sentinelProvider.notifier).enable();
      await c.read(sentinelProvider.notifier).disable();
      await pumpEventQueue();

      expect(calls, ['service.start', 'service.stop']);
    });
  });
}
