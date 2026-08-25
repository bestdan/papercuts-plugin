#!/usr/bin/env python3
"""Resolve the papercuts config file into shell-eval-safe KEY=value lines.

This is the pipeline's single config parser. Bash consumers eval this
script's stdout instead of parsing TOML themselves; Python consumers import
resolve(). Nothing else in the pipeline reads the config file directly.

Config file location, most specific first:
  1. $PAPERCUT_CONFIG (when set and non-empty, this is the sole location --
     it never falls through to the defaults below)
  2. $XDG_CONFIG_HOME/papercuts/config.toml
  3. ~/.config/papercuts/config.toml

Keys read under [ledger]:
  repo       -- "owner/name". No default: required for publishing, not for
                this resolver to run.
  host       -- default "github.com".
  dir        -- local clone path, default "~/src/papercuts" (the same
                default PAPERCUT_LEDGER_DIR already has). Tilde is expanded.
  remote_url -- full remote URL, any scheme; no default. An exact-match
                trust anchor the flusher's origin allowlist accepts in
                addition to the host/repo-derived forms. Because it lives
                in the config file (the operator's PR-reviewable trust
                root), it is trusted; the PAPERCUT_LEDGER_REMOTE env var
                stays a value override that is always judged against the
                allowlist.

Keys read under [profile]:
  strict_hosts -- array of glob patterns, default empty. A machine whose
                real hostname matches any pattern resolves to the strict
                profile (papercut_append.detect_machine). Emitted as
                PAPERCUT_CONFIG_PROFILE_STRICT_HOSTS, one pattern per line
                (a newline separator is safe because a hostname pattern can
                never contain one, and shlex.quote keeps it eval-safe).
                Python consumers call strict_hosts() instead of splitting
                that value: command substitution strips trailing newlines, so
                the shell view of a list whose LAST pattern is the empty
                string loses that empty entry. No shell consumer reads this
                key today; the profile is resolved in Python
                (papercut_append.detect_machine), and the flusher calls that
                resolver rather than re-deriving it from this line.

                This key can only ADD strictness. Nothing here can remove
                it: the strict marker file's path is a hardcoded literal in
                papercut_append.py and NO key in this file names it. A key
                that looked like it did (a "marker" or "strict_marker"
                spelling) is simply ignored, like any other unknown key.

The resolver ALWAYS resolves: it exits 0 on a missing or partially-filled
config, emitting every key (defaults where they exist, empty where they
don't) plus one status line per key group -- PAPERCUT_CONFIG_LEDGER=ok when
the ledger identity resolved (repo or remote_url set), =missing when it
did not. Consumers decide whether a
missing group is fatal; only the flusher's publish path treats it that way.
The one hard error (non-zero exit, nothing on stdout) is a config file that
EXISTS but cannot be parsed or holds wrongly-typed values -- that is a
broken config, not an absent one.

Requires Python 3.11+ for stdlib tomllib; older interpreters get a clear
message instead of an ImportError.

Usage:
  out="$(python3 papercut_config.py)" || exit 1
  eval "$out"

(Not a bare `eval "$(python3 ...)"` -- eval of the empty hard-error output
exits 0, so the resolver's non-zero exit would be silently swallowed.)
"""

import os
import shlex
import sys

DEFAULT_HOST = "github.com"
DEFAULT_DIR = "~/src/papercuts"


class ConfigError(Exception):
    """A config file that exists but cannot be used."""


def config_path(environ):
    explicit = environ.get("PAPERCUT_CONFIG")
    if explicit:
        return os.path.expanduser(explicit)
    xdg = environ.get("XDG_CONFIG_HOME")
    if xdg:
        return os.path.expanduser(os.path.join(xdg, "papercuts", "config.toml"))
    return os.path.expanduser("~/.config/papercuts/config.toml")


def _load(path):
    # Returns None when the file is absent. Opening directly (no exists()
    # pre-check) keeps an unreadable-but-existing config a hard error:
    # exists() returns False when a parent directory is unreadable, which
    # would silently resolve a broken config to defaults.
    import tomllib

    try:
        with open(path, "rb") as f:
            return tomllib.load(f)
    except FileNotFoundError:
        return None
    except (tomllib.TOMLDecodeError, UnicodeDecodeError) as exc:
        raise ConfigError(f"{path}: TOML parse error: {exc}") from exc
    except OSError as exc:
        raise ConfigError(f"{path}: unreadable: {exc}") from exc


def _string_key(table, key, path):
    value = table.get(key)
    if value is None:
        return None
    if not isinstance(value, str):
        raise ConfigError(f"{path}: ledger.{key} must be a string, got {type(value).__name__}")
    return value


def _profile_table(data, path):
    profile = data.get("profile", {})
    if not isinstance(profile, dict):
        raise ConfigError(f"{path}: [profile] must be a table, got {type(profile).__name__}")
    return profile


def _strict_hosts(profile, path):
    """The [profile] strict_hosts patterns, or [] when the key is absent. A
    non-list value, or a list holding a non-string, is a hard error on the
    same path as every other wrongly-typed value: a config that means to add
    strictness and is malformed must not read as "no patterns"."""
    value = profile.get("strict_hosts")
    if value is None:
        return []
    if not isinstance(value, list):
        raise ConfigError(
            f"{path}: profile.strict_hosts must be an array of strings, "
            f"got {type(value).__name__}"
        )
    for item in value:
        if not isinstance(item, str):
            raise ConfigError(
                f"{path}: profile.strict_hosts entries must be strings, "
                f"got {type(item).__name__}"
            )
    return list(value)


def strict_hosts(environ=os.environ):
    """Return the [profile] strict_hosts glob patterns as a list of strings.

    The plain-list view of the same key resolve() emits, for Python importers
    (papercut_append.detect_machine) that want the patterns rather than an
    encoded shell value. Same load and same validation — the TOML is never
    parsed a second way. Raises ConfigError on the same broken-config states
    resolve() does; an absent file or an absent [profile] table returns []."""
    path = config_path(environ)
    data = _load(path)
    if data is None:
        data = {}
    return _strict_hosts(_profile_table(data, path), path)


def resolve(environ=os.environ):
    """Return an ordered list of (KEY, value) pairs. Raises ConfigError on a
    config file that exists but is unparseable or wrongly typed; every other
    state (absent file, missing keys) resolves to defaults plus a status."""
    path = config_path(environ)
    data = _load(path)
    if data is None:
        data = {}

    ledger = data.get("ledger", {})
    if not isinstance(ledger, dict):
        raise ConfigError(f"{path}: [ledger] must be a table, got {type(ledger).__name__}")

    repo = _string_key(ledger, "repo", path)
    host = _string_key(ledger, "host", path) or DEFAULT_HOST
    ledger_dir = os.path.expanduser(_string_key(ledger, "dir", path) or DEFAULT_DIR)
    remote_url = _string_key(ledger, "remote_url", path)

    patterns = _strict_hosts(_profile_table(data, path), path)

    return [
        ("PAPERCUT_CONFIG_LEDGER_REPO", repo or ""),
        ("PAPERCUT_CONFIG_LEDGER_HOST", host),
        ("PAPERCUT_CONFIG_LEDGER_DIR", ledger_dir),
        ("PAPERCUT_CONFIG_LEDGER_REMOTE_URL", remote_url or ""),
        ("PAPERCUT_CONFIG_LEDGER", "ok" if (repo or remote_url) else "missing"),
        ("PAPERCUT_CONFIG_PROFILE_STRICT_HOSTS", "\n".join(patterns)),
    ]


def main():
    if sys.version_info < (3, 11):
        found = ".".join(str(part) for part in sys.version_info[:3])
        print(
            f"papercut_config.py: Python 3.11 or newer is required (stdlib tomllib); "
            f"this python3 is {found}",
            file=sys.stderr,
        )
        return 1

    try:
        pairs = resolve()
    except ConfigError as exc:
        print(f"papercut_config.py: {exc}", file=sys.stderr)
        return 1

    for key, value in pairs:
        print(f"{key}={shlex.quote(value)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
