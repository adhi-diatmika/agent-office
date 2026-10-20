#!/usr/bin/env bash
# agent-office: mode detection and shared helpers.
#
# Execute it to print the current mode (local or cloud):
#   bash office-mode.sh
# Or source it from another script to get the helper functions below.
#
# Mode rules:
#   1. OFFICE_MODE (local|cloud) wins when set.
#   2. Otherwise CLAUDE_CODE_REMOTE=true means cloud.
#   3. Otherwise local.
#
# Compatible with macOS bash 3.2 and Linux bash.

# Space separated list of branch names nobody in the office may touch.
AGENT_OFFICE_PROTECTED="${AGENT_OFFICE_PROTECTED:-main master develop trunk}"

office_mode() {
  case "${OFFICE_MODE:-}" in
    local|cloud) printf '%s\n' "$OFFICE_MODE"; return 0 ;;
  esac
  if [ "${CLAUDE_CODE_REMOTE:-}" = "true" ]; then
    printf 'cloud\n'
  else
    printf 'local\n'
  fi
}

# office_is_protected <branch>: true when the branch name is protected.
# Accepts refs/heads/<name> as well.
office_is_protected() {
  local name="${1#refs/heads/}"
  local p
  for p in $AGENT_OFFICE_PROTECTED; do
    [ "$name" = "$p" ] && return 0
  done
  return 1
}

# office_current_branch [dir]: prints the current branch, empty when detached.
office_current_branch() {
  git -C "${1:-.}" symbolic-ref --short -q HEAD 2>/dev/null || true
}

# office_repo_root [dir]: absolute path of the main working tree, even when
# called from inside a linked worktree.
office_repo_root() {
  local dir="${1:-.}" common
  common="$(git -C "$dir" rev-parse --git-common-dir 2>/dev/null)" || return 1
  case "$common" in
    /*) ;;
    *) common="$(cd "$dir" && cd "$common" && pwd)" || return 1 ;;
  esac
  if [ "$(basename "$common")" = ".git" ]; then
    dirname "$common"
  else
    # Unusual layout (for example a bare repo): fall back to the toplevel.
    git -C "$dir" rev-parse --show-toplevel 2>/dev/null
  fi
}

# office_quote <value>: value made safe inside double quotes in meta.env.
office_quote() {
  printf '%s' "$1" | sed -e 's/[\\"$`]/\\&/g'
}

# office_meta_get <meta.env> <KEY>: prints one value without sourcing the file.
office_meta_get() {
  local line
  line="$(grep -E "^$2=" "$1" 2>/dev/null | tail -n 1)" || true
  line="${line#*=}"
  line="${line#\"}"
  line="${line%\"}"
  printf '%s' "$line" | sed -e 's/\\\(.\)/\1/g'
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  office_mode
fi
