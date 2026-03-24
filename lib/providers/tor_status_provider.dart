import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/tor_service.dart';

final torStatusProvider =
    AsyncNotifierProvider<TorStatusNotifier, TorStatus>(
  TorStatusNotifier.new,
);

class TorStatusNotifier extends AsyncNotifier<TorStatus> {
  @override
  Future<TorStatus> build() => TorService.probe();

  /// Re-probe Orbot — call this when the user taps the refresh button
  /// after launching Orbot in the background.
  Future<void> recheck() async {
    state = const AsyncValue.loading();
    state = await AsyncValue.guard(TorService.probe);
  }

  /// Update the cached status with an already-known result.
  /// Use this when a fresh probe has just been performed inline (e.g. before
  /// a wallet scan) so the UI badge reflects reality without triggering a
  /// second probe or passing through the loading state.
  void setValue(TorStatus status) {
    state = AsyncValue.data(status);
  }
}
