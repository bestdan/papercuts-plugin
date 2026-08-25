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

Keys read (all under [ledger]):
  repo -- "owner/name". No default: required for publishing, not for this
          resolver to run.
  host -- default "github.com".
  dir  -- local clone path, default "~/src/papercuts" (the same default
          PAPERCUT_LEDGER_DIR already has). Tilde is expanded.

The resolver ALWAYS resolves: it exits 0 on a missing or partially-filled
config, emitting every key (defaults where they exist, empty where they
don't) plus one status line per key group -- PAPERCUT_CONFIG_LEDGER=ok when
ledger.repo resolved, =missing when it did not. Consumers decide whether a
missing group is fatal; only the flusher's publish path treats it that way.
The one hard error (non-zero exit, nothing on stdout) is a config file that
EXISTS but cannot be parsed or holds wrongly-typed values -- that is a
broken config, not an absent one.

Requires Python 3.11+ for stdlib tomllib; older interpreters get a clear
message instead of an ImportError.

Usage:
  eval "$(python3 papercut_config.py)"
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
        return explicit
    xdg = environ.get("XDG_CONFIG_HOME")
    if xdg:
        return os.path.join(xdg, "papercuts", "config.toml")
    return os.path.expanduser("~/.config/papercuts/config.toml")


def _load(path):
    import tomllib

    try:
        with open(path, "rb") as f:
            return tomllib.load(f)
    except tomllib.TOMLDecodeError as exc:
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


def resolve(environ=os.environ):
    """Return an ordered list of (KEY, value) pairs. Raises ConfigError on a
    config file that exists but is unparseable or wrongly typed; every other
    state (absent file, missing keys) resolves to defaults plus a status."""
    path = config_path(environ)
    data = {}
    if os.path.exists(path):
        data = _load(path)

    ledger = data.get("ledger", {})
    if not isinstance(ledger, dict):
        raise ConfigError(f"{path}: [ledger] must be a table, got {type(ledger).__name__}")

    repo = _string_key(ledger, "repo", path)
    host = _string_key(ledger, "host", path) or DEFAULT_HOST
    ledger_dir = os.path.expanduser(_string_key(ledger, "dir", path) or DEFAULT_DIR)

    return [
        ("PAPERCUT_CONFIG_LEDGER_REPO", repo or ""),
        ("PAPERCUT_CONFIG_LEDGER_HOST", host),
        ("PAPERCUT_CONFIG_LEDGER_DIR", ledger_dir),
        ("PAPERCUT_CONFIG_LEDGER", "ok" if repo else "missing"),
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
