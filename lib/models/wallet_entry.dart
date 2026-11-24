import 'dart:convert';

/// What kind of holding a [WalletEntry] represents.
enum WalletKind {
  /// Watch-only single-sig BIP84 wallet. Secret material: a `zpub`.
  zpub,

  /// Watch-only wallet described by an output descriptor — typically a
  /// multisig such as Bitkey's 2-of-3. Secret material: the descriptor.
  descriptor,

  /// A balance the user typed in themselves (e.g. coins held on an
  /// exchange). Nothing is derived and nothing is ever queried on-chain.
  manual;

  static WalletKind fromName(String? name) => switch (name) {
        'descriptor' => WalletKind.descriptor,
        'manual' => WalletKind.manual,
        // Entries written before multi-kind support are all zpubs.
        _ => WalletKind.zpub,
      };
}

/// A single portfolio entry with its cached scan state.
///
/// The zpub / descriptor is NOT stored here — it lives in
/// FlutterSecureStorage keyed by [id]. This model holds only the metadata
/// needed to render and schedule scans, and it is itself persisted to
/// secure storage (see `biometric_storage_service.dart`) because
/// per-wallet balances are sensitive.
final class WalletEntry {
  final String id;
  final String label;
  final WalletKind kind;
  final int? lastSats;
  final DateTime? lastScanAt;
  final int usedAddresses;

  /// Human-readable script summary for descriptor wallets, e.g.
  /// "2-of-3 multisig · native segwit". Derived from the descriptor at add
  /// time so the UI never has to decrypt the descriptor just to draw a card.
  /// Null for other kinds.
  final String? descriptorSummary;

  /// Last scanned external (receive) address index — used to re-derive
  /// addresses for chain analysis without re-scanning.
  final int lastExternalIndex;

  /// Last scanned change address index.
  final int lastChangeIndex;

  // Transient scan state — NOT persisted.
  final bool isScanning;
  final int scanProgress;
  final String? scanError;

  const WalletEntry({
    required this.id,
    required this.label,
    this.kind = WalletKind.zpub,
    this.lastSats,
    this.lastScanAt,
    this.usedAddresses = 0,
    this.descriptorSummary,
    this.lastExternalIndex = 0,
    this.lastChangeIndex = 0,
    this.isScanning = false,
    this.scanProgress = 0,
    this.scanError,
  });

  double get btcAmount => (lastSats ?? 0) / 1e8;

  /// True for entries whose balance comes from an on-chain scan.
  bool get isWatchOnly => kind != WalletKind.manual;

  bool get isStale {
    // Manual entries are whatever the user last typed — never stale, and
    // never scanned.
    if (kind == WalletKind.manual) return false;
    if (lastScanAt == null) return true;
    return DateTime.now().difference(lastScanAt!) > const Duration(minutes: 15);
  }

  // Sentinel so copyWith can explicitly clear nullable fields.
  static const _keep = Object();

  WalletEntry copyWith({
    String? id,
    String? label,
    WalletKind? kind,
    int? lastSats,
    DateTime? lastScanAt,
    int? usedAddresses,
    Object? descriptorSummary = _keep,
    int? lastExternalIndex,
    int? lastChangeIndex,
    bool? isScanning,
    int? scanProgress,
    Object? scanError = _keep,
  }) =>
      WalletEntry(
        id: id ?? this.id,
        label: label ?? this.label,
        kind: kind ?? this.kind,
        lastSats: lastSats ?? this.lastSats,
        lastScanAt: lastScanAt ?? this.lastScanAt,
        usedAddresses: usedAddresses ?? this.usedAddresses,
        descriptorSummary: descriptorSummary == _keep
            ? this.descriptorSummary
            : descriptorSummary as String?,
        lastExternalIndex: lastExternalIndex ?? this.lastExternalIndex,
        lastChangeIndex: lastChangeIndex ?? this.lastChangeIndex,
        isScanning: isScanning ?? this.isScanning,
        scanProgress: scanProgress ?? this.scanProgress,
        scanError: scanError == _keep ? this.scanError : scanError as String?,
      );

  /// Serialises only the stable metadata fields — not transient scan state.
  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'kind': kind.name,
        if (lastSats != null) 'lastSats': lastSats,
        if (lastScanAt != null)
          'lastScanAt': lastScanAt!.millisecondsSinceEpoch,
        'usedAddresses': usedAddresses,
        if (descriptorSummary != null) 'descriptorSummary': descriptorSummary,
        'lastExternalIndex': lastExternalIndex,
        'lastChangeIndex': lastChangeIndex,
      };

  factory WalletEntry.fromJson(Map<String, dynamic> json) => WalletEntry(
        id: json['id'] as String,
        label: json['label'] as String,
        kind: WalletKind.fromName(json['kind'] as String?),
        lastSats: json['lastSats'] as int?,
        lastScanAt: json['lastScanAt'] != null
            ? DateTime.fromMillisecondsSinceEpoch(json['lastScanAt'] as int)
            : null,
        usedAddresses: json['usedAddresses'] as int? ?? 0,
        descriptorSummary: json['descriptorSummary'] as String?,
        lastExternalIndex: json['lastExternalIndex'] as int? ?? 0,
        lastChangeIndex: json['lastChangeIndex'] as int? ?? 0,
      );

  static List<WalletEntry> listFromJson(String raw) {
    final list = jsonDecode(raw) as List<dynamic>;
    return list
        .map((e) => WalletEntry.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  static String listToJsonString(List<WalletEntry> entries) =>
      jsonEncode(entries.map((e) => e.toJson()).toList());
}
