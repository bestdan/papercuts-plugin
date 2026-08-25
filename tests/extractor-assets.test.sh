#!/usr/bin/env bash
# Asserts the extractor's bundled assets exist at the paths extractor-run.sh
# resolves by default. This cannot be left to papercut-capture.test.sh: that
# suite stubs the extractor via PAPERCUT_EXTRACTOR_CMD (and the extractor via
# PAPERCUT_EXTRACTOR_SCHEMA / PAPERCUT_EXTRACTOR_PROMPT), so a missing bundled
# file never fails it — the file could be dropped in a move and the suite
# would stay green.
# Run:
#   bash tests/extractor-assets.test.sh

set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/test_prelude.sh"

script_dir="$(cd "$(dirname "$0")/../scripts" && pwd)"
fail=0

# Mirror extractor-run.sh's own defaults exactly:
#   schema_file="${PAPERCUT_EXTRACTOR_SCHEMA:-$script_dir/extractor-schema.json}"
#   prompt_file="${PAPERCUT_EXTRACTOR_PROMPT:-$script_dir/../prompts/extractor-prompt.md}"
schema_file="$script_dir/extractor-schema.json"
prompt_file="$script_dir/../prompts/extractor-prompt.md"

if [ -f "$schema_file" ]; then
  echo "PASS: extractor-schema.json exists at the default path"
else
  echo "FAIL: extractor-schema.json missing at $schema_file"
  fail=1
fi

if python3 -c "import json; json.load(open('$schema_file'))" 2>/dev/null; then
  echo "PASS: extractor-schema.json is valid JSON"
else
  echo "FAIL: extractor-schema.json is not valid JSON"
  fail=1
fi

if [ -f "$prompt_file" ]; then
  echo "PASS: extractor-prompt.md exists at the default path"
else
  echo "FAIL: extractor-prompt.md missing at $prompt_file"
  fail=1
fi

# Guard the mirror itself: the defaults asserted above must still be the
# defaults extractor-run.sh actually resolves.
if grep -qF 'PAPERCUT_EXTRACTOR_SCHEMA:-$script_dir/extractor-schema.json' "$script_dir/extractor-run.sh" \
  && grep -qF 'PAPERCUT_EXTRACTOR_PROMPT:-$script_dir/../prompts/extractor-prompt.md' "$script_dir/extractor-run.sh"; then
  echo "PASS: asserted paths match extractor-run.sh's defaults"
else
  echo "FAIL: extractor-run.sh's default asset paths changed; update this suite"
  fail=1
fi

if [ "$fail" -eq 0 ]; then
  echo "All extractor-assets tests passed."
else
  echo "Some extractor-assets tests FAILED."
fi
exit "$fail"
