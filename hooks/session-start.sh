#!/usr/bin/env bash
# agent-office SessionStart hook. Prints one line of context for Claude.
# In cloud mode it also installs project dependencies (best effort).
set -u

ROOT="${CLAUDE_PLUGIN_ROOT:-}"
if [ -z "$ROOT" ] || [ ! -d "$ROOT/scripts" ]; then
  ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fi
# shellcheck source=../scripts/office-mode.sh
. "$ROOT/scripts/office-mode.sh"

# Drain stdin (hook input JSON) so the writer never blocks.
cat >/dev/null 2>&1 || true

MODE="$(office_mode)"
PROJECT="${CLAUDE_PROJECT_DIR:-$PWD}"

if [ "$MODE" = "local" ]; then
  RULES="local mode: each task gets its own git worktree under .claude/worktrees/<slug> on branch office/<slug>; agents never push, merge, or delete branches; the user accepts or rejects with finish-task.sh."
  DEPS=""
else
  RULES="cloud mode: one task per session, work happens in the repo root on the current session branch (office/<slug> if it was a protected branch); at the end commit and run git push -u origin <BRANCH>; the user accepts via a Pull Request."
  LOG="/tmp/agent-office-install.log"
  if bash "$ROOT/scripts/run-checks.sh" --install-only "$PROJECT" >"$LOG" 2>&1; then
    DEPS=" DEPS=OK (log: $LOG)."
  else
    DEPS=" DEPS=FAILED (log: $LOG)."
  fi
fi

printf '[agent-office] MODE=%s AGENT_OFFICE_ROOT=%s. Rules: %s Use /agent-office:task <brief> to start a task.%s\n' \
  "$MODE" "$ROOT" "$RULES" "$DEPS"
exit 0
