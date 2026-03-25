import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app.dart';
import 'core/constants/app_constants.dart';
import 'providers/shared_preferences_provider.dart';
import 'services/notification_service.dart';
import 'services/price_service.dart';
import 'services/sentinel_service.dart';
import 'services/widget_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await WidgetService.initialise();
  await WidgetService.scheduleRefresh();
  if (Platform.isAndroid) {
    SentinelService.initialise(); // register config before restoreIfEnabled / BootReceiver
    await SentinelService.restoreIfEnabled();
  }
  await NotificationService.initialise();
  await Hive.initFlutter();
  await Hive.openBox<String>(AppConstants.priceBox);
  await Hive.openBox<String>(AppConstants.dcaBox);
  await PriceService.seedFromAssets();

  final prefs = await SharedPreferences.getInstance();
  final onboardingComplete =
      prefs.getBool(AppConstants.keyOnboardingComplete) ?? false;

  runApp(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
      ],
      child: BagApp(onboardingComplete: onboardingComplete),
    ),
  );
}
