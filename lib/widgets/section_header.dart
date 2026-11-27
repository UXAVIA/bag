import 'package:flutter/material.dart';

/// A section's heading on the Settings and Wallets tabs: the label in the
/// theme's `titleMedium`.
class SectionHeader extends StatelessWidget {
  final String label;

  const SectionHeader({super.key, required this.label});

  @override
  Widget build(BuildContext context) =>
      Text(label, style: Theme.of(context).textTheme.titleMedium);
}
