#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$ROOT/.build/tests"
xcrun clang++ -std=c++17 -fobjc-arc -fblocks -Wall -Wextra \
  "$ROOT/Tests/translation_client.mm" -framework Foundation \
  -o "$ROOT/.build/tests/translation-client"
"$ROOT/.build/tests/translation-client"
