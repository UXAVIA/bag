#!/usr/bin/env bash
# Regenerates Bag's third-party licence notices:
#   assets/licenses/rust_licenses.json, assets/licenses/native_licenses.json
#   and THIRD_PARTY_NOTICES.md.
#
#   bash tools/licenses/generate.sh
#
# Run it after any dependency change (pubspec.lock, the tor plugin's ref, a
# Flutter or plugin bump) and commit the three files: the release workflow
# regenerates them and fails if they differ from what is committed.
#
# Needs network, the Flutter release in .flutter-version on PATH, and cargo
# with the pinned cargo-about:
#   cargo install --locked --features cli cargo-about --version 0.9.3
# See generate.py for what each file covers and how it is enumerated.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
exec python3 -I "$here/generate.py" "$@"
