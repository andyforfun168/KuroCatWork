#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/kurocatwork-check.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT
python3 - "$ROOT" "$CHECK_DIR" <<'PY'
from pathlib import Path
import sys
root,work=map(Path,sys.argv[1:])
for source in (root/'Sources').glob('*.swift'):
    if source.name != 'main.swift':
        (work/source.name).write_text(source.read_text().replace('UserDefaults.standard','workTestDefaults'))
(work/'main.swift').write_text((root/'tests/main.swift').read_text())
PY
swiftc -module-cache-path "${TMPDIR:-/tmp}/kurocatwork-test-cache" \
  -framework AppKit -framework CoreGraphics -framework QuartzCore \
  -framework IOKit -framework ApplicationServices -framework WebKit -lsqlite3 \
  "$CHECK_DIR"/*.swift -o "$CHECK_DIR/check"
"$CHECK_DIR/check" "$CHECK_DIR/work-mode-options.png"
