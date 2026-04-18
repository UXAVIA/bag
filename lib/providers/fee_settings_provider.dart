import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/constants/app_constants.dart';
import '../services/widget_service.dart';
import 'shared_preferences_provider.dart';

class FeeSettings {
  final bool showOnHome;   // show fee section on home screen
  final bool compact;      // true = compact row, false = three-tile normal view
  final bool showInWidget; // show fast fee in home screen widget

  const FeeSettings({
    this.showOnHome = false,
    this.compact = true,
    this.showInWidget = false,
  });

  FeeSettings copyWith({bool? showOnHome, bool? compact, bool? showInWidget}) =>
      FeeSettings(
        showOnHome: showOnHome ?? this.showOnHome,
        compact: compact ?? this.compact,
        showInWidget: showInWidget ?? this.showInWidget,
      );
}

final feeSettingsProvider =
    NotifierProvider<FeeSettingsNotifier, FeeSettings>(FeeSettingsNotifier.new);

class FeeSettingsNotifier extends Notifier<FeeSettings> {
  @override
  FeeSettings build() {
    final prefs = ref.read(sharedPreferencesProvider);
    return FeeSettings(
      showOnHome: prefs.getBool(AppConstants.keyShowFeeEstimates) ?? false,
      compact: prefs.getBool(AppConstants.keyFeeCompact) ?? true,
      showInWidget: prefs.getBool(AppConstants.keyWidgetShowFee) ?? false,
    );
  }

  Future<void> setShowOnHome(bool value) async {
    await ref
        .read(sharedPreferencesProvider)
        .setBool(AppConstants.keyShowFeeEstimates, value);
    state = state.copyWith(showOnHome: value);
  }

  Future<void> setCompact(bool value) async {
    await ref
        .read(sharedPreferencesProvider)
        .setBool(AppConstants.keyFeeCompact, value);
    state = state.copyWith(compact: value);
  }

  Future<void> setShowInWidget(bool value) async {
    await ref
        .read(sharedPreferencesProvider)
        .setBool(AppConstants.keyWidgetShowFee, value);
    state = state.copyWith(showInWidget: value);
    if (!value) {
      WidgetService.clearFee().ignore();
    }
  }
}
