#!/usr/bin/env bash
# Tests for papercut_append.py — the trusted gate all papercut records
# funnel through (construct -> validate -> scrub -> revalidate -> append).
# Run:
#   bash tests/papercut_append.test.sh

set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/test_prelude.sh"

gate="$(dirname "$0")/../scripts/papercut_append.py"
fail=0
workdir="$(mktemp -d "${TMPDIR:-/tmp}/papercut-test.XXXXXX")"
trap 'rm -rf "$workdir"' EXIT

next_dir() {
  local d
  d="$workdir/$RANDOM$RANDOM"
  mkdir -p "$d"
  printf '%s' "$d"
}

# Suite-wide config: one strict_hosts pattern, so a monkeypatched "WORK-*"
# hostname resolves to the strict profile and everything else to default. The
# prelude pinned HOME and unset XDG_CONFIG_HOME, so without this the resolver
# would find no config at all and no hostname could ever reach strict.
strict_hosts_config="$workdir/config-strict-hosts.toml"
cat >"$strict_hosts_config" <<'EOF'
[profile]
strict_hosts = ["WORK-*"]
EOF
export PAPERCUT_CONFIG="$strict_hosts_config"

# Runs the gate as a subprocess with socket.gethostname monkeypatched to $host,
# so the suite can drive EITHER profile on any machine (including a real work
# laptop whose hostname matches the operator's own strict_hosts) without a
# production-settable env override. Production invokes `python3
# papercut_append.py` directly, which has no patch, so the machine profile can
# never be flipped by a caller's environment.
#
# A monkeypatched hostname only reaches the strict profile because of
# $strict_hosts_config below: detect_machine() matches the hostname against
# profile.strict_hosts from the config file, so the suite pins PAPERCUT_CONFIG
# at a temp config declaring the pattern "WORK-*". The OTHER strict trigger --
# the marker file -- is exercised separately (sections 28-31), under a temp
# HOME, since no config can name its path.
run_as_host() {
  local host="$1"
  shift
  python3 -c '
import runpy, socket, sys
host, gate = sys.argv[1], sys.argv[2]
socket.gethostname = lambda: host
sys.argv = ["papercut_append.py"] + sys.argv[3:]
runpy.run_path(gate, run_name="__main__")
' "$host" "$gate" "$@"
}

# Runs the gate with a fresh spool/lock dir (so tests never touch real
# ~/.claude or ~/.config) and the default profile unless the caller sets
# PAPERCUT_FAKE_HOST to a hostname matching $strict_hosts_config's pattern.
run_gate() {
  local dir="$1"
  shift
  local stdin_json="$1"
  shift
  printf '%s' "$stdin_json" | (
    export PAPERCUT_SPOOL="$dir/spool.jsonl" PAPERCUT_LOCK="$dir/.spool.lock"
    run_as_host "${PAPERCUT_FAKE_HOST:-some-laptop}" "$@"
  )
}

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    printf 'ok   (%s)\n' "$desc"
  else
    printf 'FAIL (%s: expected %q, got %q)\n' "$desc" "$expected" "$actual"
    fail=1
  fi
}

assert_true() {
  local desc="$1" cond="$2"
  if [ "$cond" = "1" ]; then
    printf 'ok   (%s)\n' "$desc"
  else
    printf 'FAIL (%s)\n' "$desc"
    fail=1
  fi
}

# Pulls a top-level string field out of a single-record JSON stdout blob.
get_field() {
  local json="$1" field="$2"
  printf '%s' "$json" | python3 -c "import json, sys; print(json.loads(sys.stdin.read()).get('$field', ''))"
}

assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then
    printf 'ok   (%s)\n' "$desc"
  else
    printf 'FAIL (%s: expected to find %q in %q)\n' "$desc" "$needle" "$haystack"
    fail=1
  fi
}

assert_not_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then
    printf 'FAIL (%s: did not expect to find %q in %q)\n' "$desc" "$needle" "$haystack"
    fail=1
  else
    printf 'ok   (%s)\n' "$desc"
  fi
}

# --- 1. valid round-trip: default profile + --repo, stdout contract ---
d="$(next_dir)"
out="$(run_gate "$d" '{"category":"harness_config","severity":"low","title":"t1","description":"d1"}' \
  --source manual --producer test/1 --repo dotfiles)"
rc=$?
assert_eq "round-trip exits 0" "0" "$rc"
if printf '%s' "$out" | python3 -c '
import json, re, sys
rec = json.loads(sys.stdin.read())
assert re.match(r"^pc_[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-4[0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$", rec["id"])
assert re.match(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$", rec["ts"])
assert rec["machine"] == "default"
assert rec["repo"] == "dotfiles"
' 2>"$workdir"/round_trip_err; then
  printf 'ok   (round-trip stdout has generated id/ts, machine=default, repo)\n'
else
  printf 'FAIL (round-trip stdout contract: %s | out=%q)\n' "$(cat "$workdir"/round_trip_err)" "$out"
  fail=1
fi
lines="$(wc -l < "$d/spool.jsonl" | tr -d ' ')"
assert_eq "round-trip appends exactly one line" "1" "$lines"

# --- 2. controlled fields constructed: caller-supplied id/ts/machine ignored ---
d="$(next_dir)"
out="$(run_gate "$d" '{"category":"harness_config","severity":"low","title":"t2","description":"d2","id":"pc_evil","ts":"1999-01-01T00:00:00Z","machine":"strict"}' \
  --source manual --producer test/1 --repo dotfiles)"
if printf '%s' "$out" | python3 -c '
import json, sys
rec = json.loads(sys.stdin.read())
assert rec["id"] != "pc_evil"
assert rec["ts"] != "1999-01-01T00:00:00Z"
assert rec["machine"] == "default"
' 2>"$workdir"/spoof_err; then
  printf 'ok   (caller-supplied id/ts/machine ignored, gate-constructed values used)\n'
else
  printf 'FAIL (controlled-field spoofing test: %s | out=%q)\n' "$(cat "$workdir"/spoof_err)" "$out"
  fail=1
fi

# --- 3. schema rejections: exit 1, nothing appended ---
d="$(next_dir)"
run_gate "$d" '{"category":"harness_config","severity":"nonsense","title":"t3","description":"d3"}' \
  --source manual --producer test/1 --repo dotfiles >"$workdir"/bad_severity_out 2>"$workdir"/bad_severity_err
rc=$?
assert_eq "bad severity enum exits 1" "1" "$rc"
assert_true "bad severity enum appends nothing" "$([ ! -s "$d/spool.jsonl" ] && echo 1 || echo 0)"

d="$(next_dir)"
long_title="$(python3 -c 'print("x" * 101)')"
run_gate "$d" "{\"category\":\"harness_config\",\"severity\":\"low\",\"title\":\"$long_title\",\"description\":\"d4\"}" \
  --source manual --producer test/1 --repo dotfiles >"$workdir"/long_title_out 2>"$workdir"/long_title_err
rc=$?
assert_eq "title over 100 chars exits 1" "1" "$rc"
assert_true "title over 100 chars appends nothing" "$([ ! -s "$d/spool.jsonl" ] && echo 1 || echo 0)"

d="$(next_dir)"
run_gate "$d" '{"category":"harness_config","severity":"low","title":"t5","description":"d5"}' \
  --source manual --producer test/1 >"$workdir"/no_repo_out 2>"$workdir"/no_repo_err
rc=$?
assert_eq "default profile missing required repo exits 1" "1" "$rc"
assert_true "missing repo appends nothing" "$([ ! -s "$d/spool.jsonl" ] && echo 1 || echo 0)"

# additionalProperties:false via a controlled-construction test: force an
# unknown key straight into the constructed record and confirm the
# hand-rolled validator's additionalProperties check rejects it.
d="$(next_dir)"
out="$(PAPERCUT_SPOOL="$d/spool.jsonl" PAPERCUT_LOCK="$d/.spool.lock" python3 -c '
import sys
sys.path.insert(0, "'"$(dirname "$gate")"'")
import papercut_append as pa
schema = pa.load_schema()
rec = {
    "id": "pc_00000000-0000-4000-8000-000000000000",
    "v": 1,
    "producer": "test/1",
    "ts": "2026-01-01T00:00:00Z",
    "machine": "default",
    "source": "manual",
    "category": "harness_config",
    "severity": "low",
    "title": "t",
    "description": "d",
    "repo": "dotfiles",
    "unexpected_field": "nope",
}
ok, reason = pa.validate_record(rec, schema)
print("REJECTED" if not ok else "ACCEPTED", reason)
')"
assert_true "additionalProperties:false rejects an unknown key" "$(printf '%s' "$out" | grep -q '^REJECTED' && echo 1 || echo 0)"

# --- 4/5. strict profile drops session_id and repo (not a rejection) ---
# strict profile fails closed without a valid denylist (see section 13
# below), so this pre-existing test needs one even though it isn't
# exercising denylist behavior itself.
strict_smoke_denylist="$workdir/denylist_strict_smoke.txt"
printf 'unrelated-literal\n' >"$strict_smoke_denylist"
chmod 0600 "$strict_smoke_denylist"
d="$(next_dir)"
out="$(PAPERCUT_DENYLIST="$strict_smoke_denylist" PAPERCUT_FAKE_HOST=WORK-LAPTOP-01 run_gate "$d" '{"category":"harness_config","severity":"low","title":"t6","description":"d6","repo":"secret-repo","session_id":"stdin-sess"}' \
  --source manual --producer test/1 --repo dotfiles --session-id sess-123)"
rc=$?
assert_eq "strict profile still exits 0" "0" "$rc"
if printf '%s' "$out" | python3 -c '
import json, sys
rec = json.loads(sys.stdin.read())
assert rec["machine"] == "strict"
assert "repo" not in rec
assert "session_id" not in rec
' 2>"$workdir"/strict_err; then
  printf 'ok   (strict drops repo and session_id from both flags and stdin)\n'
else
  printf 'FAIL (strict drop test: %s | out=%q)\n' "$(cat "$workdir"/strict_err)" "$out"
  fail=1
fi
lines="$(wc -l < "$d/spool.jsonl" | tr -d ' ')"
assert_eq "strict record still appended (not rejected)" "1" "$lines"

# --- 6. array input: 2 records in, 2 lines appended, 2 printed ---
d="$(next_dir)"
out="$(run_gate "$d" '[{"category":"harness_config","severity":"low","title":"a1","description":"d1"},{"category":"model_behavior","severity":"high","title":"a2","description":"d2"}]' \
  --source auto --producer test/2 --repo dotfiles)"
rc=$?
assert_eq "array input exits 0" "0" "$rc"
out_lines="$(printf '%s\n' "$out" | grep -c .)"
assert_eq "array input prints 2 lines" "2" "$out_lines"
spool_lines="$(wc -l < "$d/spool.jsonl" | tr -d ' ')"
assert_eq "array input appends 2 lines" "2" "$spool_lines"

# --- 7. concurrent appends don't interleave/corrupt ---
d="$(next_dir)"
n=20
pids=()
for i in $(seq 1 "$n"); do
  (run_gate "$d" "{\"category\":\"harness_config\",\"severity\":\"low\",\"title\":\"c$i\",\"description\":\"concurrent $i\"}" \
    --source manual --producer test/concurrency --repo dotfiles >/dev/null 2>>"$workdir/concurrency_err") &
  pids+=($!)
done
for p in "${pids[@]}"; do
  wait "$p" || { echo "FAIL (concurrent append process $p failed)"; fail=1; }
done

spool_line_count="$(wc -l < "$d/spool.jsonl" | tr -d ' ')"
assert_eq "concurrency: exactly $n lines in spool" "$n" "$spool_line_count"

well_formed=0
while IFS= read -r line; do
  if printf '%s' "$line" | python3 -c 'import json, sys; json.loads(sys.stdin.read())' 2>/dev/null; then
    well_formed=$((well_formed + 1))
  fi
done < "$d/spool.jsonl"
assert_eq "concurrency: every line is well-formed JSON" "$n" "$well_formed"

distinct_ids="$(python3 -c '
import json
ids = set()
with open("'"$d/spool.jsonl"'") as f:
    for line in f:
        ids.add(json.loads(line)["id"])
print(len(ids))
')"
assert_eq "concurrency: $n distinct ids" "$n" "$distinct_ids"

# --- 8. file/dir perms (dir must not already exist: the gate itself must
# create it with mode 0700, so use a nested path the test never pre-mkdirs) ---
parent="$(next_dir)"
d="$parent/spool_dir"
PAPERCUT_SPOOL="$d/spool.jsonl" PAPERCUT_LOCK="$d/.spool.lock" \
  run_as_host some-laptop --source manual --producer test/1 --repo dotfiles \
  <<<'{"category":"harness_config","severity":"low","title":"perm","description":"d"}' >/dev/null
dir_perm="$(stat -c '%a' "$d" 2>/dev/null || stat -f '%Lp' "$d")"
file_perm="$(stat -c '%a' "$d/spool.jsonl" 2>/dev/null || stat -f '%Lp' "$d/spool.jsonl")"
assert_eq "spool dir is 0700" "700" "$dir_perm"
assert_eq "spool file is 0600" "600" "$file_perm"

# --- 9. a pre-existing world-readable spool gets tightened to 0600 on append
# (os.open's mode only applies on creation; the gate fchmods regardless). ---
d="$(next_dir)"
: > "$d/spool.jsonl"
chmod 0644 "$d/spool.jsonl"
PAPERCUT_SPOOL="$d/spool.jsonl" PAPERCUT_LOCK="$d/.spool.lock" \
  run_as_host some-laptop --source manual --producer test/1 --repo dotfiles \
  <<<'{"category":"harness_config","severity":"low","title":"perm","description":"d"}' >/dev/null
existing_perm="$(stat -c '%a' "$d/spool.jsonl" 2>/dev/null || stat -f '%Lp' "$d/spool.jsonl")"
assert_eq "pre-existing permissive spool tightened to 0600" "600" "$existing_perm"

# =============================================================================
# Scrub stage (papercuts_task_2__scrub) — the privacy backstop.
#
# IMPORTANT: passing these tests proves SYNTACTIC scrubbing only, NOT
# semantic confidentiality. Regexes can detect emails/IPs/tokens/keys/JWTs/
# PEM blocks/creds-in-URLs/home paths, but they cannot detect arbitrary
# internal repo names, ticket IDs, project codenames, or person names — that
# residual risk is accepted and documented in papercuts_plan.md's privacy
# model. The only backstop for those semantic cases is the per-machine
# denylist (never committed) and, on the strict profile, its fail-closed gate.
#
# Every test below routes through PAPERCUT_DENYLIST pointing at a temp file
# (or a deliberately missing/malformed one) — never the real
# ~/.config/papercuts/denylist.txt.
# =============================================================================

no_denylist="$workdir/no-such-denylist.txt"

# --- 10. built-in redaction patterns, one at a time (default profile,
# denylist absent so only built-in patterns are in play) ---

d="$(next_dir)"
out="$(PAPERCUT_DENYLIST="$no_denylist" run_gate "$d" \
  '{"category":"harness_config","severity":"low","title":"t","description":"contact me at foo.bar@example.com about it"}' \
  --source manual --producer test/1 --repo dotfiles)"
desc="$(get_field "$out" description)"
assert_contains "email: marker present" "$desc" "[email]"
assert_not_contains "email: raw address gone" "$desc" "foo.bar@example.com"

# The other two free-text fields (title, suggested_fix) must be scrubbed too,
# not just description — guards against a field being dropped from
# FREE_TEXT_KEYS or handled differently.
d="$(next_dir)"
out="$(PAPERCUT_DENYLIST="$no_denylist" run_gate "$d" \
  '{"category":"harness_config","severity":"low","title":"ping admin@example.com re host","description":"d","suggested_fix":"rotate key sk-abcdefghijklmnopqrstuvwxyz1234 now"}' \
  --source manual --producer test/1 --repo dotfiles)"
title="$(get_field "$out" title)"
suggested_fix="$(get_field "$out" suggested_fix)"
assert_contains "title: email marker present" "$title" "[email]"
assert_not_contains "title: raw address gone" "$title" "admin@example.com"
assert_contains "suggested_fix: key marker present" "$suggested_fix" "[key]"
assert_not_contains "suggested_fix: raw key gone" "$suggested_fix" "sk-abcdefghijklmnopqrstuvwxyz1234"

d="$(next_dir)"
out="$(PAPERCUT_DENYLIST="$no_denylist" run_gate "$d" \
  '{"category":"harness_config","severity":"low","title":"t","description":"the server at 10.20.30.40 is unreachable"}' \
  --source manual --producer test/1 --repo dotfiles)"
desc="$(get_field "$out" description)"
assert_contains "IPv4: marker present" "$desc" "[ip]"
assert_not_contains "IPv4: raw address gone" "$desc" "10.20.30.40"

d="$(next_dir)"
out="$(PAPERCUT_DENYLIST="$no_denylist" run_gate "$d" \
  '{"category":"harness_config","severity":"low","title":"t","description":"the host resolves to 2001:0db8:85a3:0000:0000:8a2e:0370:7334 now"}' \
  --source manual --producer test/1 --repo dotfiles)"
desc="$(get_field "$out" description)"
assert_contains "IPv6: marker present" "$desc" "[ip]"
assert_not_contains "IPv6: raw address gone" "$desc" "2001:0db8:85a3:0000:0000:8a2e:0370:7334"

# Regression: a COMPRESSED IPv6 (with "::") must be redacted WHOLE. A prior
# hand-rolled alternation matched only the "2001:db8:85a3::" prefix and leaked
# the "8a2e:370:7334" tail; the ipaddress-validated scan redacts it entirely.
d="$(next_dir)"
out="$(PAPERCUT_DENYLIST="$no_denylist" run_gate "$d" \
  '{"category":"harness_config","severity":"low","title":"t","description":"peer 2001:db8:85a3::8a2e:370:7334 and mapped ::ffff:192.0.2.128 seen"}' \
  --source manual --producer test/1 --repo dotfiles)"
desc="$(get_field "$out" description)"
assert_not_contains "IPv6 compressed: no tail leak" "$desc" "8a2e:370:7334"
assert_not_contains "IPv6 compressed: no prefix leak" "$desc" "2001:db8:85a3"
assert_not_contains "IPv6 mapped: no embedded IPv4 leak" "$desc" "192.0.2.128"

# Regression: an IPv6 glued directly after a delimiter colon with no space
# (e.g. "IP:2001:db8::1") must still redact. The candidate scan otherwise
# absorbs the leading ":" into ":2001:db8::1", which fails ipaddress
# validation and leaked the address unredacted.
d="$(next_dir)"
out="$(PAPERCUT_DENYLIST="$no_denylist" run_gate "$d" \
  '{"category":"harness_config","severity":"low","title":"t","description":"see IP:2001:db8::1 for the host"}' \
  --source manual --producer test/1 --repo dotfiles)"
desc="$(get_field "$out" description)"
assert_contains "IPv6 colon-prefixed: marker present" "$desc" "[ip]"
assert_not_contains "IPv6 colon-prefixed: raw address gone" "$desc" "2001:db8::1"

# A bare "HH:MM:SS" time has 2 colons but is NOT a valid IPv6 — must be left
# alone (ipaddress validation prevents this false positive).
d="$(next_dir)"
out="$(PAPERCUT_DENYLIST="$no_denylist" run_gate "$d" \
  '{"category":"harness_config","severity":"low","title":"t","description":"failed at 12:30:45 today"}' \
  --source manual --producer test/1 --repo dotfiles)"
desc="$(get_field "$out" description)"
assert_contains "IPv6 false-positive: time preserved" "$desc" "12:30:45"

d="$(next_dir)"
out="$(PAPERCUT_DENYLIST="$no_denylist" run_gate "$d" \
  '{"category":"harness_config","severity":"low","title":"t","description":"the token is QWERTYUIOPASDFGHJKLZXCVBNM123456 for now"}' \
  --source manual --producer test/1 --repo dotfiles)"
desc="$(get_field "$out" description)"
assert_contains "generic token: marker present" "$desc" "[token]"
assert_not_contains "generic token: raw value gone" "$desc" "QWERTYUIOPASDFGHJKLZXCVBNM123456"

# --- token allowlist: an exact-match safe term survives the >=20-char token rule ---
d="$(next_dir)"
out="$(PAPERCUT_DENYLIST="$no_denylist" run_gate "$d" \
  '{"category":"harness_config","severity":"low","title":"t","description":"verify the path gates on dependency-readiness before claiming"}' \
  --source manual --producer test/1 --repo dotfiles)"
desc="$(get_field "$out" description)"
assert_contains "token allowlist: allowlisted term survives" "$desc" "dependency-readiness"
assert_not_contains "token allowlist: allowlisted term not shredded" "$desc" "[token]"

# --- this repo's own script names survive: they are tracked files, never secrets ---
d="$(next_dir)"
out="$(PAPERCUT_DENYLIST="$no_denylist" run_gate "$d" \
  '{"category":"harness_config","severity":"low","title":"t","description":"the sandbox-network-guard hook fired before merge-claude-settings ran"}' \
  --source manual --producer test/1 --repo dotfiles)"
desc="$(get_field "$out" description)"
assert_contains "token allowlist: sandbox-network-guard survives" "$desc" "sandbox-network-guard"
assert_contains "token allowlist: merge-claude-settings survives" "$desc" "merge-claude-settings"
assert_not_contains "token allowlist: repo script names not shredded" "$desc" "[token]"

# --- the sandbox refusal string survives alongside a real token in the same record ---
d="$(next_dir)"
out="$(PAPERCUT_DENYLIST="$no_denylist" run_gate "$d" \
  '{"category":"harness_config","severity":"low","title":"t","description":"the prune failed with Operation-not-permitted, an operation-not-permitted denial; ghp_A1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q7r8 was in the log"}' \
  --source manual --producer test/1 --repo dotfiles)"
desc="$(get_field "$out" description)"
assert_contains "token allowlist: Operation-not-permitted survives" "$desc" "Operation-not-permitted"
assert_contains "token allowlist: lowercase operation-not-permitted survives" "$desc" "an operation-not-permitted denial"
assert_not_contains "token allowlist: real token beside it still redacted" "$desc" "ghp_A1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q7r8"

# --- a hyphenated run NOT on the allowlist is still redacted (exact-match, not "any hyphenated word") ---
d="$(next_dir)"
out="$(PAPERCUT_DENYLIST="$no_denylist" run_gate "$d" \
  '{"category":"harness_config","severity":"low","title":"t","description":"passphrase correct-horse-battery-staple-lock here"}' \
  --source manual --producer test/1 --repo dotfiles)"
desc="$(get_field "$out" description)"
assert_contains "token allowlist: non-listed hyphenated run still redacted" "$desc" "[token]"
assert_not_contains "token allowlist: hyphenated passphrase gone" "$desc" "correct-horse-battery-staple-lock"

# --- user check: a vocabulary-shaped redaction (lowercase hyphenated words) is surfaced on stderr ---
d="$(next_dir)"
out="$(PAPERCUT_DENYLIST="$no_denylist" run_gate "$d" \
  '{"category":"harness_config","severity":"low","title":"t","description":"note the phrase backward-compatibility-shim here"}' \
  --source manual --producer test/1 --repo dotfiles 2>"$d/err")"
err="$(cat "$d/err")"
desc="$(get_field "$out" description)"
assert_contains "scrub review: vocab run still redacted in stored record" "$desc" "[token]"
assert_not_contains "scrub review: vocab run not stored raw" "$desc" "backward-compatibility-shim"
assert_contains "scrub review: surfaced on stderr" "$err" "SCRUB_REVIEW"
assert_contains "scrub review: names the redacted term" "$err" "backward-compatibility-shim"

# --- user check: identifier-shaped redactions are surfaced too, not shredded silently ---
# The lowercase-hyphen shape was the only one surfaced originally, so every
# camelCase / snake_case / SCREAMING_SNAKE false positive vanished without a
# trace and the allowlist could never be extended for it.
for vocab_case in \
  'annual_rate_cents_value:snake_case' \
  'GH_TOKEN_FALLBACK_NAME:screaming_snake' \
  'deliberatelyRoutedHandler:camelCase'; do
  term="${vocab_case%%:*}"
  shape="${vocab_case##*:}"
  d="$(next_dir)"
  out="$(PAPERCUT_DENYLIST="$no_denylist" run_gate "$d" \
    "{\"category\":\"harness_config\",\"severity\":\"low\",\"title\":\"t\",\"description\":\"see $term in the trace\"}" \
    --source manual --producer test/1 --repo dotfiles 2>"$d/err")"
  err="$(cat "$d/err")"
  desc="$(get_field "$out" description)"
  assert_contains "scrub review ($shape): still redacted in stored record" "$desc" "[token]"
  assert_contains "scrub review ($shape): surfaced on stderr" "$err" "SCRUB_REVIEW"
  assert_contains "scrub review ($shape): names the redacted term" "$err" "$term"
done

# --- user check: an entropy-bearing token is redacted but NOT surfaced (probable real secret) ---
d="$(next_dir)"
out="$(PAPERCUT_DENYLIST="$no_denylist" run_gate "$d" \
  '{"category":"harness_config","severity":"low","title":"t","description":"the token is QWERTYUIOPASDFGHJKLZXCVBNM123456 for now"}' \
  --source manual --producer test/1 --repo dotfiles 2>"$d/err")"
err="$(cat "$d/err")"
assert_not_contains "scrub review: entropy token not surfaced" "$err" "SCRUB_REVIEW"

# --- user check: the plaintext advisory is MANUAL-ONLY, never on the auto path ---
# papercut-capture.sh captures the gate's stderr (to catch the bounded
# SCRUB_REVIEW_WRITE_FAILED marker), so an advisory printed on --source auto
# would spill the redacted runs verbatim into a temp file on every automated
# capture. The sidecar is the auto path's retention mechanism; stderr is not.
d="$(next_dir)"
out="$(PAPERCUT_DENYLIST="$no_denylist" run_gate "$d" \
  '{"category":"harness_config","severity":"low","title":"t","description":"note the phrase backward-compatibility-shim here"}' \
  --source auto --producer test/1 --repo dotfiles 2>"$d/err")"
err="$(cat "$d/err")"
desc="$(get_field "$out" description)"
assert_contains "scrub review (auto): vocab run still redacted in stored record" "$desc" "[token]"
assert_not_contains "scrub review (auto): advisory not printed" "$err" "SCRUB_REVIEW"
assert_not_contains "scrub review (auto): redacted term never hits stderr" "$err" "backward-compatibility-shim"

# --- user check: an allowlisted term is neither redacted nor surfaced ---
d="$(next_dir)"
out="$(PAPERCUT_DENYLIST="$no_denylist" run_gate "$d" \
  '{"category":"harness_config","severity":"low","title":"t","description":"gates on dependency-readiness first"}' \
  --source manual --producer test/1 --repo dotfiles 2>"$d/err")"
err="$(cat "$d/err")"
assert_not_contains "scrub review: allowlisted term not surfaced" "$err" "SCRUB_REVIEW"

for prefix_case in \
  'sk-abcdefghijklmnopqrstuvwxyz1234:sk- key' \
  'ghp_abcdefghijklmnopqrstuvwxyz1234:ghp_ key' \
  'github_pat_abcdefghijklmnopqrstuvwxyz1234:github_pat_ key' \
  'xoxb-abcdefghijklmnopqrstuvwxyz1234:xox key' \
  'AKIAIOSFODNN7EXAMPLE:AKIA key'
do
  secret="${prefix_case%%:*}"
  label="${prefix_case#*:}"
  d="$(next_dir)"
  out="$(PAPERCUT_DENYLIST="$no_denylist" run_gate "$d" \
    "{\"category\":\"harness_config\",\"severity\":\"low\",\"title\":\"t\",\"description\":\"the key is $secret please rotate\"}" \
    --source manual --producer test/1 --repo dotfiles)"
  desc="$(get_field "$out" description)"
  assert_contains "$label: marker present" "$desc" "[key]"
  assert_not_contains "$label: raw value gone" "$desc" "$secret"
done

d="$(next_dir)"
out="$(PAPERCUT_DENYLIST="$no_denylist" run_gate "$d" \
  '{"category":"harness_config","severity":"low","title":"t","description":"bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PYE9oqYA9E7A used"}' \
  --source manual --producer test/1 --repo dotfiles)"
desc="$(get_field "$out" description)"
assert_contains "JWT: marker present" "$desc" "[jwt]"
assert_not_contains "JWT: raw header segment gone" "$desc" "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"

pem_payload="$(python3 -c '
import json
desc = "key follows:\n-----BEGIN PRIVATE KEY-----\nMIIBVQIBADANBgkqhkiG9w0BAQEFAASCAT8wggE7AgEAAkEAy0abcdefghijkl\n-----END PRIVATE KEY-----\ndone"
print(json.dumps({"category": "harness_config", "severity": "low", "title": "t", "description": desc}))
')"
d="$(next_dir)"
out="$(PAPERCUT_DENYLIST="$no_denylist" run_gate "$d" "$pem_payload" --source manual --producer test/1 --repo dotfiles)"
desc="$(get_field "$out" description)"
assert_contains "PEM block: marker present" "$desc" "[pem-block]"
assert_not_contains "PEM block: raw body gone" "$desc" "MIIBVQIBADANBgkqhkiG9w0BAQEFAASCAT8wggE7AgEAAkEAy0abcdefghijkl"

d="$(next_dir)"
out="$(PAPERCUT_DENYLIST="$no_denylist" run_gate "$d" \
  '{"category":"harness_config","severity":"low","title":"t","description":"login at https://svcuser:hunter2pw@internal.example.com/api works"}' \
  --source manual --producer test/1 --repo dotfiles)"
desc="$(get_field "$out" description)"
assert_not_contains "creds-in-URL: credential gone" "$desc" "svcuser:hunter2pw"
assert_contains "creds-in-URL: host preserved" "$desc" "internal.example.com"

d="$(next_dir)"
out="$(PAPERCUT_DENYLIST="$no_denylist" run_gate "$d" \
  '{"category":"harness_config","severity":"low","title":"t","description":"see /Users/janedoe/src/project/notes.md for details"}' \
  --source manual --producer test/1 --repo dotfiles)"
desc="$(get_field "$out" description)"
# shellcheck disable=SC2088  # asserting on the literal ~ the gate wrote, not a path to expand
assert_contains "home path: collapsed to ~" "$desc" "~/src/project/notes.md"
assert_not_contains "home path: username gone" "$desc" "/Users/janedoe"

# --- 11. adversarial corpus: many patterns at once, plus semantic cases the
# regex CANNOT catch on the default profile (repo name, ticket id, person
# name) — those are only caught via the work-profile denylist, not here. ---

adversarial_payload="$(python3 -c '
import json
desc = (
    "Internal repo bestdan/starship-secrets, ticket ENG-1234, opened by Jane Smith.\n"
    "Path /Users/jane/work/notes.txt.\n"
    "Login https://svcuser:pw0rd123@internal.example.com/api.\n"
    "JWT eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0In0.abcdefghijklmnopqrstuvwxyz012345\n"
    "-----BEGIN PRIVATE KEY-----\n"
    "MIIBVQIBADANBgkqhkiG9w0BAQEFAASCAT8wggE7AgEAAkEAy0abcdefghijkl\n"
    "-----END PRIVATE KEY-----\n"
    "AWS key AKIAIOSFODNN7EXAMPLE\n"
    "IPv6 2001:0db8::1"
)
print(json.dumps({"category": "harness_config", "severity": "low", "title": "adv", "description": desc}))
')"
d="$(next_dir)"
out="$(PAPERCUT_DENYLIST="$no_denylist" run_gate "$d" "$adversarial_payload" --source manual --producer test/1 --repo dotfiles)"
desc="$(get_field "$out" description)"
assert_contains "adversarial: PEM marker present" "$desc" "[pem-block]"
assert_not_contains "adversarial: PEM body gone" "$desc" "MIIBVQIBADANBgkqhkiG9w0BAQEFAASCAT8wggE7AgEAAkEAy0abcdefghijkl"
assert_contains "adversarial: JWT marker present" "$desc" "[jwt]"
assert_not_contains "adversarial: JWT body gone" "$desc" "eyJzdWIiOiIxMjM0In0"
assert_not_contains "adversarial: home path gone" "$desc" "/Users/jane"
# shellcheck disable=SC2088  # asserting on the literal ~ the gate wrote, not a path to expand
assert_contains "adversarial: home path collapsed" "$desc" "~/work/notes.txt"
assert_not_contains "adversarial: URL creds gone" "$desc" "svcuser:pw0rd123"
assert_contains "adversarial: URL host preserved" "$desc" "internal.example.com"
assert_contains "adversarial: AWS key marker present" "$desc" "[key]"
assert_not_contains "adversarial: AWS key raw value gone" "$desc" "AKIAIOSFODNN7EXAMPLE"
assert_contains "adversarial: IPv6 marker present" "$desc" "[ip]"
assert_not_contains "adversarial: IPv6 raw value gone" "$desc" "2001:0db8::1"
# NOTE: these are the SEMANTIC cases regex cannot catch on the default
# profile — the repo name, ticket id, and person name all survive here on
# purpose; they are only caught on the strict profile via the denylist match
# in section 13 below.
assert_contains "adversarial: repo name NOT caught by regex (semantic, expected)" "$desc" "starship-secrets"
assert_contains "adversarial: ticket id NOT caught by regex (semantic, expected)" "$desc" "ENG-1234"
assert_contains "adversarial: person name NOT caught by regex (semantic, expected)" "$desc" "Jane Smith"

# --- 12. denylist redaction on the default profile ---

denylist_file="$workdir/denylist_default.txt"
cat >"$denylist_file" <<'EOF'
# example denylist for tests
project-nightingale
EOF
d="$(next_dir)"
out="$(PAPERCUT_DENYLIST="$denylist_file" run_gate "$d" \
  '{"category":"harness_config","severity":"low","title":"t","description":"working on Project-Nightingale rollout today"}' \
  --source manual --producer test/1 --repo dotfiles)"
rc=$?
assert_eq "default profile denylist match: still exits 0 (redacted, not rejected)" "0" "$rc"
desc="$(get_field "$out" description)"
assert_contains "default profile denylist: redacted marker present" "$desc" "[redacted]"
assert_not_contains "default profile denylist: literal gone (case-insensitive)" "$desc" "Nightingale"
lines="$(wc -l < "$d/spool.jsonl" | tr -d ' ')"
assert_eq "default profile denylist match: record still appended" "1" "$lines"

# --- 13. strict profile fails closed, TWICE ---

# (i) missing denylist file entirely -> reject
d="$(next_dir)"
PAPERCUT_DENYLIST="$workdir/does-not-exist.txt" PAPERCUT_FAKE_HOST=WORK-LAPTOP-01 \
  run_gate "$d" '{"category":"harness_config","severity":"low","title":"t","description":"benign text"}' \
  --source manual --producer test/1 >"$d"/wf_missing_out 2>"$d"/wf_missing_err
rc=$?
assert_eq "strict profile: missing denylist exits 1" "1" "$rc"
assert_contains "strict profile: missing denylist error message" "$(cat "$d"/wf_missing_err)" "scrub rejected"
assert_true "strict profile: missing denylist appends nothing" "$([ ! -s "$d/spool.jsonl" ] && echo 1 || echo 0)"

# (ii) present but empty (all comments/blank) -> reject
empty_denylist="$workdir/denylist_empty.txt"
cat >"$empty_denylist" <<'EOF'
# just comments here

EOF
chmod 0600 "$empty_denylist"
d="$(next_dir)"
PAPERCUT_DENYLIST="$empty_denylist" PAPERCUT_FAKE_HOST=WORK-LAPTOP-01 \
  run_gate "$d" '{"category":"harness_config","severity":"low","title":"t","description":"benign text"}' \
  --source manual --producer test/1 >"$d"/wf_empty_out 2>"$d"/wf_empty_err
rc=$?
assert_eq "strict profile: empty/all-comment denylist exits 1" "1" "$rc"
assert_true "strict profile: empty denylist appends nothing" "$([ ! -s "$d/spool.jsonl" ] && echo 1 || echo 0)"

# (iii) present, non-empty, but world-readable -> reject
world_readable_denylist="$workdir/denylist_world_readable.txt"
printf 'topsecret\n' >"$world_readable_denylist"
chmod 0644 "$world_readable_denylist"
d="$(next_dir)"
PAPERCUT_DENYLIST="$world_readable_denylist" PAPERCUT_FAKE_HOST=WORK-LAPTOP-01 \
  run_gate "$d" '{"category":"harness_config","severity":"low","title":"t","description":"benign text"}' \
  --source manual --producer test/1 >"$d"/wf_worldread_out 2>"$d"/wf_worldread_err
rc=$?
assert_eq "strict profile: world-readable denylist exits 1" "1" "$rc"
assert_true "strict profile: world-readable denylist appends nothing" "$([ ! -s "$d/spool.jsonl" ] && echo 1 || echo 0)"

# (iv) valid denylist, but the record's PRE-redaction text matches a
# literal -> the WHOLE record is rejected, not redacted
good_denylist="$workdir/denylist_good.txt"
printf 'topsecret\n' >"$good_denylist"
chmod 0600 "$good_denylist"
d="$(next_dir)"
PAPERCUT_DENYLIST="$good_denylist" PAPERCUT_FAKE_HOST=WORK-LAPTOP-01 \
  run_gate "$d" '{"category":"harness_config","severity":"low","title":"t","description":"this is topsecret stuff"}' \
  --source manual --producer test/1 >"$d"/wf_match_out 2>"$d"/wf_match_err
rc=$?
assert_eq "strict profile: pre-redaction denylist match exits 1" "1" "$rc"
assert_contains "strict profile: pre-redaction match error message" "$(cat "$d"/wf_match_err)" "scrub rejected"
assert_true "strict profile: pre-redaction denylist match appends nothing" "$([ ! -s "$d/spool.jsonl" ] && echo 1 || echo 0)"

# sanity: a valid, non-matching denylist on the strict profile still lets a
# clean record through (proves the fail-closed checks aren't over-broad)
d="$(next_dir)"
out="$(PAPERCUT_DENYLIST="$good_denylist" PAPERCUT_FAKE_HOST=WORK-LAPTOP-01 run_gate "$d" \
  '{"category":"harness_config","severity":"low","title":"t","description":"nothing sensitive here"}' \
  --source manual --producer test/1)"
rc=$?
assert_eq "strict profile: valid denylist + clean record still exits 0" "0" "$rc"
lines="$(wc -l < "$d/spool.jsonl" | tr -d ' ')"
assert_eq "strict profile: valid denylist + clean record appended" "1" "$lines"

# --- 14. post-scrub revalidation/truncation: redaction markers can grow a
# field (a short match like "a@b.co" (6 chars) becomes "[email]" (7 chars));
# many such matches can push description over its 1000-char schema max, so
# truncate_to_schema() must clamp it back down BEFORE revalidate. ---

near_limit_payload="$(python3 -c '
import json
desc = "a@b.co " * 142  # 994 raw chars; each match grows by 1 char on redaction
print(json.dumps({"category": "harness_config", "severity": "low", "title": "t", "description": desc}))
')"
d="$(next_dir)"
out="$(PAPERCUT_DENYLIST="$no_denylist" run_gate "$d" "$near_limit_payload" --source manual --producer test/1 --repo dotfiles)"
rc=$?
assert_eq "truncation: record with growth-inducing redaction still exits 0" "0" "$rc"
desc="$(get_field "$out" description)"
desc_len="$(printf '%s' "$desc" | wc -c | tr -d ' ')"
assert_true "truncation: description length <= 1000 after scrub" "$([ "$desc_len" -le 1000 ] && echo 1 || echo 0)"
lines="$(wc -l < "$d/spool.jsonl" | tr -d ' ')"
assert_eq "truncation: record still appended (not rejected)" "1" "$lines"
# --- 15. the strict guard is NOT downgradeable by the environment: with a
# strict hostname in effect, legacy override env vars must be ignored so the
# profile stays "strict" and repo/session_id are still dropped. (A valid
# denylist is supplied because the implemented scrub stage fails closed on the
# strict profile without one; this test is about the guard, not the denylist.) ---
d="$(next_dir)"
out="$(PAPERCUT_DENYLIST="$strict_smoke_denylist" PAPERCUT_FAKE_HOST=WORK-LAPTOP-01 PAPERCUT_HOSTNAME=some-laptop PAPERCUT_TEST_MODE=1 \
  run_gate "$d" '{"category":"harness_config","severity":"low","title":"t10","description":"d10"}' \
  --source manual --producer test/1 --repo dotfiles --session-id sess-123)"
if printf '%s' "$out" | python3 -c '
import json, sys
rec = json.loads(sys.stdin.read())
assert rec["machine"] == "strict"
assert "repo" not in rec
assert "session_id" not in rec
' 2>"$workdir/downgrade_err"; then
  printf 'ok   (strict host stays strict; PAPERCUT_HOSTNAME/PAPERCUT_TEST_MODE env ignored)\n'
else
  printf 'FAIL (guard downgradeable by env: %s | out=%q)\n' "$(cat "$workdir/downgrade_err")" "$out"
  fail=1
fi

# --- 16. array all-or-nothing: one invalid record aborts the whole batch,
# nothing is appended, exit 1. ---
d="$(next_dir)"
run_gate "$d" '[{"category":"harness_config","severity":"low","title":"good","description":"ok"},{"category":"harness_config","severity":"nonsense","title":"bad","description":"no"}]' \
  --source auto --producer test/1 --repo dotfiles >/dev/null 2>&1
rc=$?
assert_eq "array with one bad record exits 1" "1" "$rc"
assert_true "array with one bad record appends nothing" "$([ ! -s "$d/spool.jsonl" ] && echo 1 || echo 0)"

# =============================================================================
# 17. Resolution record type (--type resolution)
# =============================================================================

resolves_id="pc_00000000-0000-4000-8000-000000000000"

# --- valid resolution appends ---
d="$(next_dir)"
out="$(run_gate "$d" "{\"resolves\":\"$resolves_id\",\"status\":\"fixed\",\"fix_url\":\"https://github.com/x/y/commit/abc123\"}" \
  --source manual --producer test/1 --type resolution)"
rc=$?
assert_eq "valid resolution exits 0" "0" "$rc"
if printf '%s' "$out" | python3 -c '
import json, sys
rec = json.loads(sys.stdin.read())
assert rec["type"] == "resolution"
assert rec["resolves"] == "'"$resolves_id"'"
assert rec["status"] == "fixed"
assert rec["fix_url"] == "https://github.com/x/y/commit/abc123"
assert "category" not in rec
' 2>"$workdir"/resolution_ok_err; then
  printf 'ok   (valid resolution: fields set correctly, no descriptive keys)\n'
else
  printf 'FAIL (valid resolution: %s | out=%q)\n' "$(cat "$workdir"/resolution_ok_err)" "$out"
  fail=1
fi
lines="$(wc -l < "$d/spool.jsonl" | tr -d ' ')"
assert_eq "valid resolution appends exactly one line" "1" "$lines"

# --- type defaults to papercut when --type omitted (existing behavior) ---
d="$(next_dir)"
out="$(run_gate "$d" '{"category":"harness_config","severity":"low","title":"t","description":"d"}' \
  --source manual --producer test/1 --repo dotfiles)"
rc=$?
assert_eq "type-omitted record still exits 0" "0" "$rc"
type_field="$(get_field "$out" type)"
assert_eq "type defaults to papercut when --type omitted" "papercut" "$type_field"

# --- resolution missing resolves/status fails ---
d="$(next_dir)"
run_gate "$d" '{"fix_url":"https://example.com/x"}' \
  --source manual --producer test/1 --type resolution >/dev/null 2>"$workdir"/resolution_missing_err
rc=$?
assert_eq "resolution missing resolves/status exits 1" "1" "$rc"
assert_true "resolution missing resolves/status appends nothing" "$([ ! -s "$d/spool.jsonl" ] && echo 1 || echo 0)"

# --- papercut record carrying resolves/status/fix_url fails ---
d="$(next_dir)"
out="$(PAPERCUT_SPOOL="$d/spool.jsonl" PAPERCUT_LOCK="$d/.spool.lock" python3 -c '
import sys
sys.path.insert(0, "'"$(dirname "$gate")"'")
import papercut_append as pa
schema = pa.load_schema()
rec = {
    "id": "pc_00000000-0000-4000-8000-000000000001",
    "v": 1,
    "type": "papercut",
    "producer": "test/1",
    "ts": "2026-01-01T00:00:00Z",
    "machine": "default",
    "source": "manual",
    "category": "harness_config",
    "severity": "low",
    "title": "t",
    "description": "d",
    "repo": "dotfiles",
    "resolves": "pc_00000000-0000-4000-8000-000000000000",
    "status": "fixed",
}
ok, reason = pa.validate_record(rec, schema)
print("REJECTED" if not ok else "ACCEPTED", reason)
')"
assert_true "papercut carrying resolves/status is rejected" "$(printf '%s' "$out" | grep -q '^REJECTED' && echo 1 || echo 0)"

# --- resolution carrying category/title fails (schema-level: the gate's own
# extract_descriptive() would silently drop these on a real invocation, so
# this exercises validate_record() directly, same pattern as the
# "papercut carrying resolves/status" case above) ---
d="$(next_dir)"
out="$(PAPERCUT_SPOOL="$d/spool.jsonl" PAPERCUT_LOCK="$d/.spool.lock" python3 -c '
import sys
sys.path.insert(0, "'"$(dirname "$gate")"'")
import papercut_append as pa
schema = pa.load_schema()
rec = {
    "id": "pc_00000000-0000-4000-8000-000000000002",
    "v": 1,
    "type": "resolution",
    "producer": "test/1",
    "ts": "2026-01-01T00:00:00Z",
    "machine": "default",
    "source": "manual",
    "resolves": "pc_00000000-0000-4000-8000-000000000000",
    "status": "fixed",
    "category": "harness_config",
    "title": "t",
}
ok, reason = pa.validate_record(rec, schema)
print("REJECTED" if not ok else "ACCEPTED", reason)
')"
assert_true "resolution carrying category/title is rejected" "$(printf '%s' "$out" | grep -q '^REJECTED' && echo 1 || echo 0)"

# --- fix_url with a 40-hex commit SHA survives UNshredded (no [token]) ---
d="$(next_dir)"
out="$(PAPERCUT_DENYLIST="$no_denylist" run_gate "$d" \
  "{\"resolves\":\"$resolves_id\",\"status\":\"fixed\",\"fix_url\":\"https://github.com/bestdan/dotfiles/commit/0123456789abcdef0123456789abcdef01234567\"}" \
  --source manual --producer test/1 --type resolution)"
fix_url="$(get_field "$out" fix_url)"
assert_not_contains "fix_url commit SHA: not shredded by token rule" "$fix_url" "[token]"
assert_contains "fix_url commit SHA: SHA preserved" "$fix_url" "0123456789abcdef0123456789abcdef01234567"

# --- fix_url with embedded credentials gets the creds-in-URL redaction while
#     a SHA in the same URL survives (default profile, no denylist) ---
d="$(next_dir)"
out="$(PAPERCUT_DENYLIST="$no_denylist" run_gate "$d" \
  "{\"resolves\":\"$resolves_id\",\"status\":\"fixed\",\"fix_url\":\"https://user:s3cr3ttoken@github.com/bestdan/dotfiles/commit/0123456789abcdef0123456789abcdef01234567\"}" \
  --source manual --producer test/1 --type resolution)"
fix_url="$(get_field "$out" fix_url)"
assert_contains "fix_url creds: user:pass@ redacted" "$fix_url" "[redacted]@"
assert_not_contains "fix_url creds: token gone" "$fix_url" "s3cr3ttoken"
assert_contains "fix_url creds: SHA still preserved" "$fix_url" "0123456789abcdef0123456789abcdef01234567"

# --- bad fix_url (non-http) fails validation ---
d="$(next_dir)"
run_gate "$d" "{\"resolves\":\"$resolves_id\",\"status\":\"fixed\",\"fix_url\":\"not-a-url\"}" \
  --source manual --producer test/1 --type resolution >/dev/null 2>"$workdir"/resolution_badurl_err
rc=$?
assert_eq "bad fix_url exits 1" "1" "$rc"
assert_true "bad fix_url appends nothing" "$([ ! -s "$d/spool.jsonl" ] && echo 1 || echo 0)"

# --- strict: denylist literal in fix_url rejects the record ---
d="$(next_dir)"
PAPERCUT_DENYLIST="$good_denylist" PAPERCUT_FAKE_HOST=WORK-LAPTOP-01 \
  run_gate "$d" "{\"resolves\":\"$resolves_id\",\"status\":\"fixed\",\"fix_url\":\"https://example.com/topsecret\"}" \
  --source manual --producer test/1 --type resolution >/dev/null 2>"$workdir"/resolution_strict_deny_err
rc=$?
assert_eq "strict: denylist literal in fix_url exits 1" "1" "$rc"
assert_contains "strict: denylist literal in fix_url error message" "$(cat "$workdir"/resolution_strict_deny_err)" "scrub rejected"
assert_true "strict: denylist literal in fix_url appends nothing" "$([ ! -s "$d/spool.jsonl" ] && echo 1 || echo 0)"

# --- strict: strips session_id/repo from a resolution too (resolution
# has neither field to begin with, but confirm the machine profile itself
# still resolves to strict and the record appends) ---
d="$(next_dir)"
out="$(PAPERCUT_DENYLIST="$strict_smoke_denylist" PAPERCUT_FAKE_HOST=WORK-LAPTOP-01 \
  run_gate "$d" "{\"resolves\":\"$resolves_id\",\"status\":\"mitigated\"}" \
  --source manual --producer test/1 --type resolution --repo secret-repo --session-id sess-1)"
rc=$?
assert_eq "strict resolution exits 0" "0" "$rc"
if printf '%s' "$out" | python3 -c '
import json, sys
rec = json.loads(sys.stdin.read())
assert rec["machine"] == "strict"
assert "repo" not in rec
assert "session_id" not in rec
' 2>"$workdir"/resolution_strict_strip_err; then
  printf 'ok   (strict resolution: repo/session_id stripped)\n'
else
  printf 'FAIL (strict resolution strip: %s | out=%q)\n' "$(cat "$workdir"/resolution_strict_strip_err)" "$out"
  fail=1
fi

# --- default: denylist literal in fix_url gets redacted (not rejected) ---
d="$(next_dir)"
out="$(PAPERCUT_DENYLIST="$denylist_file" run_gate "$d" \
  "{\"resolves\":\"$resolves_id\",\"status\":\"fixed\",\"fix_url\":\"https://example.com/project-nightingale/notes\"}" \
  --source manual --producer test/1 --type resolution)"
rc=$?
assert_eq "default: denylist literal in fix_url still exits 0" "0" "$rc"
fix_url="$(get_field "$out" fix_url)"
assert_contains "default: denylist literal in fix_url redacted marker present" "$fix_url" "[redacted]"
assert_not_contains "default: denylist literal in fix_url literal gone" "$fix_url" "nightingale"
lines="$(wc -l < "$d/spool.jsonl" | tr -d ' ')"
assert_eq "default: denylist literal in fix_url record still appended" "1" "$lines"

# =============================================================================
# 18. Scrub-review sidecar (PAPERCUT_REVIEW_FILE) — reconstructs a
# vocab-shaped redaction's plaintext for later human review, since the auto
# capture path discards the pre-existing stderr advisory.
# =============================================================================

review_no_denylist="$workdir/no-such-denylist-review.txt"

# --- sidecar line written with correct shape on a vocab-shaped redaction ---
d="$(next_dir)"
review_file="$d/scrub-review.jsonl"
out="$(PAPERCUT_DENYLIST="$review_no_denylist" PAPERCUT_REVIEW_FILE="$review_file" run_gate "$d" \
  '{"category":"harness_config","severity":"low","title":"t","description":"note the phrase backward-compatibility-shim here"}' \
  --source manual --producer test/1 --repo dotfiles)"
record_id="$(get_field "$out" id)"
if [ -s "$review_file" ] && python3 -c '
import json, re, sys
with open(sys.argv[1]) as f:
    lines = [l for l in f if l.strip()]
assert len(lines) == 1, lines
entry = json.loads(lines[0])
assert set(entry.keys()) == {"ts", "record_id", "runs"}, entry
assert entry["record_id"] == sys.argv[2], entry
assert entry["runs"] == ["backward-compatibility-shim"], entry
assert re.match(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$", entry["ts"])
' "$review_file" "$record_id" 2>"$workdir/review_shape_err"; then
  printf 'ok   (scrub-review sidecar: one line, correct shape, verbatim run)\n'
else
  printf 'FAIL (scrub-review sidecar shape: %s | file=%s)\n' "$(cat "$workdir/review_shape_err")" "$(cat "$review_file" 2>/dev/null)"
  fail=1
fi

# --- sidecar file/dir perms are 0600/0700 (dir must not pre-exist: the gate
# itself must create it, like the spool dir test above) ---
d="$(next_dir)"
review_dir="$d/review_dir"
review_file="$review_dir/scrub-review.jsonl"
PAPERCUT_DENYLIST="$review_no_denylist" PAPERCUT_REVIEW_FILE="$review_file" run_gate "$d" \
  '{"category":"harness_config","severity":"low","title":"t","description":"note the phrase backward-compatibility-shim here"}' \
  --source manual --producer test/1 --repo dotfiles >/dev/null
review_dir_perm="$(stat -c '%a' "$review_dir" 2>/dev/null || stat -f '%Lp' "$review_dir")"
review_file_perm="$(stat -c '%a' "$review_file" 2>/dev/null || stat -f '%Lp' "$review_file")"
assert_eq "scrub-review sidecar dir is 0700" "700" "$review_dir_perm"
assert_eq "scrub-review sidecar file is 0600" "600" "$review_file_perm"

# --- no sidecar created when PAPERCUT_REVIEW_FILE is unset: the pre-existing
# unchanged-behavior guarantee ---
d="$(next_dir)"
review_file="$d/should-not-exist.jsonl"
PAPERCUT_DENYLIST="$review_no_denylist" run_gate "$d" \
  '{"category":"harness_config","severity":"low","title":"t","description":"note the phrase backward-compatibility-shim here"}' \
  --source manual --producer test/1 --repo dotfiles >/dev/null
assert_true "no PAPERCUT_REVIEW_FILE: no sidecar file created" "$([ ! -e "$review_file" ] && echo 1 || echo 0)"

# --- a non-vocab-shaped redaction (real entropy token) does NOT produce a
# sidecar entry, even with PAPERCUT_REVIEW_FILE set ---
d="$(next_dir)"
review_file="$d/scrub-review.jsonl"
PAPERCUT_DENYLIST="$review_no_denylist" PAPERCUT_REVIEW_FILE="$review_file" run_gate "$d" \
  '{"category":"harness_config","severity":"low","title":"t","description":"the token is QWERTYUIOPASDFGHJKLZXCVBNM123456 for now"}' \
  --source manual --producer test/1 --repo dotfiles >/dev/null
assert_true "entropy token: no sidecar entry written" "$([ ! -s "$review_file" ] && echo 1 || echo 0)"

# --- regression for the sentence-initial-capital fix: a capitalized
# hyphenated run now reaches the sidecar. Uses a term OTHER than the
# already-allowlisted "Closed-without-merge" so the allowlist's exact-match
# short-circuit (which runs before the vocab check) can't mask a regression
# in the regex itself. ---
d="$(next_dir)"
review_file="$d/scrub-review.jsonl"
out="$(PAPERCUT_DENYLIST="$review_no_denylist" PAPERCUT_REVIEW_FILE="$review_file" run_gate "$d" \
  '{"category":"harness_config","severity":"low","title":"t","description":"status was Deferred-without-review at the time"}' \
  --source manual --producer test/1 --repo dotfiles)"
record_id="$(get_field "$out" id)"
if [ -s "$review_file" ] && python3 -c '
import json, sys
with open(sys.argv[1]) as f:
    entry = json.loads(f.readline())
assert entry["record_id"] == sys.argv[2], entry
assert entry["runs"] == ["Deferred-without-review"], entry
' "$review_file" "$record_id" 2>"$workdir/review_cap_err"; then
  printf 'ok   (sentence-initial-capital vocab run now reaches the sidecar)\n'
else
  printf 'FAIL (sentence-initial-capital regression: %s | file=%s)\n' "$(cat "$workdir/review_cap_err")" "$(cat "$review_file" 2>/dev/null)"
  fail=1
fi

# --- sidecar write failure must NEVER fail the append: point
# PAPERCUT_REVIEW_FILE at a path whose parent already exists as a plain FILE
# (not a directory), so os.makedirs() inside write_review_sidecar() raises.
# The record must still land in the spool and the gate must still exit 0. ---
d="$(next_dir)"
blocked_parent="$d/blocked"
: > "$blocked_parent"
review_file="$blocked_parent/scrub-review.jsonl"
PAPERCUT_DENYLIST="$review_no_denylist" PAPERCUT_REVIEW_FILE="$review_file" run_gate "$d" \
  '{"category":"harness_config","severity":"low","title":"t","description":"note the phrase backward-compatibility-shim here"}' \
  --source manual --producer test/1 --repo dotfiles >/dev/null
rc=$?
assert_eq "sidecar write failure: gate still exits 0" "0" "$rc"
lines="$(wc -l < "$d/spool.jsonl" | tr -d ' ')"
assert_eq "sidecar write failure: record still appended" "1" "$lines"

# --- 17-20. detect_machine(): the profile resolver itself. Strictness is a
# MONOTONE UNION of a configured hostname pattern and a marker file whose path
# no config can name. Each case gets its own throwaway HOME, so the marker is
# planted (or absent) in isolation from the developer's real ~/.config. ---
detect_with() {
  # detect_with <home> <config-path-or-empty> <hostname> -> prints the profile.
  # An empty config path means "no config file at all": config_path() then
  # falls back to $HOME/.config/papercuts/config.toml under the throwaway HOME,
  # which does not exist.
  local home="$1" cfg="$2" host="$3"
  HOME="$home" PAPERCUT_CONFIG="$cfg" python3 -c '
import socket, sys
sys.path.insert(0, sys.argv[1])
socket.gethostname = lambda: sys.argv[2]
import papercut_append
print(papercut_append.detect_machine())
' "$(cd "$(dirname "$gate")" && pwd)" "$host"
}

plant_marker() {
  # plant_marker <home> -> creates <home>/.config/papercuts/strict
  mkdir -p "$1/.config/papercuts"
  : >"$1/.config/papercuts/strict"
}

# 17. a hostname matching a strict_hosts pattern resolves strict — with no
# marker anywhere, so the pattern is provably what did it. Both the exact
# uppercase form and a lowercased FQDN form must match (the pre-config
# behavior this replaced was case-insensitive and domain-stripped).
d="$(next_dir)"
assert_eq "strict_hosts pattern match resolves strict" \
  "strict" "$(detect_with "$d" "$strict_hosts_config" WORK-LAPTOP-01)"
assert_eq "strict_hosts pattern match is case-insensitive and domain-stripped" \
  "strict" "$(detect_with "$d" "$strict_hosts_config" work-laptop-01.local)"
assert_eq "non-matching hostname with a config present resolves default" \
  "default" "$(detect_with "$d" "$strict_hosts_config" some-laptop)"

# 18. no pattern match, but the marker is present -> strict. The monotone rule:
# the marker alone is enough, and it is the trigger an operator can use without
# the plugin knowing anything about their employer.
d="$(next_dir)"
plant_marker "$d"
assert_eq "marker present with no matching pattern resolves strict" \
  "strict" "$(detect_with "$d" "$strict_hosts_config" some-laptop)"
assert_eq "marker present with no config file at all resolves strict" \
  "strict" "$(detect_with "$d" "" some-laptop)"

# 19. empty strict_hosts and no marker -> default.
d="$(next_dir)"
empty_hosts_config="$d/config-empty-hosts.toml"
cat >"$empty_hosts_config" <<'EOF'
[profile]
strict_hosts = []
EOF
assert_eq "empty strict_hosts + no marker resolves default" \
  "default" "$(detect_with "$d" "$empty_hosts_config" WORK-LAPTOP-01)"
assert_eq "no config file + no marker resolves default" \
  "default" "$(detect_with "$d" "" WORK-LAPTOP-01)"

# 20. NO config key can relocate the marker. A config that spells keys which
# look like they name the marker path is ignored (they are unknown keys), so a
# machine holding ~/.config/papercuts/strict still resolves strict regardless
# of config contents. This is the monotone-strictness promise: config can only
# ADD strictness, never hide the operator's own declaration.
d="$(next_dir)"
plant_marker "$d"
relocate_config="$d/config-relocate.toml"
cat >"$relocate_config" <<EOF
[profile]
strict_hosts = []
marker = "$d/nonexistent-marker"
strict_marker = "/nonexistent"
marker_path = "/nonexistent"
EOF
assert_eq "no config key relocates the marker: still strict" \
  "strict" "$(detect_with "$d" "$relocate_config" some-laptop)"

# A BROKEN config must not hide the marker either — detect_machine fails
# closed: unreadable patterns become unmatchable, the marker is still checked.
broken_config="$d/config-broken.toml"
printf '[profile\nstrict_hosts = ["WORK-*"]\n' >"$broken_config"
assert_eq "broken config still sees the marker (fails closed)" \
  "strict" "$(detect_with "$d" "$broken_config" some-laptop)"

# --- 21. the SHIPPED schema carries no employer-named value and no `reporter`
# property. The employer name is this migration's residue: the gate can never
# produce it again, so shipping it would be dead vocabulary for every install
# but one and would leak the provenance the rename exists to hide. `reporter`
# was refused outright — extension happens in a ledger repo's own schema copy
# or via the compatibility contract, never speculatively here. ---
schema_file="$(cd "$(dirname "$gate")/../schema" && pwd)/v1.json"
# The name is assembled from two fragments on purpose: this repo's own
# no-employer-name check is `rg -i <name>` over every file, and a suite that
# spelled the name in full to assert its absence would be the one hit.
employer_residue="better""ment"
assert_true "shipped schema has no employer-named value" \
  "$(grep -qi -- "$employer_residue" "$schema_file" && echo 0 || echo 1)"
assert_true "shipped schema has no reporter property" \
  "$(grep -q '"reporter"' "$schema_file" && echo 0 || echo 1)"
assert_true "shipped schema machine enum is exactly default/strict" \
  "$(grep -qF '"enum": ["default", "strict"]' "$schema_file" && echo 1 || echo 0)"

# --- 22. a `strict` record carrying repo or session_id fails validation. The
# gate strips both before it ever validates (section 4/5), so this exercises
# the schema conditional directly — it is the backstop if a future caller path
# ever constructs one. ---
strict_conditional_out="$(python3 -c '
import sys
sys.path.insert(0, sys.argv[1])
import papercut_append as pa
schema = pa.load_schema()
base = {
    "id": "pc_00000000-0000-4000-8000-000000000000",
    "v": 1,
    "type": "papercut",
    "producer": "test/1",
    "ts": "2026-01-01T00:00:00Z",
    "machine": "strict",
    "source": "manual",
    "category": "harness_config",
    "severity": "low",
    "title": "t",
    "description": "d",
}
for extra in ("repo", "session_id"):
    rec = dict(base)
    rec[extra] = "leaky"
    ok, _ = pa.validate_record(rec, schema)
    print(extra, "REJECTED" if not ok else "ACCEPTED")
ok, reason = pa.validate_record(base, schema)
print("bare", "ACCEPTED" if ok else "REJECTED " + str(reason))
' "$(cd "$(dirname "$gate")" && pwd)")"
assert_contains "strict record carrying repo fails validation" "$strict_conditional_out" "repo REJECTED"
assert_contains "strict record carrying session_id fails validation" "$strict_conditional_out" "session_id REJECTED"
assert_contains "strict record with neither still validates" "$strict_conditional_out" "bare ACCEPTED"

exit $fail
