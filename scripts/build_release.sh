#!/usr/bin/env bash
# Release build script for SatMeter.
# Fetches fresh seed price data then builds the release APK.
#
# Usage:
#   ./scripts/build_release.sh              # build APK
#   ./scripts/build_release.sh --split-per-abi   # build split ABIs for Play
#   SKIP_SEED=1 ./scripts/build_release.sh  # skip data fetch (use existing)

set -euo pipefail

cd "$(dirname "$0")/.."

if [[ "${SKIP_SEED:-0}" != "1" ]]; then
  echo "==> Fetching seed price data..."
  dart run tool/fetch_seed_data.dart
  echo ""
else
  echo "==> Skipping seed fetch (SKIP_SEED=1)"
fi

echo "==> Building release APK..."
flutter build apk --release "$@"

echo ""
echo "==> Done. APK: build/app/outputs/flutter-apk/app-release.apk"
