/// The About section's licence-key row: always in the direct flavor, in the
/// store flavor only while a verified key is stored.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bag/core/theme/app_theme.dart';
import 'package:bag/features/settings/presentation/settings_screen.dart';
import 'package:bag/providers/purchase_provider.dart';
import 'package:bag/providers/shared_preferences_provider.dart';

class _Pro extends ProUnlockedNotifier {
  @override
  bool build() => true;
}

void main() {
  tearDown(() => ProUnlockedNotifier.debugFlavor = null);

  Future<void> show(WidgetTester tester, {required bool stored}) async {
    tester.view.physicalSize = const Size(390, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          proUnlockedProvider.overrideWith(_Pro.new),
          licenceKeyStoredProvider.overrideWith((ref) async => stored),
        ],
        child: MaterialApp(
          theme: AppTheme.dark,
          home: const SettingsScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  final viewer = find.text('License Key');

  testWidgets('store flavor: no viewer without a stored key', (tester) async {
    ProUnlockedNotifier.debugFlavor = 'store';
    await show(tester, stored: false);
    expect(find.text('Source Code'), findsOneWidget);
    expect(viewer, findsNothing);
  });

  testWidgets('store flavor: the viewer shows with a stored key', (
    tester,
  ) async {
    ProUnlockedNotifier.debugFlavor = 'store';
    await show(tester, stored: true);
    expect(viewer, findsOneWidget);
  });

  testWidgets('direct flavor: the viewer shows whatever is stored', (
    tester,
  ) async {
    ProUnlockedNotifier.debugFlavor = 'direct';
    await show(tester, stored: false);
    expect(viewer, findsOneWidget);
  });
}
