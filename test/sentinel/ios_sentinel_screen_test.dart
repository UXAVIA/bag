/// Sentinel Lite's screen on iPhone (spec D8, D9): its own title, honest copy
/// about iOS deciding when it runs, the enable tile with no Android
/// disclosure, and status lines that name what stops the background checks
/// (notifications off, Background App Refresh off, Low Power Mode on). Those
/// come from the `app.bitbag/background` channel, answered in Swift by
/// `ios/Runner/AppDelegate.swift`, pinned here by its source shape.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bag/core/theme/app_theme.dart';
import 'package:bag/features/settings/presentation/pro_upgrade_sheet.dart';
import 'package:bag/features/settings/presentation/sentinel_screen.dart';
import 'package:bag/models/wallet_entry.dart';
import 'package:bag/providers/purchase_provider.dart';
import 'package:bag/providers/sentinel_provider.dart';
import 'package:bag/providers/shared_preferences_provider.dart';
import 'package:bag/providers/wallets_provider.dart';
import 'package:bag/services/background_status.dart';
import 'package:bag/services/notification_service.dart';
import 'package:bag/services/sentinel_service.dart';

const _firstLine =
    'Checks when iOS lets Bag run, not continuously like Sentinel on Android.';
const _intro =
    'Bag checks your wallets for new transactions in the background and '
    'alerts you. iOS decides when Bag may run, usually every 15 minutes to a '
    'few hours, so alerts can be late. Checks stop in Low Power Mode, with '
    'Background App Refresh off, or after you swipe Bag away, until you open '
    'it again.';
const _bullets = [
  'Alerts for incoming and outgoing transactions, pending and confirmed',
  'Checks through your connection setting: Tor, your proxy or direct',
  'Nothing is sent to a Bag server',
  'Not real-time: iOS decides when it runs',
];
const _notificationsOff =
    'Notifications are off for Bag. Turn them on in Settings.';
const _refreshOff =
    'Background App Refresh is off for Bag. Turn it on in Settings › General '
    '› Background App Refresh.';
const _lowPower = 'Low Power Mode is on, so iOS pauses background checks.';

final _watchOnly = WalletEntry(id: 'w1', label: 'Coldcard', lastSats: 1000);
final _typedIn = WalletEntry(
  id: 'm1',
  label: 'Kraken',
  kind: WalletKind.manual,
  lastSats: 5000,
);

class _FixedPro extends ProUnlockedNotifier {
  _FixedPro(this._value);
  final bool _value;

  @override
  bool build() => _value;
}

class _FixedWallets extends WalletsNotifier {
  _FixedWallets(this._wallets);
  final List<WalletEntry> _wallets;

  @override
  List<WalletEntry> build() => _wallets;
}

class _RecordingSentinel extends SentinelNotifier {
  _RecordingSentinel(this._initial, this.calls);
  final SentinelState _initial;
  final List<String> calls;

  @override
  SentinelState build() => _initial;
  @override
  Future<void> enable() async => calls.add('enable');
  @override
  Future<void> disable() async => calls.add('disable');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const channel = MethodChannel(BackgroundStatus.channelName);

  /// What the channel answers; a method that throws answers with an error.
  late Map<String, Object?> answers;
  late List<String> channelCalls;
  late NotificationAccess notificationAccess;

  setUp(() {
    SentinelService.debugIsAndroid = false;
    answers = {
      BackgroundStatus.methodRefreshStatus: 'available',
      BackgroundStatus.methodLowPowerMode: false,
    };
    channelCalls = [];
    notificationAccess = NotificationAccess.allowed;
    NotificationService.debugNotificationAccess = () async =>
        notificationAccess;
    messenger.setMockMethodCallHandler(channel, (call) async {
      channelCalls.add(call.method);
      final answer = answers[call.method];
      if (answer is Exception) throw answer;
      return answer;
    });
  });

  tearDown(() {
    SentinelService.debugIsAndroid = null;
    NotificationService.debugNotificationAccess = null;
    messenger.setMockMethodCallHandler(channel, null);
  });

  Future<List<String>> pumpScreen(
    WidgetTester tester, {
    SentinelState state = const SentinelEnabled(),
    List<WalletEntry>? wallets,
    bool pro = true,
  }) async {
    tester.view.physicalSize = const Size(1100, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final calls = <String>[];
    // A test may pump twice: start from an empty tree so the screen reads
    // its status again and the new overrides apply.
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          proUnlockedProvider.overrideWith(() => _FixedPro(pro)),
          walletsProvider.overrideWith(
            () => _FixedWallets(wallets ?? [_watchOnly]),
          ),
          sentinelProvider.overrideWith(() => _RecordingSentinel(state, calls)),
        ],
        child: MaterialApp(theme: AppTheme.dark, home: const SentinelScreen()),
      ),
    );
    await tester.pumpAndSettle();
    return calls;
  }

  Finder appBarTitle(String title) =>
      find.descendant(of: find.byType(AppBar), matching: find.text(title));

  group('copy (spec D9)', () {
    testWidgets('titled Sentinel Lite, with the first line, intro and '
        'bullets', (tester) async {
      await pumpScreen(tester);

      expect(appBarTitle('Sentinel Lite'), findsOneWidget);
      expect(appBarTitle('Sentinel'), findsNothing);
      for (final text in [_firstLine, _intro, ..._bullets]) {
        expect(find.text(text), findsOneWidget, reason: text);
      }
      expect(find.text('Enable Sentinel Lite'), findsOneWidget);
    });

    testWidgets('the first line comes before the intro', (tester) async {
      await pumpScreen(tester);

      expect(
        tester.getTopLeft(find.text(_firstLine)).dy,
        lessThan(tester.getTopLeft(find.text(_intro)).dy),
      );
    });

    testWidgets('nothing of the Android screen is left', (tester) async {
      await pumpScreen(tester);

      for (final old in [
        'Android requires',
        'persistent notification',
        'battery optimisation',
        'Always-on',
        'Restarts automatically',
        'Scans every',
      ]) {
        expect(find.textContaining(old), findsNothing, reason: old);
      }
    });
  });

  group('enable tile', () {
    testWidgets('"Connect a wallet first" with no watch-only wallet', (
      tester,
    ) async {
      await pumpScreen(
        tester,
        state: const SentinelDisabled(),
        wallets: [_typedIn],
      );

      expect(find.text('Connect a wallet first'), findsOneWidget);
      final tile = tester.widget<SwitchListTile>(find.byType(SwitchListTile));
      expect(tile.onChanged, isNull);
    });

    testWidgets('off: "Check in the background"; on: "Tap to stop checking"', (
      tester,
    ) async {
      await pumpScreen(tester, state: const SentinelDisabled());
      expect(find.text('Check in the background'), findsOneWidget);

      await pumpScreen(tester);
      expect(find.text('Tap to stop checking'), findsOneWidget);
    });

    testWidgets('Pro: enabling needs no disclosure', (tester) async {
      final calls = await pumpScreen(tester, state: const SentinelDisabled());

      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();

      expect(calls, ['enable']);
      expect(find.text('Enable Sentinel?'), findsNothing);
      expect(find.byType(BottomSheet), findsNothing);
    });

    testWidgets('free: enabling opens the Pro sheet, nothing runs', (
      tester,
    ) async {
      final calls = await pumpScreen(
        tester,
        state: const SentinelDisabled(),
        pro: false,
      );

      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();

      expect(find.byKey(proUpgradeSheetKey), findsOneWidget);
      expect(calls, isEmpty);
    });

    testWidgets('free: switching off is always allowed (R-B2g)', (
      tester,
    ) async {
      final calls = await pumpScreen(tester, pro: false);

      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();

      expect(calls, ['disable']);
      expect(find.byKey(proUpgradeSheetKey), findsNothing);
    });
  });

  group('status lines', () {
    testWidgets('"Not checked yet" without a last scan', (tester) async {
      await pumpScreen(tester);

      expect(find.text('Not checked yet'), findsOneWidget);
      expect(find.textContaining('Last checked'), findsNothing);
    });

    testWidgets('"Last checked HH:mm" today', (tester) async {
      final now = DateTime.now();
      await pumpScreen(
        tester,
        state: SentinelEnabled(
          lastScanAt: DateTime(now.year, now.month, now.day, 9, 5),
        ),
      );

      expect(find.text('Last checked 09:05'), findsOneWidget);
      expect(find.text('Not checked yet'), findsNothing);
    });

    testWidgets('"Last checked d MMM" on another day', (tester) async {
      await pumpScreen(
        tester,
        state: SentinelEnabled(lastScanAt: DateTime(2026, 3, 2, 12, 2)),
      );

      expect(find.text('Last checked 2 Mar'), findsOneWidget);
    });

    testWidgets('no warning while everything allows the checks', (
      tester,
    ) async {
      await pumpScreen(tester);

      for (final line in [_notificationsOff, _refreshOff, _lowPower]) {
        expect(find.text(line), findsNothing, reason: line);
      }
      expect(
        channelCalls,
        containsAll([
          BackgroundStatus.methodRefreshStatus,
          BackgroundStatus.methodLowPowerMode,
        ]),
      );
    });

    testWidgets('Background App Refresh line only when the channel says '
        'denied', (tester) async {
      for (final status in ['available', 'restricted']) {
        answers[BackgroundStatus.methodRefreshStatus] = status;
        await pumpScreen(tester);
        expect(find.text(_refreshOff), findsNothing, reason: status);
      }

      answers[BackgroundStatus.methodRefreshStatus] = 'denied';
      await pumpScreen(tester);
      expect(find.text(_refreshOff), findsOneWidget);
    });

    testWidgets('Low Power line only when lowPowerMode is true', (
      tester,
    ) async {
      await pumpScreen(tester);
      expect(find.text(_lowPower), findsNothing);

      answers[BackgroundStatus.methodLowPowerMode] = true;
      await pumpScreen(tester);
      expect(find.text(_lowPower), findsOneWidget);
    });

    testWidgets('notifications line only when notifications are off', (
      tester,
    ) async {
      await pumpScreen(tester);
      expect(find.text(_notificationsOff), findsNothing);

      notificationAccess = NotificationAccess.off;
      await pumpScreen(tester);
      expect(find.text(_notificationsOff), findsOneWidget);
    });

    testWidgets('notifications that can\'t be read show no warning', (
      tester,
    ) async {
      notificationAccess = NotificationAccess.unknown;
      await pumpScreen(tester);
      expect(find.text(_notificationsOff), findsNothing);
    });

    test('a permission read that throws is unknown, not off', () async {
      NotificationService.debugNotificationAccess = () async =>
          throw PlatformException(code: 'x');
      expect(
        await NotificationService.notificationAccess(),
        NotificationAccess.unknown,
      );
    });

    testWidgets('a channel error shows no warning', (tester) async {
      answers[BackgroundStatus.methodRefreshStatus] = PlatformException(
        code: 'x',
      );
      answers[BackgroundStatus.methodLowPowerMode] = PlatformException(
        code: 'x',
      );
      await pumpScreen(tester);

      expect(find.text(_refreshOff), findsNothing);
      expect(find.text(_lowPower), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('no status lines while Sentinel Lite is off', (tester) async {
      answers[BackgroundStatus.methodRefreshStatus] = 'denied';
      answers[BackgroundStatus.methodLowPowerMode] = true;
      notificationAccess = NotificationAccess.off;
      await pumpScreen(tester, state: const SentinelDisabled());

      for (final line in [
        'Not checked yet',
        _notificationsOff,
        _refreshOff,
        _lowPower,
      ]) {
        expect(find.text(line), findsNothing, reason: line);
      }
    });
  });

  group('BackgroundStatus', () {
    test('maps the three answers, anything else is unknown', () async {
      for (final (answer, expected) in [
        ('available', BackgroundRefresh.available),
        ('denied', BackgroundRefresh.denied),
        ('restricted', BackgroundRefresh.restricted),
        ('other', BackgroundRefresh.unknown),
        (null, BackgroundRefresh.unknown),
      ]) {
        answers[BackgroundStatus.methodRefreshStatus] = answer;
        expect(await BackgroundStatus.refresh(), expected, reason: '$answer');
      }
    });

    test('an error is unknown / false', () async {
      answers[BackgroundStatus.methodRefreshStatus] = PlatformException(
        code: 'x',
      );
      answers[BackgroundStatus.methodLowPowerMode] = PlatformException(
        code: 'x',
      );
      expect(await BackgroundStatus.refresh(), BackgroundRefresh.unknown);
      expect(await BackgroundStatus.lowPowerMode(), isFalse);
    });

    test('a missing handler is unknown / false', () async {
      messenger.setMockMethodCallHandler(channel, null);
      expect(await BackgroundStatus.refresh(), BackgroundRefresh.unknown);
      expect(await BackgroundStatus.lowPowerMode(), isFalse);
    });

    test('lowPowerMode reads the bool', () async {
      answers[BackgroundStatus.methodLowPowerMode] = true;
      expect(await BackgroundStatus.lowPowerMode(), isTrue);
    });

    test('Android: available / false without a call', () async {
      SentinelService.debugIsAndroid = true;
      answers[BackgroundStatus.methodRefreshStatus] = 'denied';
      answers[BackgroundStatus.methodLowPowerMode] = true;

      expect(await BackgroundStatus.refresh(), BackgroundRefresh.available);
      expect(await BackgroundStatus.lowPowerMode(), isFalse);
      expect(channelCalls, isEmpty);
    });
  });

  group('native channel (skipped without ios/, as in the public snapshot)', () {
    final delegate = File('ios/Runner/AppDelegate.swift');
    final skip = delegate.existsSync() ? null : 'ios/ is absent';

    test('AppDelegate registers app.bitbag/background with both methods', () {
      final src = delegate.readAsStringSync();
      final start = src.indexOf('func didInitializeImplicitFlutterEngine');
      expect(start, greaterThan(-1));
      final body = src.substring(start);

      expect(body, contains('name: "${BackgroundStatus.channelName}"'));
      expect(body, contains('case "${BackgroundStatus.methodRefreshStatus}"'));
      expect(body, contains('case "${BackgroundStatus.methodLowPowerMode}"'));
      expect(body, contains('backgroundRefreshStatus'));
      expect(body, contains('isLowPowerModeEnabled'));
      for (final answer in ['"available"', '"denied"', '"restricted"']) {
        expect(body, contains(answer), reason: answer);
      }
      // UIApplication is read on the main thread.
      expect(body, contains('DispatchQueue.main'));
      expect(body, contains('FlutterMethodNotImplemented'));
    }, skip: skip);

    test(
      'the background channel isn\'t behind the widget channel\'s guard',
      () {
        // The widget stubs `return` when their registrar is missing; the
        // background channel must not depend on that registrar.
        final src = delegate.readAsStringSync();
        expect(src, contains('forPlugin: "BagBackgroundStatus"'));
        final channel = src.indexOf('"${BackgroundStatus.channelName}"');
        final guard = src.indexOf('guard let registrar');
        expect(channel, greaterThan(-1));
        expect(guard, greaterThan(-1));
        expect(channel, lessThan(guard),
            reason: 'the background channel sits behind the widget guard');
      },
      skip: skip,
    );
  });
}
