#!/usr/bin/env python3
"""Load and validate the papercuts owners registry (owners.toml).

The registry lives in the ledger repo, not the machine config -- owners are a
property of the ledger (the set of people sharing it), so every machine that
runs triage must see one map, and a change to it must be a reviewed commit.
See dev_docs/designs/2026-09-07-triage-and-route.md §3 for the design.

File location, most specific first:
  1. $PAPERCUT_OWNERS (when set and non-empty, this is the sole location --
     it never falls through to the ledger clone below; tests use this)
  2. <ledger dir>/owners.toml, where <ledger dir> is the same resolution
     papercut_config.py provides ([ledger].dir, default ~/src/papercuts),
     overridable with $PAPERCUT_LEDGER_DIR like every other script.

Shape:
  [owners.<name>]
    tracker = "gh-issue"   # required; only "gh-issue" is implemented
    repo    = "owner/name" # required
    scope   = "..."        # required, non-empty
    labels  = ["..."]      # optional, array of strings

  [external.<name>]
    repo  = "owner/name"   # required
    scope = "..."          # required, non-empty
    # no tracker, no labels -- an external target files nowhere itself

  [unowned]
    repo = "owner/name"    # optional, default [ledger].repo from config.toml

<name> matches ^[a-z0-9][a-z0-9._-]*$, is never "unowned", and is unique
across [owners] and [external] -- it is the closed vocabulary triage picks
a target from, so an ambiguous or reserved name must fail loudly rather than
resolve to something a later reader would not expect.

Python consumers import load(). It raises OwnersError on any problem,
INCLUDING a missing file -- triage without a registry is not a run, so there
is no "no owners" fallback the way an absent papercuts config resolves to
defaults. Command-line use exits 2 with a message on stderr on any
validation error, and nothing on stdout.

Requires Python 3.11+ for stdlib tomllib, same as papercut_config.py.

Usage:
  python3 papercut_owners.py           # human-readable listing
  python3 papercut_owners.py --json    # {"owners": {...}, "external": {...}, "unowned": {...}}
"""

import argparse
import json
import os
import re
import sys

NAME_RE = re.compile(r"^[a-z0-9][a-z0-9._-]*$")
REPO_RE = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")

_CONFIG_MODULE = None


def _config_module():
    """Import papercut_config.py from THIS file's directory, by path.

    Mirrors papercut_append.py's _config_module(): a bare `import
    papercut_config` works when this script is run directly (its directory
    is sys.path[0]) but not under a test harness that executes it another
    way. Loading by explicit path works in both."""
    global _CONFIG_MODULE
    if _CONFIG_MODULE is None:
        import importlib.util

        path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "papercut_config.py")
        spec = importlib.util.spec_from_file_location("papercut_config", path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        _CONFIG_MODULE = module
    return _CONFIG_MODULE


class OwnersError(Exception):
    """A registry file that is missing, unparseable, or invalid."""


def _resolve_ledger(environ):
    """Return (ledger_dir, ledger_repo). ledger_repo is None when config.toml
    has no [ledger].repo set. Raises OwnersError on a broken config.toml --
    the same hard-error contract papercut_config.py has for its own callers."""
    config = _config_module()
    try:
        pairs = dict(config.resolve(environ))
    except config.ConfigError as exc:
        raise OwnersError(str(exc)) from exc

    ledger_dir = environ.get("PAPERCUT_LEDGER_DIR") or pairs["PAPERCUT_CONFIG_LEDGER_DIR"]
    ledger_dir = os.path.expanduser(ledger_dir)
    ledger_repo = pairs["PAPERCUT_CONFIG_LEDGER_REPO"] or None
    return ledger_dir, ledger_repo


def registry_path(environ=os.environ):
    """Where the registry file is read from -- $PAPERCUT_OWNERS, else
    <ledger dir>/owners.toml."""
    explicit = environ.get("PAPERCUT_OWNERS")
    if explicit:
        return os.path.expanduser(explicit)
    ledger_dir, _ = _resolve_ledger(environ)
    return os.path.join(ledger_dir, "owners.toml")


def _validate_name(name, path):
    if name == "unowned":
        raise OwnersError(f"{path}: 'unowned' is a reserved name and cannot be an owner or external target")
    if not NAME_RE.match(name):
        raise OwnersError(f"{path}: '{name}' is not a valid name (must match {NAME_RE.pattern})")


def _require_str(table, key, path, context):
    value = table.get(key)
    if not isinstance(value, str) or not value:
        raise OwnersError(f"{path}: {context}.{key} must be a non-empty string")
    return value


def _require_repo(table, path, context):
    value = _require_str(table, "repo", path, context)
    if not REPO_RE.match(value):
        raise OwnersError(f"{path}: {context}.repo must be 'owner/name', got {value!r}")
    return value


def _optional_labels(table, path, context):
    if "labels" not in table:
        return []
    value = table["labels"]
    if not isinstance(value, list) or not all(isinstance(item, str) for item in value):
        raise OwnersError(f"{path}: {context}.labels must be an array of strings")
    return list(value)


def _validate_owner(name, table, path):
    if not isinstance(table, dict):
        raise OwnersError(f"{path}: owners.{name} must be a table, got {type(table).__name__}")
    context = f"owners.{name}"
    tracker = table.get("tracker")
    if tracker != "gh-issue":
        raise OwnersError(f"{path}: {context}.tracker must be 'gh-issue', got {tracker!r}")
    repo = _require_repo(table, path, context)
    scope = _require_str(table, "scope", path, context)
    labels = _optional_labels(table, path, context)
    return {"tracker": tracker, "repo": repo, "scope": scope, "labels": labels}


def _validate_external(name, table, path):
    if not isinstance(table, dict):
        raise OwnersError(f"{path}: external.{name} must be a table, got {type(table).__name__}")
    context = f"external.{name}"
    if "tracker" in table:
        raise OwnersError(f"{path}: {context}.tracker is not allowed -- external targets have no tracker")
    if "labels" in table:
        raise OwnersError(f"{path}: {context}.labels is not allowed -- external targets have no tracker")
    repo = _require_repo(table, path, context)
    scope = _require_str(table, "scope", path, context)
    return {"repo": repo, "scope": scope}


def load(environ=os.environ):
    """Return {"owners": {name: {...}}, "external": {name: {...}}, "unowned":
    {"repo": ...}}. Raises OwnersError on a missing, unparseable, or invalid
    registry."""
    import tomllib

    path = registry_path(environ)

    try:
        with open(path, "rb") as f:
            data = tomllib.load(f)
    except FileNotFoundError:
        raise OwnersError(f"{path}: owners registry not found")
    except (tomllib.TOMLDecodeError, UnicodeDecodeError) as exc:
        raise OwnersError(f"{path}: TOML parse error: {exc}") from exc
    except OSError as exc:
        raise OwnersError(f"{path}: unreadable: {exc}") from exc

    owners_table = data.get("owners", {})
    if not isinstance(owners_table, dict):
        raise OwnersError(f"{path}: [owners] must be a table, got {type(owners_table).__name__}")
    external_table = data.get("external", {})
    if not isinstance(external_table, dict):
        raise OwnersError(f"{path}: [external] must be a table, got {type(external_table).__name__}")
    unowned_table = data.get("unowned", {})
    if not isinstance(unowned_table, dict):
        raise OwnersError(f"{path}: [unowned] must be a table, got {type(unowned_table).__name__}")

    owners = {}
    for name, table in owners_table.items():
        _validate_name(name, path)
        owners[name] = _validate_owner(name, table, path)

    external = {}
    for name, table in external_table.items():
        _validate_name(name, path)
        external[name] = _validate_external(name, table, path)

    dupes = sorted(set(owners) & set(external))
    if dupes:
        raise OwnersError(f"{path}: name(s) {dupes} appear in both [owners] and [external]")

    unowned_repo = unowned_table.get("repo")
    if unowned_repo is not None:
        if not isinstance(unowned_repo, str) or not REPO_RE.match(unowned_repo):
            raise OwnersError(f"{path}: unowned.repo must be 'owner/name', got {unowned_repo!r}")
    else:
        # config.toml is consulted only here, and only when the registry
        # leaves the default to it -- an explicit $PAPERCUT_OWNERS registry
        # that sets unowned.repo never touches config at all.
        _, unowned_repo = _resolve_ledger(environ)
    if not unowned_repo:
        raise OwnersError(f"{path}: unowned.repo is not set and [ledger].repo is not configured either")

    return {"owners": owners, "external": external, "unowned": {"repo": unowned_repo}}


def main():
    if sys.version_info < (3, 11):
        found = ".".join(str(part) for part in sys.version_info[:3])
        print(
            f"papercut_owners.py: Python 3.11 or newer is required (stdlib tomllib); "
            f"this python3 is {found}",
            file=sys.stderr,
        )
        return 2

    parser = argparse.ArgumentParser(description="Load and validate the papercuts owners registry.")
    parser.add_argument("--json", action="store_true", help="print the registry as JSON")
    args = parser.parse_args()

    try:
        registry = load()
    except OwnersError as exc:
        print(f"papercut_owners.py: {exc}", file=sys.stderr)
        return 2

    if args.json:
        print(json.dumps(registry))
    else:
        for name, owner in sorted(registry["owners"].items()):
            labels = ", ".join(owner["labels"]) if owner["labels"] else "none"
            print(f"owner    {name}: {owner['repo']} [{owner['tracker']}] scope={owner['scope']!r} labels={labels}")
        for name, ext in sorted(registry["external"].items()):
            print(f"external {name}: {ext['repo']} scope={ext['scope']!r}")
        print(f"unowned  -> {registry['unowned']['repo']}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
