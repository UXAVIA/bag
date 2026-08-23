import 'package:flutter/material.dart';

import '../core/theme/app_theme.dart';
import '../models/chain_analysis.dart';

/// Shows a bottom sheet with the full privacy score breakdown.
void showPrivacyScoreSheet(BuildContext context, ChainAnalysisResult result) {
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => _PrivacyScoreSheet(result: result),
  );
}

class _PrivacyScoreSheet extends StatelessWidget {
  final ChainAnalysisResult result;
  const _PrivacyScoreSheet({required this.result});

  @override
  Widget build(BuildContext context) {
    final score = result.score;
    final scoreColor = AppColors.scoreColor(score.score);
    final cs = Theme.of(context).colorScheme;

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      minChildSize: 0.4,
      maxChildSize: 0.92,
      builder: (_, controller) => Column(
        children: [
          // Drag handle
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: cs.outline,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),

          Expanded(
            child: ListView(
              controller: controller,
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 40),
              children: [
                // Score hero
                Center(
                  child: Column(
                    children: [
                      Text(
                        'Bitcoin Health Check',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 20),
                      _ScoreGauge(score: score.score, color: scoreColor),
                      const SizedBox(height: 8),
                      Text(
                        _scoreLabel(score.score),
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color: scoreColor,
                              fontWeight: FontWeight.w600,
                            ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${score.totalUtxos} UTXOs · ${score.totalAddresses} addresses',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 28),

                // Breakdown
                Text(
                  'SCORE BREAKDOWN',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.5,
                      ),
                ),
                const SizedBox(height: 8),
                Container(
                  decoration: BoxDecoration(
                    color: cs.surface,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: cs.outline),
                  ),
                  child: Column(
                    children: [
                      _ComponentRow(
                        icon: Icons.wifi_tethering_error,
                        label: 'Address hygiene',
                        detail: score.reusedAddressCount > 0
                            ? '${score.reusedAddressCount} of ${score.totalAddresses} addresses reused'
                            : 'No address reuse detected',
                        earned: score.hygienePoints,
                        max: 30,
                        isFirst: true,
                      ),
                      _ComponentRow(
                        icon: Icons.shield_outlined,
                        label: 'Coinjoin coverage',
                        detail: score.coinjoinedCount > 0
                            ? '${score.coinjoinedCount} of ${score.totalUtxos} UTXOs coinjoined'
                            : 'No coinjoined UTXOs detected',
                        earned: score.coinjoinPoints,
                        max: 25,
                      ),
                      _ComponentRow(
                        icon: Icons.grain,
                        label: 'UTXO cleanliness',
                        detail: _cleanlinessDetail(score),
                        earned: score.cleanlinessPoints,
                        max: 20,
                      ),
                      _ComponentRow(
                        icon: Icons.compare_arrows,
                        label: 'Address consistency',
                        detail: score.hasMixedTypes
                            ? 'Multiple address types in UTXO set'
                            : 'Consistent address types',
                        earned: score.consistencyPoints,
                        max: 10,
                      ),
                      _ComponentRow(
                        icon: Icons.security,
                        label: 'Privacy infrastructure',
                        detail: _infraDetail(score),
                        earned: score.infraPoints,
                        max: 15,
                        isLast: true,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),

                // What does this mean
                Text(
                  'WHAT THIS MEANS',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.5,
                      ),
                ),
                const SizedBox(height: 8),
                Text(
                  _scoreExplanation(score),
                  style: Theme.of(context)
                      .textTheme
                      .bodyMedium
                      ?.copyWith(height: 1.5),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _cleanlinessDetail(PrivacyScore score) {
    final parts = <String>[];
    if (score.dustCount > 0) {
      parts.add('${score.dustCount} dust UTXO${score.dustCount == 1 ? '' : 's'}');
    }
    if (score.roundAmountCount > 0) {
      parts.add('${score.roundAmountCount} round amount${score.roundAmountCount == 1 ? '' : 's'}');
    }
    return parts.isEmpty ? 'No dust or round amounts' : parts.join(' · ');
  }

  String _infraDetail(PrivacyScore score) {
    if (score.torEnabled && score.customExplorerEnabled) {
      return 'Tor + personal node';
    }
    if (score.torEnabled) return 'Tor enabled, no custom node';
    if (score.customExplorerEnabled) return 'Custom node, no Tor';
    return 'No Tor or custom node';
  }

  String _scoreExplanation(PrivacyScore score) {
    if (score.score >= 90) {
      return 'Excellent privacy hygiene. Your UTXO set is well-mixed, '
          'addresses are fresh, and your infrastructure protects query privacy.';
    }
    if (score.score >= 75) {
      return 'Good privacy posture with room to improve. '
          '${score.coinjoinPoints < 20 ? 'Increasing coinjoin coverage would push your score higher. ' : ''}'
          '${!score.torEnabled ? 'Enabling Tor would protect your wallet queries. ' : ''}';
    }
    if (score.score >= 55) {
      return 'Moderate privacy. '
          '${score.reusedAddressCount > 0 ? 'Address reuse is your biggest risk — reused addresses link your transactions. ' : ''}'
          '${score.coinjoinPoints == 0 ? 'Coinjoin mixing would significantly improve your score. ' : ''}';
    }
    if (score.score >= 35) {
      return 'Several privacy concerns detected. '
          '${score.reusedAddressCount > 0 ? 'Address reuse makes your transaction graph traceable. ' : ''}'
          '${score.hasMixedTypes ? 'Mixed address types reveal wallet history. ' : ''}'
          'Consider moving funds to a fresh wallet and using coinjoin.';
    }
    return 'Significant privacy risks. Reused addresses, no mixing, and no '
        'privacy infrastructure leave your transaction history exposed. '
        'Consider a fresh wallet, Tor routing, and a privacy-preserving '
        'coinjoin service.';
  }
}

// ── Score gauge ───────────────────────────────────────────────────────────────

class _ScoreGauge extends StatelessWidget {
  final int score;
  final Color color;

  const _ScoreGauge({required this.score, required this.color});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 120,
      height: 120,
      child: CustomPaint(
        painter: _GaugePainter(
          score: score,
          color: color,
          trackColor:
              Theme.of(context).colorScheme.outline.withValues(alpha: 0.2),
        ),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '$score',
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                      color: color,
                      fontWeight: FontWeight.w700,
                      height: 1,
                    ),
              ),
              Text(
                '/ 100',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: color.withValues(alpha: 0.7),
                    ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _GaugePainter extends CustomPainter {
  final int score;
  final Color color;
  final Color trackColor;

  const _GaugePainter({
    required this.score,
    required this.color,
    required this.trackColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    const strokeWidth = 8.0;
    const startAngle = 2.356; // 135°
    const sweepTotal = 4.712; // 270°

    final rect = Rect.fromCircle(
      center: Offset(size.width / 2, size.height / 2),
      radius: size.width / 2 - strokeWidth / 2,
    );

    // Track
    canvas.drawArc(
      rect,
      startAngle,
      sweepTotal,
      false,
      Paint()
        ..color = trackColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.round,
    );

    // Fill
    if (score > 0) {
      canvas.drawArc(
        rect,
        startAngle,
        sweepTotal * (score / 100),
        false,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = strokeWidth
          ..strokeCap = StrokeCap.round,
      );
    }
  }

  @override
  bool shouldRepaint(_GaugePainter old) =>
      old.score != score || old.color != color;
}

// ── Component row ─────────────────────────────────────────────────────────────
//
// Each row shows how many points the component earned vs its maximum.
// earned == max → green; earned >= max/2 → amber; earned < max/2 → red.

class _ComponentRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String detail;
  final int earned;
  final int max;
  final bool isFirst;
  final bool isLast;

  const _ComponentRow({
    required this.icon,
    required this.label,
    required this.detail,
    required this.earned,
    required this.max,
    this.isFirst = false,
    this.isLast = false,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    final Color earnedColor;
    if (earned == max) {
      earnedColor = AppColors.positive;
    } else if (earned * 2 >= max) {
      earnedColor = Colors.amber.shade700;
    } else {
      earnedColor = AppColors.negative;
    }

    return Column(
      children: [
        if (!isFirst)
          Divider(height: 1, color: cs.outline.withValues(alpha: 0.5)),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Icon(icon, size: 18, color: cs.secondary),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label,
                        style: Theme.of(context).textTheme.bodyMedium),
                    Text(detail,
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(color: cs.secondary)),
                  ],
                ),
              ),
              // Points badge: "earned / max"
              RichText(
                text: TextSpan(
                  children: [
                    TextSpan(
                      text: '$earned',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: earnedColor,
                            fontWeight: FontWeight.w700,
                          ),
                    ),
                    TextSpan(
                      text: '/$max',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: cs.secondary,
                          ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ── Helpers ───────────────────────────────────────────────────────────────────

String _scoreLabel(int score) {
  if (score >= 90) return 'Excellent';
  if (score >= 80) return 'Good';
  if (score >= 70) return 'Fair';
  if (score >= 60) return 'Moderate';
  if (score >= 40) return 'Concerning';
  return 'Poor';
}
