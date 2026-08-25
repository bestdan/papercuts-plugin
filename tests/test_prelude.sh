#!/usr/bin/env bash
# Shared prelude for this repo's *.test.sh suites. Source it at the top of
# every suite, before any other setup:
#
#   . "$(dirname "${BASH_SOURCE[0]}")/test_prelude.sh"          # tests/
#
# Why: the suites build throwaway git repos, spawn hooks, and shell out to
# tools that all read ambient state. Whatever the developer's machine happens
# to have configured leaks straight in. That is how 20 papercut-flush tests
# came to fail on a real workstation while passing in a bare CI sandbox — the
# fixtures inherited core.hooksPath from this very repo, whose pre-commit
# refuses commits to main, which is exactly what the fixtures do.
#
# The rule this encodes: a test's result must not depend on the machine it
# runs on. Anything ambient gets pinned here rather than in each suite.

# Git: ignore ~/.gitconfig and /etc/gitconfig entirely. Every fixture repo
# already sets a local user.name/user.email, so nothing needs global config.
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null

# HOME: pin it to a throwaway so that anything which reads it — directly, or
# via a tool's dotfile lookup — can neither read nor scribble on the real home
# directory. Two paths under it are load-bearing for the profile resolver:
# ~/.config/papercuts/strict (the strict marker) and
# ~/.config/papercuts/config.toml (profile.strict_hosts). A suite that read the
# developer's real ones would resolve the strict profile on a work laptop and
# fail there while passing in CI — the exact class of breakage this prelude
# exists to prevent.
#
# tests/run-tests.sh does not set DOTFILES_TEST_HOME, so every suite creates
# its own throwaway home here, left in TMPDIR for the OS to reap. Exporting
# DOTFILES_TEST_HOME first makes the suites share (and keep) one directory.
#
# The explicit "$TMPDIR" template is load-bearing on macOS: bare `mktemp -d`
# resolves its own per-user directory (/var/folders/...) via confstr and
# ignores $TMPDIR entirely, so under an agent sandbox — which grants write
# access to $TMPDIR and nothing else — it fails with "Operation not permitted".
# Every mktemp in this repo's test tooling passes a $TMPDIR template for that
# reason; without it the suites only run with the sandbox disabled.
if [ -z "${DOTFILES_TEST_HOME:-}" ]; then
  DOTFILES_TEST_HOME="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-test-home.XXXXXX")"
  export DOTFILES_TEST_HOME
fi
export HOME="$DOTFILES_TEST_HOME"

# XDG_CONFIG_HOME: pinning HOME is not enough — the config resolver checks
# $XDG_CONFIG_HOME/papercuts/config.toml BEFORE ~/.config, so a developer with
# it exported would still steer every suite at their real config (including
# profile.strict_hosts). Unset it so the pinned HOME is the only lookup path.
unset XDG_CONFIG_HOME

# PAPERCUT_*: a developer with these exported (they are a supported way to
# point the tools at a scratch spool) would otherwise silently steer the
# suites. Each suite sets the ones it needs after sourcing this.
for _tp_var in $(env | sed -n 's/^\(PAPERCUT_[A-Za-z0-9_]*\)=.*/\1/p'); do
  unset "$_tp_var"
done
unset _tp_var
