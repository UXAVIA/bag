/// M-15: an xpub, descriptor or licence key on screen never reaches the
/// app-switcher snapshot.
///
/// - Android: FLAG_SECURE (`setSecureMode`) is on for the dialog's lifetime
///   and is turned off in `finally`, even if the dialog throws.
/// - iOS, where `setSecureMode` does nothing: while a secret is shown,
///   `inactive` (when iOS takes the snapshot) covers the whole app, dialog
///   included, with the opaque privacy overlay of `MaterialApp.builder`.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bag/app.dart';
import 'package:bag/core/constants/app_constants.dart';
import 'package:bag/core/utils/secret_on_screen.dart';
import 'package:bag/mock/mock_providers.dart';
import 'package:bag/mock/scenes.dart';

const _secret = 'zpub-top-secret-value';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final secureModeCalls = <bool>[];

  setUp(() {
    secureModeCalls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('app.bitbag/widget'), (
          call,
        ) async {
          if (call.method == 'setSecureMode') {
            secureModeCalls.add((call.arguments as Map)['secure'] as bool);
          }
          return null;
        });
  });

  tearDown(() {
    SecretOnScreen.debugReset();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('app.bitbag/widget'),
          null,
        );
  });

  group('SecretOnScreen.guard', () {
    test('secure mode on for the dialog, off afterwards; the flag follows',
        () async {
      final seen = <bool>[];
      final result = await SecretOnScreen.guard(() async {
        seen.add(SecretOnScreen.isShown.value);
        return 42;
      });
      expect(result, 42);
      expect(seen, [true]);
      expect(SecretOnScreen.isShown.value, isFalse);
      expect(secureModeCalls, [true, false]);
    });

    test('a dialog that throws still clears the flag and secure mode',
        () async {
      await expectLater(
        SecretOnScreen.guard<void>(() async => throw StateError('boom')),
        throwsStateError,
      );
      expect(SecretOnScreen.isShown.value, isFalse);
      expect(secureModeCalls, [true, false]);
    });
  });

  group('the iOS cover', () {
    Future<void> pumpApp(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1100, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({
        AppConstants.keyOnboardingComplete: true,
      });
      final prefs = await SharedPreferences.getInstance();
      await tester.pumpWidget(
        ProviderScope(
          overrides: overridesForScene(ScreenshotScene.dcaTracker, prefs: prefs),
          child: const BagApp(onboardingComplete: true, initialLocation: '/'),
        ),
      );
      await tester.pumpAndSettle(const Duration(seconds: 3));
    }

    /// Opens a secret dialog the way `_showSecret` / `_viewKey` do, and
    /// returns the future that completes when it closes.
    Future<void> showSecret(WidgetTester tester) {
      final context = tester.element(find.byType(Scaffold).first);
      final closed = SecretOnScreen.guard(
        () => showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            content: const Text(_secret),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Close'),
              ),
            ],
          ),
        ),
      );
      return closed;
    }

    void lifecycle(WidgetTester tester, AppLifecycleState state) =>
        tester.binding.handleAppLifecycleStateChanged(state);

    final cover = find.byKey(privacyOverlayKey);

    testWidgets('inactive with a secret on screen: an opaque cover over '
        'everything, dialog included; resumed takes it away', (tester) async {
      await pumpApp(tester);
      final closed = showSecret(tester);
      await tester.pumpAndSettle();
      expect(find.text(_secret).hitTestable(), findsOneWidget);

      lifecycle(tester, AppLifecycleState.inactive);
      await tester.pump();
      expect(cover, findsOneWidget);
      final box = tester.widget<ColoredBox>(
        find.descendant(of: cover, matching: find.byType(ColoredBox)),
      );
      expect(box.color.a, 1.0, reason: 'the cover must be opaque');
      // Nothing under the cover can be hit, so nothing under it shows.
      expect(find.text(_secret).hitTestable(), findsNothing);

      lifecycle(tester, AppLifecycleState.hidden);
      lifecycle(tester, AppLifecycleState.paused);
      await tester.pump();
      expect(cover, findsOneWidget);

      lifecycle(tester, AppLifecycleState.hidden);
      lifecycle(tester, AppLifecycleState.inactive);
      lifecycle(tester, AppLifecycleState.resumed);
      await tester.pump();
      expect(cover, findsNothing);
      expect(find.text(_secret).hitTestable(), findsOneWidget);

      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      await closed;
      expect(SecretOnScreen.isShown.value, isFalse);
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

    testWidgets('no secret on screen, no app lock: inactive covers nothing',
        (tester) async {
      await pumpApp(tester);
      final closed = showSecret(tester);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      await closed;

      lifecycle(tester, AppLifecycleState.inactive);
      await tester.pump();
      expect(cover, findsNothing);
      lifecycle(tester, AppLifecycleState.resumed);
      await tester.pump();
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

    testWidgets('Android relies on FLAG_SECURE: inactive (the notification '
        'shade) does not blank the app', (tester) async {
      await pumpApp(tester);
      final closed = showSecret(tester);
      await tester.pumpAndSettle();
      expect(secureModeCalls, [true]);

      lifecycle(tester, AppLifecycleState.inactive);
      await tester.pump();
      expect(cover, findsNothing);

      lifecycle(tester, AppLifecycleState.resumed);
      await tester.pump();
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      await closed;
      expect(secureModeCalls, [true, false]);
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));
  });

  test('every secret dialog goes through the guard', () {
    final libFiles = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'));
    final direct = [
      for (final f in libFiles)
        if (f.readAsStringSync().contains("'setSecureMode'") &&
            !f.path.endsWith('secret_on_screen.dart'))
          f.path,
    ];
    expect(direct, isEmpty, reason: 'call SecretOnScreen.guard instead');

    for (final (path, fn) in [
      ('lib/features/wallets/presentation/wallets_screen.dart', '_showSecret'),
      ('lib/features/settings/presentation/settings_screen.dart', '_viewKey'),
    ]) {
      final src = File(path).readAsStringSync();
      final start = src.indexOf('Future<void> $fn(');
      expect(start, greaterThan(0), reason: path);
      final body = src.substring(start, src.indexOf('\n  }\n', start));
      final guard = body.indexOf('SecretOnScreen.guard(');
      expect(guard, greaterThan(0), reason: '$fn uses the guard');
      expect(body.indexOf('showDialog'), greaterThan(guard),
          reason: '$fn shows the dialog inside the guard');
    }
  });
}
