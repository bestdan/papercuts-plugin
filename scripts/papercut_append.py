#!/usr/bin/env python3
"""The trusted gate all papercut records funnel through before hitting disk.

Pipeline is strictly construct -> validate -> scrub -> revalidate -> append.
There are two record types, selected by --type (default "papercut"):
  - papercut: callers (the auto extractor and the manual /papercut skill)
    supply only descriptive fields on stdin (category, severity, title,
    description, suggested_fix?).
  - resolution: callers (papercut-resolve.sh) supply only (resolves, status,
    fix_url?) on stdin — a later record pointing at an earlier papercut's id
    to mark it fixed/mitigated/reported-upstream/wontfix/out-of-scope.
In both cases this script owns every controlled field (id, v, producer, ts,
machine, source, type, session_id, repo) so model output or a caller's JSON
can never spoof identity or provenance. Validation is a hand-rolled,
stdlib-only subset of JSON Schema draft 2020-12 sufficient for
schema/v1.json — not a general validator.

Env overrides (so tests never touch real ~/.claude or ~/.config):
  PAPERCUT_SPOOL     spool JSONL path (default ~/.claude/papercuts/spool.jsonl)
  PAPERCUT_LOCK      flock lock file, separate from the spool, shared with
                     the flusher (default <spool dir>/.spool.lock)
  PAPERCUT_SCHEMA    schema JSON path (default schema/v1.json next to this file)
  PAPERCUT_DENYLIST  per-machine denylist path (default
                     ~/.config/papercuts/denylist.txt); see scrub() below
  PAPERCUT_REVIEW_FILE  scrub-review sidecar path (default: unset, meaning no
                     sidecar is written at all — the pre-existing stderr-only
                     advisory behavior is unchanged). When set, every
                     vocab-shaped redaction (see _VOCAB_RUN_RES) is ALSO
                     appended, verbatim, to this path as one JSON line per
                     record — the automated capture path discards stderr, so
                     without this the advisory is unrecoverable for auto-
                     captured records. See write_review_sidecar() below.

Machine classification (default vs strict) is a MONOTONE UNION of two
triggers: the real hostname matching a configured profile.strict_hosts glob,
or the strict marker file existing (see STRICT_MARKER_PATH). Config can only
ADD strictness; nothing production-settable can remove it, so a real work host
can never be downgraded and a model-composed invocation can't flip the profile
to slip repo/session_id past the strict scrub gate. The hostname itself still
has no env override: tests inject an alternate hostname by monkeypatching
socket.gethostname in-process (see papercut_append.test.sh), never via an env
var a production caller could also set.
"""

import argparse
import fcntl
import fnmatch
import ipaddress
import json
import os
import re
import socket
import sys
import uuid
from datetime import datetime, timezone

DESCRIPTIVE_KEYS = ("category", "severity", "title", "description", "suggested_fix")
RESOLUTION_KEYS = ("resolves", "status", "fix_url")

DENYLIST_PATH = os.path.expanduser(
    os.environ.get("PAPERCUT_DENYLIST", "~/.config/papercuts/denylist.txt")
)

FREE_TEXT_KEYS = ("title", "description", "suggested_fix")
# fix_url is controlled-shape (URL pattern) rather than free text, so it never
# goes through the FULL _redact_builtins (the generic >=20-char token rule would
# shred a commit SHA embedded in the URL). It instead gets _redact_url_safe — the
# same structured-secret patterns MINUS that token rule — so an embedded
# credential/key/JWT/etc. is still stripped while SHAs survive. A denylist literal
# in it also fails-closed on strict / gets redacted on default, same as free
# text, since a URL can carry a codename or repo slug in its path.
DENYLIST_ONLY_KEYS = ("fix_url",)


# The strict-profile marker. An operator declares "records from this machine
# may describe confidential work" with a single `touch`, knowing nothing about
# their employer or this plugin's config format.
#
# HARDCODED, and deliberately unreachable from config, env var, or argument.
# The monotone-strictness promise is that shared, PR-reviewable config can only
# ADD strictness, never remove it from a machine whose operator planted this
# file. A configurable marker PATH breaks exactly that: one config line
# pointing the key at a nonexistent path makes the canonical marker invisible
# and the machine silently resolves "default". The deciding argument is
# POLARITY — a wrong denylist path fails CLOSED (records get rejected), a wrong
# marker path fails OPEN (records get published). So this one path is the thing
# nothing production-settable may move. That also rules out deriving it from
# $XDG_CONFIG_HOME: an environment variable is a production-settable override
# too. profile.strict_hosts stays configurable because it can only add.
STRICT_MARKER_PATH = os.path.expanduser("~/.config/papercuts/strict")

_CONFIG_MODULE = None


def _config_module():
    """Import papercut_config.py from THIS file's directory, by path.

    A bare `import papercut_config` would work in production (the gate is run
    as `python3 .../papercut_append.py`, so its directory is sys.path[0]) but
    not under the test harness, which executes this file via runpy.run_path —
    that puts nothing on sys.path. Loading by explicit path works in both."""
    global _CONFIG_MODULE
    if _CONFIG_MODULE is None:
        import importlib.util

        path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "papercut_config.py")
        spec = importlib.util.spec_from_file_location("papercut_config", path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        _CONFIG_MODULE = module
    return _CONFIG_MODULE


def detect_machine() -> str:
    """Return "strict" or "default" — the pipeline's single profile resolver.

    Strict is a MONOTONE UNION of two independent triggers:
      (a) the real hostname (first dot-separated label, matched
          case-insensitively) matches any profile.strict_hosts glob from the
          config file — the fleet convenience, one config shipped to many
          machines;
      (b) STRICT_MARKER_PATH exists — the primary operator-facing trigger,
          which no config can relocate or suppress.

    The hostname comes from the real system call with no production-settable
    override, so a work host can never be downgraded to "default" (which would
    fail open and let repo/session_id slip past the strict scrub gate). Tests
    drive either profile by monkeypatching socket.gethostname in-process; see
    papercut_append.test.sh.

    FAILS CLOSED. A config file that EXISTS but is broken resolves "strict":
    a fleet machine that is strict only via strict_hosts must not be silently
    downgraded by a truncated or mis-edited config (an absent file is not an
    error — it just means no patterns). Any other unexpected failure also
    resolves "strict" rather than crashing to the permissive profile.

    papercut-flush.sh and extractor-run.sh both call THIS function rather than
    growing their own copy, so the three call sites can never disagree about
    what machine this is."""
    try:
        patterns = _config_module().strict_hosts()
        host = socket.gethostname().split(".", 1)[0].upper()
        if any(fnmatch.fnmatchcase(host, pattern.upper()) for pattern in patterns):
            return "strict"
        # lexists, not exists: a marker that is a dangling symlink is still a
        # human declaration, and exists() would read it as absent (fail open).
        if os.path.lexists(STRICT_MARKER_PATH):
            return "strict"
        return "default"
    except Exception:
        return "strict"


def load_schema() -> dict:
    default_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "schema", "v1.json")
    schema_path = os.environ.get("PAPERCUT_SCHEMA", default_path)
    with open(schema_path, "r", encoding="utf-8") as f:
        return json.load(f)


def _validate_property(value, prop_schema: dict, name: str):
    if prop_schema.get("type") == "string" and not isinstance(value, str):
        return f"{name}: expected string"
    if "const" in prop_schema and value != prop_schema["const"]:
        return f"{name}: must equal {prop_schema['const']!r}"
    if "enum" in prop_schema and value not in prop_schema["enum"]:
        return f"{name}: must be one of {prop_schema['enum']}"
    if "pattern" in prop_schema and not re.fullmatch(prop_schema["pattern"], value):
        return f"{name}: does not match required pattern"
    if "minLength" in prop_schema and len(value) < prop_schema["minLength"]:
        return f"{name}: shorter than minLength {prop_schema['minLength']}"
    if "maxLength" in prop_schema and len(value) > prop_schema["maxLength"]:
        return f"{name}: longer than maxLength {prop_schema['maxLength']}"
    return None


def _if_matches(record: dict, if_schema: dict) -> bool:
    for req in if_schema.get("required", []):
        if req not in record:
            return False
    for prop, prop_schema in if_schema.get("properties", {}).items():
        if prop not in record:
            return False
        if "const" in prop_schema and record[prop] != prop_schema["const"]:
            return False
    return True


def _check_then(record: dict, then_schema: dict):
    for req in then_schema.get("required", []):
        if req not in record:
            return f"conditionally required property missing: {req}"
    not_schema = then_schema.get("not")
    if not_schema:
        for sub in not_schema.get("anyOf", []):
            for req in sub.get("required", []):
                if req in record:
                    return f"conditionally forbidden property present: {req}"
    return None


def validate_record(record: dict, schema: dict):
    """Hand-rolled validation against schema/v1.json. Supports exactly the
    subset of JSON Schema draft 2020-12 this schema uses: type/const/enum/
    pattern/minLength/maxLength/required/additionalProperties:false, plus
    allOf/if/then conditionals (required-if-const and not/anyOf/required).
    Returns (True, None) or (False, reason)."""
    errors = []
    props = schema.get("properties", {})

    if schema.get("additionalProperties") is False:
        for key in record:
            if key not in props:
                errors.append(f"unexpected property: {key}")

    for key in schema.get("required", []):
        if key not in record:
            errors.append(f"missing required property: {key}")

    for key, value in record.items():
        if key in props:
            err = _validate_property(value, props[key], key)
            if err:
                errors.append(err)

    for clause in schema.get("allOf", []):
        if _if_matches(record, clause.get("if", {})):
            err = _check_then(record, clause.get("then", {}))
            if err:
                errors.append(err)

    if errors:
        return False, "; ".join(errors)
    return True, None


class ScrubRejected(Exception):
    """Raised by scrub() to reject a record outright (fail-closed), as
    opposed to redacting it in place. main() catches this separately from a
    validation failure so the failure message makes the distinction clear."""


# --- built-in redaction patterns -------------------------------------------
#
# Substitution ORDER matters — each pattern below is more specific than the
# next, and an earlier, more-generic pattern would otherwise shred the text
# a later, more-specific one is meant to catch as a single unit:
#   1. PEM blocks first: a PEM block is a multiline blob of base64 that the
#      generic >=20-char token rule would otherwise shatter into many
#      unhelpful [token] markers instead of one [pem-block].
#   2. JWTs next, for the same reason — each of the three dot-separated
#      segments is itself a >=20-char base64url run. Redacting the whole
#      eyJ...·...·... blob before the token rule keeps it one [jwt] marker.
#   3. Creds-embedded-in-URLs before the generic token rule: a long password
#      would otherwise get eaten by the token rule, destroying the
#      scheme://user:pass@host structure we need in order to keep the host
#      and only strip the credential.
#   4. Key-prefixed tokens (sk-/ghp_/github_pat_/xox.../AKIA...) before the
#      generic token rule, so these get the more specific [key] marker
#      instead of the token rule eating the alnum suffix and leaving a
#      mangled "sk-[token]" hybrid.
#   5. Email addresses: no overlap with the patterns above or below, order
#      is not load-bearing, but it runs here for readability.
#   6. IPv6 before IPv4: an IPv4-mapped IPv6 address (e.g. ::ffff:192.0.2.1)
#      would otherwise have its embedded IPv4 tail eaten by the IPv4 rule
#      first, leaving a mangled partial IPv6 address behind.
#   7. The generic >=20-char hex/base64 token rule runs last among the
#      "consume a chunk of text" patterns, now that everything more specific
#      has already claimed its matches.
#   8. Home-path collapsing can run anywhere — it only matches `/Users/...`
#      or `/home/...` path text that none of the above touch — so it runs
#      last for simplicity.

_PEM_RE = re.compile(r"-----BEGIN [^-]+-----.*?-----END [^-]+-----", re.DOTALL)
_JWT_RE = re.compile(r"\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b")
_CREDS_URL_RE = re.compile(r"([a-zA-Z][a-zA-Z0-9+.-]*://)([^/@\s:]+):([^/@\s]+)@")
_KEY_RE = re.compile(
    r"\b(?:sk-[A-Za-z0-9]{10,}"
    r"|ghp_[A-Za-z0-9]{10,}"
    r"|github_pat_[A-Za-z0-9_]{10,}"
    r"|xox[a-zA-Z0-9-]{10,}"
    r"|AKIA[A-Z0-9]{12,20})\b"
)
_EMAIL_RE = re.compile(r"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b")
# IPv6 is matched by scanning for candidate runs (hex, colons, and an optional
# trailing dotted-quad for IPv4-mapped forms) and VALIDATING each with stdlib
# ipaddress — a hand-rolled alternation regex silently mis-parses compressed
# forms (e.g. it matched only the "2001:db8:85a3::" prefix of
# "2001:db8:85a3::8a2e:370:7334" and leaked the tail). The candidate must hold
# at least two ":" so bare hex tokens and "scheme:" prefixes aren't considered.
_IPV6_CANDIDATE_RE = re.compile(r"[0-9A-Fa-f:]{2,}(?:\.[0-9]{1,3}){0,3}")


def _redact_ipv6(text: str) -> str:
    def repl(m: "re.Match") -> str:
        s = m.group(0)
        # Peel a lone delimiter colon that a neighboring label glued onto the
        # candidate (e.g. "IP:2001:db8::1" matches ":2001:db8::1"). A single
        # leading/trailing ":" that is NOT part of a "::" group would otherwise
        # fail ipaddress validation and leak the address unredacted.
        lead = trail = ""
        core = s
        if len(core) >= 2 and core[0] == ":" and core[1] != ":":
            lead, core = ":", core[1:]
        if len(core) >= 2 and core[-1] == ":" and core[-2] != ":":
            core, trail = core[:-1], ":"
        if core.count(":") < 2:
            return s
        try:
            ipaddress.ip_address(core)
        except ValueError:
            return s
        return lead + "[ip]" + trail
    return _IPV6_CANDIDATE_RE.sub(repl, text)
_IPV4_RE = re.compile(
    r"\b(?:(?:25[0-5]|2[0-4]\d|1?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|1?\d?\d)\b"
)
# Deliberately EXCLUDES "/" from the charset, even though "/" is a valid
# base64 symbol: including it made this generic rule swallow whole path
# segments and slash-containing repo names (e.g. "bestdan/starship-secrets"
# or "/Users/x/src/project/notes") as one long "token", corrupting text the
# home-path rule and the semantic denylist are supposed to handle instead.
# The tradeoff: a legitimate base64 token containing "/" won't be fully
# caught by this fallback rule — accepted, since the more specific key/JWT/
# creds-in-URL rules above already catch the common structured secret
# formats, and this rule is the last-resort catch-all.
_TOKEN_RE = re.compile(
    r"(?<![A-Za-z0-9+=_-])[A-Za-z0-9+_-]{20,}={0,2}(?![A-Za-z0-9+=_-])"
)
# Exact-match exemptions for the generic >=20-char _TOKEN_RE. The token charset
# includes "-", so any long hyphenated vocabulary term ("dependency-readiness",
# "backward-compatibility", ...) reads as one token and gets shredded to
# [token] even though it carries no secret entropy. Only a WHOLE-run exact match
# against this set is spared — never a substring — so a real secret can never
# slip through by coincidentally containing an allowlisted word. Loosening the
# regex instead was rejected: it would leak diceware-style hyphenated
# passphrases (e.g. "correct-horse-battery-staple"). Add confirmed-safe terms.
_TOKEN_ALLOWLIST = frozenset({
    "dependency-readiness",
    "backward-compatibility",
    "consistency-checking",
    # This repo's own script names, quoted constantly by the sandbox and
    # settings-sync papercuts that are the whole reason those scripts get
    # discussed. Both are tracked files here, so neither can be a secret.
    "sandbox-network-guard",
    "merge-claude-settings",
    # Same script, but suffixed in prose ("a sandbox-network-guard-style hook").
    # The allowlist is whole-run exact-match, so the bare name above doesn't
    # cover the suffixed run — it got shredded in a sandbox papercut.
    "sandbox-network-guard-style",
    # Not hyphenated vocabulary but the same false positive: a 25-char camelCase
    # identifier (the Bash tool's sandbox-escape parameter, which papercuts about
    # sandbox friction quote constantly), which reached the ledger as
    # "unsandboxed with `[token]: true`".
    "dangerouslyDisableSandbox",
    # Plain description of the Write tool's read-before-write guard. Papercuts
    # about near-miss overwrites name it while explaining what caught the
    # mistake, so it reads as vocabulary, not entropy.
    "must-read-before-write",
    # Git merge-state vocabulary. Sentence-initial, so its leading capital used
    # to keep it from matching any _VOCAB_RUN_RES shape — it was redacted with
    # NOTHING on stderr, and only caught by reading the returned record. The
    # first _VOCAB_RUN_RES shape below now allows an optional leading capital,
    # so a run like this would be surfaced today; kept allowlisted since it's
    # already a confirmed-safe term.
    "Closed-without-merge",
    # The sandbox's refusal, hyphenated. The literal OS string ("Operation not
    # permitted") has spaces, so it never forms a single run and was never at
    # risk — what gets shredded is the compressed form papercuts write when
    # naming the condition, e.g. "detect the Operation-not-permitted failure".
    # Losing that to [token] costs the record the one detail that made its
    # suggested fix actionable. Both casings are listed for the same reason
    # sandbox-network-guard-style is: the match is exact, and the lowercase
    # form is the one that appears mid-sentence. A fixed errno message carries
    # no entropy in either casing.
    "Operation-not-permitted",
    "operation-not-permitted",
    # A CLI flag, listed WITH its leading dashes because that is the whole run
    # the token rule sees: the charset includes "-", so the match starts at the
    # first dash and "--skip-git-repo-check" is 21 chars. The bare
    # "skip-git-repo-check" is 19 and never matches at all, so an entry without
    # the dashes would exempt nothing. Named constantly by papercuts about
    # dispatching codex from a non-repo cwd, and it is a published flag of a
    # public CLI, so it carries no entropy.
    "--skip-git-repo-check",
})


# Shapes of a generic-token run that read as technical vocabulary rather than a
# secret. _TOKEN_RE still redacts every one of them — a diceware passphrase like
# "correct-horse-battery-staple" has the exact same shape as the first, so they
# must NEVER be auto-exempted — but a redaction matching one is surfaced to the
# caller on stderr as an allowlist candidate (the "did I just shred a real word?"
# user check).
#
# Every shape below is digit-free by construction. That narrows what reaches
# stderr; it does NOT make it safe to assume only vocabulary gets there. A
# letter-only secret — a diceware passphrase, a letter-only password — matches
# these shapes too and is echoed verbatim. Digit-free is a heuristic, not a
# guarantee.
#
# It is an acceptable heuristic because the exposure is local and bounded: the
# stored record always keeps [token], and the auto capture path discards the
# advisory outright (papercut-capture.sh runs the gate with 2>/dev/null), so
# only the manual path sees it — where the agent reading stderr is the one that
# just passed the plaintext in. Widening these shapes further is what would need
# a harder think, not the digit rule holding the line.
#
# Only the first shape existed originally, which left every identifier-shaped
# false positive — tool names, flag names, env vars, camelCase parameters — to be
# shredded to [token] with nothing on stderr to reveal it had happened. That
# silence is why the same over-redaction recurred after the allowlist was first
# introduced: the allowlist can only be extended for a term someone can see got
# eaten.
_VOCAB_RUN_RES = (
    # Lowercase words joined by hyphens or underscores, the ordinary shape of a
    # script name or an identifier: "sandbox-network-guard", "annual_rate_cents".
    # The first segment allows an optional leading capital ("Closed-without-
    # merge") so a sentence-initial run is still caught — this used to be
    # lowercase-only, which is exactly why "Closed-without-merge" (see
    # _TOKEN_ALLOWLIST above) was once shredded with nothing surfaced on stderr.
    # This also drops the previous 2-letter minimum on that first segment
    # (was `[a-z]{2,}`, now `[a-z]+`), so a single-letter-first run like
    # "a-bc-de" now matches too — intentional, not just a side effect of the
    # capital fix: this shape only decides what gets SURFACED for review, never
    # what gets EXEMPTED from redaction, so widening it further only means more
    # (never fewer) redactions get a human second look.
    #
    # The optional leading "-"/"--"/"_" is the same fix again, for the shapes
    # the comment above already claims to cover: flag names and identifiers.
    # The token charset includes both "-" and "_", so the run handed to
    # _is_vocab_run keeps whatever non-letter it starts with, and a pattern
    # anchored to a letter could never fullmatch it. Every flag name LONG
    # ENOUGH TO REACH the >=20-char token rule was therefore redacted with
    # nothing on stderr — a short flag like "--force" never enters this path at
    # all — which is precisely the silence this tuple exists to end. Found when
    # "--skip-git-repo-check" reached the ledger as "the skill omits [token]".
    #
    # The underscore half is the same defect one character over, fixed here
    # rather than noted, because the only way this silence has ever been caught
    # is by reading an already-mangled record: "no instance observed" was true
    # of flag names too, right up until one was. Verified before fixing that
    # "_SOME_LEADING_UNDERSCORE_NAME" and "_a_private_helper_function" were
    # both redacted and both unsurfaced.
    re.compile(r"(?:--?|_)?[A-Z]?[a-z]+(?:[-_][a-z]{2,})+"),
    # SCREAMING_SNAKE_CASE — overwhelmingly env-var and constant NAMES, which are
    # not themselves secret even when they name a secret: "GH_TOKEN_FALLBACK".
    re.compile(r"_?[A-Z]{2,}(?:_[A-Z]{2,})+"),
    # camelCase / PascalCase identifiers: "dangerouslyDisableSandbox".
    re.compile(r"[a-z]+(?:[A-Z][a-z]+)+|(?:[A-Z][a-z]+){2,}"),
)


def _is_vocab_run(run: str) -> bool:
    """True if the whole run matches one of the benign-vocabulary shapes."""
    return any(shape.fullmatch(run) for shape in _VOCAB_RUN_RES)

_HOME_PATH_RE = re.compile(r"/(?:Users|home)/[^/\s]+")


def _redact_builtins(
    text: str, review: "set | None" = None, record_review: "list | None" = None
) -> str:
    text = _PEM_RE.sub("[pem-block]", text)
    text = _JWT_RE.sub("[jwt]", text)
    text = _CREDS_URL_RE.sub(r"\1[redacted]@", text)
    text = _KEY_RE.sub("[key]", text)
    text = _EMAIL_RE.sub("[email]", text)
    text = _redact_ipv6(text)
    text = _IPV4_RE.sub("[ip]", text)

    def _token_repl(m: "re.Match") -> str:
        # A whole-run exact allowlist match survives; anything else is redacted.
        # Vocabulary-shaped redactions are collected two ways: into the
        # cross-record `review` set for the caller's stderr user check (deduped,
        # unordered), and — when a review sidecar is configured — into
        # `record_review`, a per-record list in occurrence order, verbatim, so a
        # false-positive can be reconstructed later even on the auto path where
        # stderr is discarded (see write_review_sidecar()).
        run = m.group(0)
        if run in _TOKEN_ALLOWLIST:
            return run
        if _is_vocab_run(run):
            if review is not None:
                review.add(run)
            if record_review is not None:
                record_review.append(run)
        return "[token]"

    text = _TOKEN_RE.sub(_token_repl, text)
    text = _HOME_PATH_RE.sub("~", text)
    return text


def _redact_url_safe(text: str) -> str:
    """Redaction pass for DENYLIST_ONLY_KEYS (fix_url) — every structured-secret
    pattern _redact_builtins runs EXCEPT the generic >=20-char _TOKEN_RE and the
    home-path rule. A commit SHA in a URL path is a 40-char hex run that _TOKEN_RE
    would shred (the whole reason fix_url is exempt from _redact_builtins); none of
    the patterns kept here can match a bare SHA, so SHAs survive while an embedded
    credential (scheme://user:token@host), key, JWT, PEM, email, or IP is still
    stripped. _HOME_PATH_RE is skipped too — it targets local /Users//home paths,
    not URL path segments, and would corrupt a legitimate URL path."""
    text = _PEM_RE.sub("[pem-block]", text)
    text = _JWT_RE.sub("[jwt]", text)
    text = _CREDS_URL_RE.sub(r"\1[redacted]@", text)
    text = _KEY_RE.sub("[key]", text)
    text = _EMAIL_RE.sub("[email]", text)
    text = _redact_ipv6(text)
    text = _IPV4_RE.sub("[ip]", text)
    return text


def _read_denylist(path: str) -> list:
    """Return the lowercased, non-comment, non-blank literal lines from the
    denylist file, or [] if it doesn't exist."""
    if not os.path.isfile(path):
        return []
    literals = []
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            literals.append(line.lower())
    return literals


def _denylist_match(text: str, literals: list) -> bool:
    lowered = text.lower()
    return any(lit in lowered for lit in literals)


def _redact_denylist(text: str, literals: list) -> str:
    for lit in literals:
        text = re.compile(re.escape(lit), re.IGNORECASE).sub("[redacted]", text)
    return text


def scrub(
    record: dict,
    profile: str,
    review: "set | None" = None,
    record_review: "list | None" = None,
) -> dict:
    """Redact free-text fields (title/description/suggested_fix) plus the
    denylist-only fix_url field — NEVER enums/ids/other controlled fields.
    Built-in syntactic pattern redaction applies on BOTH profiles: the FULL
    _redact_builtins to FREE_TEXT_KEYS, and the SHA-preserving _redact_url_safe
    (every structured-secret pattern except the generic >=20-char token rule) to
    DENYLIST_ONLY_KEYS (fix_url) — so an embedded credential is stripped while a
    commit SHA the token rule would otherwise shred survives. The per-machine
    denylist read from DENYLIST_PATH ($PAPERCUT_DENYLIST) applies to
    FREE_TEXT_KEYS and DENYLIST_ONLY_KEYS alike.

    `record_review`, when passed, collects this record's own vocab-shaped
    redactions (verbatim, occurrence order) for the scrub-review sidecar — see
    write_review_sidecar(). Only FREE_TEXT_KEYS can produce one: fix_url's
    _redact_url_safe never runs the generic token rule that vocab shapes are
    matched against.

    Default profile: a denylist literal found in free text or fix_url is
    redacted to "[redacted]" (best-effort; a missing/empty denylist is fine
    here, it just means nothing extra gets redacted beyond the built-in
    patterns).

    Strict profile fails closed, TWICE:
      (a) the denylist file must be present, non-empty after stripping
          comments/blank lines, and not world-readable (mode & 0o004) —
          otherwise raise ScrubRejected. This is deliberate: strict-profile
          auto-capture stays inert until the denylist is hand-populated,
          rather than silently shipping unredacted records.
      (b) any record whose PRE-redaction free text OR fix_url matches ANY
          denylist literal raises ScrubRejected for the WHOLE record — it is
          rejected outright, not redacted, so a match can't leak via
          partial context around the redaction.
    Built-in pattern redaction still runs on the strict profile after the
    denylist checks pass.
    """
    record = dict(record)

    if profile == "strict":
        if not os.path.isfile(DENYLIST_PATH):
            raise ScrubRejected(
                f"strict profile requires a denylist at {DENYLIST_PATH}, none found"
            )
        mode = os.stat(DENYLIST_PATH).st_mode
        if mode & 0o004:
            raise ScrubRejected(
                f"denylist at {DENYLIST_PATH} is world-readable; refusing to use it"
            )
        literals = _read_denylist(DENYLIST_PATH)
        if not literals:
            raise ScrubRejected(
                f"denylist at {DENYLIST_PATH} is empty (no literals after stripping comments)"
            )

        for key in FREE_TEXT_KEYS + DENYLIST_ONLY_KEYS:
            if key in record and _denylist_match(record[key], literals):
                raise ScrubRejected(f"{key} matches a denylist literal")

        for key in FREE_TEXT_KEYS:
            if key in record:
                record[key] = _redact_builtins(record[key], review, record_review)
        for key in DENYLIST_ONLY_KEYS:
            if key in record:
                record[key] = _redact_url_safe(record[key])
        return record

    # default profile: built-in redaction always (FREE_TEXT_KEYS via
    # _redact_builtins, DENYLIST_ONLY_KEYS via the SHA-preserving
    # _redact_url_safe); denylist redaction is best-effort (the file may not
    # exist at all on a default-profile machine) and applies to both key sets.
    literals = _read_denylist(DENYLIST_PATH)
    for key in FREE_TEXT_KEYS:
        if key in record:
            text = _redact_builtins(record[key], review, record_review)
            if literals:
                text = _redact_denylist(text, literals)
            record[key] = text
    for key in DENYLIST_ONLY_KEYS:
        if key in record:
            text = _redact_url_safe(record[key])
            if literals:
                text = _redact_denylist(text, literals)
            record[key] = text
    return record


def truncate_to_schema(record: dict, schema: dict) -> dict:
    """Truncate free-text fields to their schema maxLength BEFORE revalidate,
    so a redaction marker (e.g. "[pem-block]") can never push a field over
    its schema limit and turn an otherwise-valid record invalid."""
    props = schema.get("properties", {})
    record = dict(record)
    for key in FREE_TEXT_KEYS + DENYLIST_ONLY_KEYS:
        if key in record:
            max_len = props.get(key, {}).get("maxLength")
            if max_len is not None and len(record[key]) > max_len:
                record[key] = record[key][:max_len]
    return record


def extract_descriptive(item: dict, record_type: str) -> dict:
    """Read ONLY the keys appropriate to record_type from caller-supplied
    stdin JSON: DESCRIPTIVE_KEYS for a papercut, RESOLUTION_KEYS for a
    resolution. Anything else — including an attempted id/ts/machine/
    producer/source/session_id/repo/type — is silently ignored; those fields
    are controlled and constructed below, never taken from the caller."""
    keys = DESCRIPTIVE_KEYS if record_type == "papercut" else RESOLUTION_KEYS
    return {k: item[k] for k in keys if k in item}


def construct(descriptive: dict, args: argparse.Namespace, machine: str) -> dict:
    record = dict(descriptive)
    record["id"] = "pc_" + str(uuid.uuid4())
    record["v"] = 1
    record["type"] = args.type
    record["producer"] = args.producer
    record["ts"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    record["machine"] = machine
    record["source"] = args.source
    if args.session_id is not None:
        record["session_id"] = args.session_id
    if args.repo is not None:
        record["repo"] = args.repo
    if machine == "strict":
        record.pop("session_id", None)
        record.pop("repo", None)
    return record


def append_records(records: list, spool_path: str, lock_path: str) -> None:
    """Append every record under a single fcntl.flock held across the ENTIRE
    append: acquire the lock on lock_fd, open the spool, write all lines,
    flush + fsync, close the spool fd, then release the lock by unlocking
    and closing lock_fd. The lock file is separate from the spool so the
    flusher (papercuts_task_4__claim) can rename/replace the spool without
    racing an in-flight append — synchronizing on this one lock file closes
    the open-inode-then-rename race."""
    os.makedirs(os.path.dirname(spool_path), mode=0o700, exist_ok=True)
    os.makedirs(os.path.dirname(lock_path), mode=0o700, exist_ok=True)

    lock_fd = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o600)
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_EX)
        spool_fd = os.open(spool_path, os.O_CREAT | os.O_WRONLY | os.O_APPEND, 0o600)
        # The mode arg to os.open only applies on creation; tighten an existing
        # spool too so a pre-existing world-readable file can't leak records.
        os.fchmod(spool_fd, 0o600)
        with os.fdopen(spool_fd, "a", encoding="utf-8") as f:
            for record in records:
                f.write(json.dumps(record, sort_keys=True) + "\n")
            f.flush()
            os.fsync(f.fileno())
    finally:
        fcntl.flock(lock_fd, fcntl.LOCK_UN)
        os.close(lock_fd)


def write_review_sidecar(review_file: str, record_id: str, ts: str, runs: list) -> None:
    """Append ONE JSON line — {ts, record_id, runs} — documenting this record's
    vocab-shaped redactions VERBATIM, so a false-positive scrub can be
    reconstructed later by a human even though the stored ledger record only
    ever keeps "[token]".

    Concurrency + crash-safety, mirroring two existing precedents in THIS
    repo (both actually read, not assumed):
      - append_records() above takes an exclusive fcntl.flock on a SEPARATE
        lock file held across the whole write, so a concurrent writer to the
        same target can't interleave with it. This function does the same:
        <review_file>.lock, held for the read-modify-write below.
      - papercut-anchor.sh's sidecar writer (agents/papercuts/papercut-anchor.sh,
        ~line 209) does NOT append in place — it reads the existing file,
        writes existing+new to a private *.tmp file, fsyncs, then os.replace()s
        it over the target, because a crash mid-write to an append-mode fd can
        leave a truncated/partial JSON line on disk, and rename is atomic on
        the same filesystem. This function follows that same read-whole,
        write-tmp, atomic-rename shape, for the same reason: the sweep's
        prune_review_sidecar() (papercut-sweep.sh) also rewrites this file
        under the same lock, so a torn line here isn't just cosmetic, it can
        break that prune's JSON parsing and silently drop entries.

    Callers must treat any exception from this as non-fatal — see main(): a
    sidecar write failure must never fail the append itself, only degrade
    (silently on auto, to stderr on manual)."""
    dirpath = os.path.dirname(review_file)
    if dirpath:
        os.makedirs(dirpath, mode=0o700, exist_ok=True)
    lock_path = review_file + ".lock"
    lock_fd = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o600)
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_EX)

        existing = b""
        if os.path.exists(review_file):
            with open(review_file, "rb") as f:
                existing = f.read()

        line = json.dumps({"ts": ts, "record_id": record_id, "runs": runs}, sort_keys=True)
        new_line = (line + "\n").encode("utf-8")

        tmp_path = review_file + ".tmp"
        tmp_fd = os.open(tmp_path, os.O_CREAT | os.O_WRONLY | os.O_TRUNC, 0o600)
        # Buffered write rather than a raw os.write(): os.write() may write
        # FEWER bytes than it was given and report that count instead of
        # raising, so on ENOSPC the tail is dropped, the fsync succeeds, and
        # os.replace() then installs a truncated file over the only copy of
        # these runs — silent loss reported as success. Disk-full is precisely
        # the failure a last-copy file has to survive. BufferedWriter.write()
        # loops to completion or raises, which is the contract this needs, and
        # it matches how append_records() above writes the spool.
        try:
            with os.fdopen(tmp_fd, "wb") as out:
                out.write(existing + new_line)
                out.flush()
                os.fsync(out.fileno())
        except Exception:
            try:
                os.unlink(tmp_path)
            except OSError:
                pass
            raise
        os.replace(tmp_path, review_file)
        # fsync the PARENT DIRECTORY, not just the file. The rename itself is a
        # directory metadata operation, so fsyncing tmp only guarantees its
        # CONTENTS survive a power loss -- the rename that publishes them can
        # still be lost, reverting the sidecar to its pre-append state. Since
        # this file is the only copy of these runs, "durable bytes at a name
        # that didn't survive" is the same as losing them. Best-effort: a
        # directory that can't be opened is not worth failing an append over.
        try:
            dir_fd = os.open(dirpath or ".", os.O_RDONLY)
            try:
                os.fsync(dir_fd)
            finally:
                os.close(dir_fd)
        except OSError:
            pass
        # The mode arg to os.open only applies on creation; tighten a
        # pre-existing sidecar too, same as append_records() does for the spool.
        os.chmod(review_file, 0o600)
    finally:
        fcntl.flock(lock_fd, fcntl.LOCK_UN)
        os.close(lock_fd)


def fail(reason: str) -> None:
    print(reason, file=sys.stderr)
    sys.exit(1)


def main() -> None:
    os.umask(0o077)

    parser = argparse.ArgumentParser()
    parser.add_argument("--source", required=True, choices=["auto", "manual"])
    parser.add_argument("--session-id", dest="session_id", default=None)
    parser.add_argument("--producer", required=True)
    parser.add_argument("--repo", default=None)
    parser.add_argument("--type", default="papercut", choices=["papercut", "resolution"])
    args = parser.parse_args()

    try:
        data = json.load(sys.stdin)
    except Exception as e:
        fail(f"invalid JSON on stdin: {e}")
        return

    if isinstance(data, dict):
        items = [data]
    elif isinstance(data, list):
        items = data
    else:
        fail("stdin JSON must be an object or an array of objects")
        return

    machine = detect_machine()
    schema = load_schema()

    records = []
    review: set = set()
    # (record_id, ts, runs) for every record whose scrub produced at least one
    # vocab-shaped redaction — only populated when a review sidecar is
    # configured (see review_file below), and only written for records that
    # actually make it to append_records() (a later failure in this loop, or
    # append_records() itself, must never orphan a sidecar entry for a record
    # that was never persisted).
    pending_review_entries = []
    for item in items:
        if not isinstance(item, dict):
            fail("each record must be a JSON object")
            return

        record = construct(extract_descriptive(item, args.type), args, machine)

        ok, reason = validate_record(record, schema)
        if not ok:
            fail(f"validation failed: {reason}")
            return

        record_review: list = []
        try:
            record = scrub(record, machine, review, record_review)
        except ScrubRejected as e:
            fail(f"scrub rejected: {e}")
            return

        record = truncate_to_schema(record, schema)

        ok, reason = validate_record(record, schema)
        if not ok:
            fail(f"validation failed after scrub: {reason}")
            return

        if record_review:
            pending_review_entries.append((record["id"], record["ts"], record_review))

        records.append(record)

    spool_path = os.path.expanduser(
        os.environ.get("PAPERCUT_SPOOL", "~/.claude/papercuts/spool.jsonl")
    )
    lock_path = os.environ.get("PAPERCUT_LOCK")
    lock_path = (
        os.path.expanduser(lock_path)
        if lock_path
        else os.path.join(os.path.dirname(spool_path), ".spool.lock")
    )

    append_records(records, spool_path, lock_path)

    for record in records:
        print(json.dumps(record, sort_keys=True))

    # Scrub-review sidecar (see write_review_sidecar()): unset by default, so
    # behavior is byte-for-byte unchanged unless a caller opts in. Written
    # only now, AFTER append_records() succeeded, so a sidecar entry only ever
    # exists for a record that's actually in the spool. A write failure here
    # must never fail the append that already landed — degrade silently on
    # the auto path, to stderr on the manual path (the same asymmetry the
    # pre-existing SCRUB_REVIEW advisory below already has).
    review_file = os.environ.get("PAPERCUT_REVIEW_FILE")
    review_file = os.path.expanduser(review_file) if review_file else None
    if review_file:
        for record_id, ts, runs in pending_review_entries:
            try:
                write_review_sidecar(review_file, record_id, ts, runs)
            except OSError as e:
                if args.source == "manual":
                    print(f"scrub-review sidecar write failed: {e}", file=sys.stderr)
                else:
                    # Auto path: papercut-capture.sh discards this command's
                    # stdout/stderr wholesale on its normal run (`>/dev/null
                    # 2>/dev/null`) and, once we exit 0 here, writes the
                    # processed marker regardless of the sidecar outcome --
                    # this is the ONE remaining copy of a redacted run that
                    # the scrub judged worth a human look, so a failure here
                    # must leave a trace. Emit a bounded, fixed-shape marker
                    # instead of the exception text: the exception message can
                    # carry OS-provided strings (paths, in some locales
                    # non-ASCII text) that aren't safe to treat as fixed
                    # shape, and per the log() invariant in
                    # papercut-capture.sh, only metadata may ever reach the
                    # capture log -- never anything that traces back toward
                    # the scrubbed runs themselves. The exception CLASS name
                    # is safe: it's one of a small, code-defined set.
                    print(
                        f"SCRUB_REVIEW_WRITE_FAILED error_class={type(e).__name__}",
                        file=sys.stderr,
                    )

    # User check for false positives: report vocabulary-shaped runs the generic
    # token rule redacted, so the caller can offer to allowlist genuinely-safe
    # terms. Advisory only, on stderr — the stored records already keep [token].
    #
    # MANUAL ONLY, and deliberately so. This line prints the runs in PLAINTEXT.
    # Nothing reads stderr on the auto path — that is the whole premise of the
    # scrub-review sidecar — so on that path the advisory was never a user
    # check, only plaintext looking for somewhere to land. It used to land in
    # /dev/null; now that papercut-capture.sh captures this stderr to catch the
    # bounded WRITE_FAILED marker above, an ungated advisory would instead spill
    # the runs into a temp file on every auto capture. The sidecar already
    # retains them properly (0600, locked, TTL-pruned), so the auto path needs
    # nothing here.
    if review and args.source == "manual":
        print(
            "SCRUB_REVIEW: redacted token(s) that look like plain words — "
            "allowlist in papercut_append.py (_TOKEN_ALLOWLIST) if not secret: "
            + " ".join(sorted(review)),
            file=sys.stderr,
        )


if __name__ == "__main__":
    main()
