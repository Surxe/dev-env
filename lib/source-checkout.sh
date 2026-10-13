#!/usr/bin/env bash
#
# source-checkout.sh — which checkout of a source repo is an install.sh deploying?
#
# SOURCED by the machine repos' installers (my-system/users/installers/common.sh,
# home-server/install.sh), never executed. An install.sh deploys whatever is CHECKED
# OUT — that is how a change is tested before it merges — so the "bring the clone up
# to date" steps (fetch + fast-forward / pull) apply only when the clone is on its
# remote's default branch. A feature branch or a detached HEAD is deployed as-is:
# pulling there either fails (no upstream) or fast-forwards the branch onto the
# default branch behind the operator's back.
#
# Git always runs AS dev: the repos are dev-owned, so git as ethan/root would trip
# the dubious-ownership guard (and a root fetch leaves root-owned objects behind).
# The callers run as dev, ethan (sudo) or root (runuser), hence _sc_git.
#
# A sourced library must not mutate the caller's shell options, so this file does
# NOT `set -euo pipefail`.

[ -n "${_DEVENV_SOURCE_CHECKOUT_SOURCED:-}" ] && return 0
_DEVENV_SOURCE_CHECKOUT_SOURCED=1

_sc_git() {   # $1 = repo root, rest = git args
    local root="$1"; shift
    case "$(id -un)" in
        dev)  git -C "$root" "$@" ;;
        root) runuser -u dev -- git -C "$root" "$@" ;;
        *)    sudo -u dev git -C "$root" "$@" ;;
    esac
}

# current_branch: echo the checked-out branch name; empty on a detached HEAD.
current_branch() {      # $1 = repo root
    _sc_git "$1" symbolic-ref -q --short HEAD 2>/dev/null || true
}

# checkout_label: current_branch for humans ("detached HEAD" instead of empty).
checkout_label() {      # $1 = repo root
    local cur; cur="$(current_branch "$1")"
    printf '%s\n' "${cur:-detached HEAD}"
}

# on_default_branch: true when the checkout is the remote's default branch
# (origin/HEAD). With no origin/HEAD recorded there is nothing to compare against,
# so any named branch counts as the default.
on_default_branch() {   # $1 = repo root
    local cur def
    cur="$(current_branch "$1")"
    def="$(_sc_git "$1" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null || true)"
    def="${def#origin/}"
    [ -n "$cur" ] && [ "$cur" = "${def:-$cur}" ]
}
