import '../core/constants/app_constants.dart';

enum ExplorerPreset { blockstream, mempool, custom }

class NetworkSettings {
  final ExplorerPreset preset;
  final String customUrl;
  final bool useTor;

  const NetworkSettings({
    this.preset = ExplorerPreset.blockstream,
    this.customUrl = '',
    this.useTor = false,
  });

  /// The base URL that the Esplora client should use.
  String get effectiveBaseUrl => switch (preset) {
        ExplorerPreset.blockstream => AppConstants.explorerBlockstream,
        ExplorerPreset.mempool => AppConstants.explorerMempool,
        ExplorerPreset.custom => customUrl.isNotEmpty
            ? customUrl
            : AppConstants.explorerBlockstream,
      };

  NetworkSettings copyWith({
    ExplorerPreset? preset,
    String? customUrl,
    bool? useTor,
  }) =>
      NetworkSettings(
        preset: preset ?? this.preset,
        customUrl: customUrl ?? this.customUrl,
        useTor: useTor ?? this.useTor,
      );
}
