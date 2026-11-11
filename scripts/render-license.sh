#!/bin/bash
# Writes LICENSE from LICENSE.template with the copyright holder set in project.env.
#
#   scripts/render-license.sh [output-dir]     # default: repository root
set -euo pipefail
. "$(dirname "$0")/common.sh"
load_project_env

OUT_DIR="${1:-$DIVOICE_ROOT}"
if [ -z "${COPYRIGHT_HOLDER:-}" ]; then
  echo "COPYRIGHT_HOLDER is empty in project.env: set it before writing LICENSE." >&2
  exit 1
fi

# Placeholders are replaced literally (no sed), so any character in the name is safe.
/usr/bin/python3 -I - "$DIVOICE_ROOT/LICENSE.template" "$OUT_DIR/LICENSE" "$COPYRIGHT_YEAR" "$COPYRIGHT_HOLDER" <<'PY'
import sys
template, out, year, holder = sys.argv[1:5]
text = open(template, encoding="utf-8").read()
text = text.replace("{{COPYRIGHT_YEAR}}", year).replace("{{COPYRIGHT_HOLDER}}", holder)
open(out, "w", encoding="utf-8").write(text)
PY
echo "$OUT_DIR/LICENSE: Copyright (c) $COPYRIGHT_YEAR $COPYRIGHT_HOLDER"
