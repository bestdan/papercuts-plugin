#!/usr/bin/env bash
# Tests for the marketplace manifest (.claude-plugin/marketplace.json) — it must
# parse, it must advertise exactly the plugin this repo ships, and its version
# must track plugin.json. A drifted version installs the wrong tree under
# ~/.claude/plugins/cache/<marketplace>/<plugin>/<version>, which is the path a
# user's append-gate permission rule is pinned to. Run:
#   bash tests/marketplace-manifest.test.sh

set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/test_prelude.sh"

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
marketplace_json="$repo_root/.claude-plugin/marketplace.json"
plugin_json="$repo_root/.claude-plugin/plugin.json"

fail=0
pass() { printf 'PASS: %s\n' "$1"; }
fail_test() {
  printf 'FAIL: %s\n' "$1"
  fail=1
}

# --- 1. both manifests parse ------------------------------------------------
# plugin.json is guarded too: the later comparisons json.load it, and a broken
# plugin manifest would otherwise surface as name/version mismatches with a
# traceback instead of one clear FAIL line.
if [ -f "$marketplace_json" ] && python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$marketplace_json" 2>/dev/null; then
  pass ".claude-plugin/marketplace.json exists and is valid JSON"
else
  fail_test ".claude-plugin/marketplace.json exists and is valid JSON"
  printf '\nManifest unusable; skipping the rest.\n'
  exit 1
fi

if [ -f "$plugin_json" ] && python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$plugin_json" 2>/dev/null; then
  pass ".claude-plugin/plugin.json exists and is valid JSON"
else
  fail_test ".claude-plugin/plugin.json exists and is valid JSON"
  printf '\nPlugin manifest unusable; skipping the rest.\n'
  exit 1
fi

# --- 2. it advertises exactly one plugin, named for the plugin manifest ------
read -r entry_count entry_name entry_version entry_source_url <<EOF
$(python3 -c '
import json
import sys

with open(sys.argv[1], "rb") as f:
    data = json.load(f)

plugins = data.get("plugins", [])
first = plugins[0] if plugins else {}
print(
    len(plugins),
    first.get("name", "-"),
    first.get("version", "-"),
    first.get("source", {}).get("url", "-"),
)
' "$marketplace_json")
EOF

if [ "$entry_count" = "1" ]; then
  pass "marketplace.json advertises exactly one plugin"
else
  fail_test "marketplace.json advertises exactly one plugin (found $entry_count)"
fi

plugin_name="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("name", "-"))' "$plugin_json")"
if [ "$entry_name" = "$plugin_name" ]; then
  pass "marketplace entry name matches plugin.json ($plugin_name)"
else
  fail_test "marketplace entry name is $entry_name but plugin.json says $plugin_name"
fi

# --- 3. the versions agree --------------------------------------------------
plugin_version="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("version", "-"))' "$plugin_json")"
if [ "$entry_version" = "$plugin_version" ]; then
  pass "marketplace entry version matches plugin.json ($plugin_version)"
else
  fail_test "marketplace entry version is $entry_version but plugin.json says $plugin_version"
fi

# --- 4. the source points at this repo --------------------------------------
expected_url="https://github.com/bestdan/papercuts-plugin.git"
if [ "$entry_source_url" = "$expected_url" ]; then
  pass "marketplace entry source url is $expected_url"
else
  fail_test "marketplace entry source url is $entry_source_url, expected $expected_url"
fi

if [ "$fail" -eq 0 ]; then
  printf '\nAll marketplace-manifest checks passed.\n'
else
  printf '\nSome marketplace-manifest checks failed.\n'
fi
exit "$fail"
