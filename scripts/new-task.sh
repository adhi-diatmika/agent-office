#!/usr/bin/env bash
# agent-office: create a new task.
#
# Usage: new-task.sh "<title>"
#
# Run from anywhere inside the project's Git repository. Prints KEY=VALUE
# lines (MODE, TASK_DIR, WORKTREE, BRANCH, BASE_COMMIT) on success.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=office-mode.sh
. "$SCRIPT_DIR/office-mode.sh"

die() {
  printf '[agent-office] GAGAL: %s\n' "$1" >&2
  exit 1
}

RAW_TITLE="${1:-}"

git rev-parse --git-dir >/dev/null 2>&1 \
  || die "folder ini bukan repository Git. Jalankan dari dalam proyek Git."
git rev-parse --verify -q HEAD >/dev/null 2>&1 \
  || die "repository belum punya commit. Buat commit pertama dulu."
CURRENT_BRANCH="$(office_current_branch)"
[ -n "$CURRENT_BRANCH" ] \
  || die "HEAD dalam keadaan detached. Pindah ke sebuah branch dulu (git switch <branch>)."

MODE="$(office_mode)"
REPO_ROOT="$(office_repo_root)" || die "tidak bisa menentukan root repository."

# Strip characters that could break quoting: " $ ` \
TITLE="$(printf '%s' "$RAW_TITLE" | tr -d '"$`\\' | tr '\n\r\t' '   ' | sed -e 's/^ *//' -e 's/ *$//')"
[ -n "$TITLE" ] || TITLE="task"

KEBAB="$(printf '%s' "$TITLE" | tr '[:upper:]' '[:lower:]' | sed -e 's/[^a-z0-9]\{1,\}/-/g' -e 's/^-*//' | cut -c1-40 | sed -e 's/-*$//')"
[ -n "$KEBAB" ] || KEBAB="task"

STAMP="$(date +%m%d-%H%M)"
SLUG="$STAMP-$KEBAB"
OFFICE_DIR="$REPO_ROOT/.claude/office"
WORKTREES_DIR="$REPO_ROOT/.claude/worktrees"

# Avoid collisions when two tasks with the same title start in one minute.
n=2
while [ -e "$OFFICE_DIR/$SLUG" ] || git -C "$REPO_ROOT" show-ref --verify -q "refs/heads/office/$SLUG"; do
  SLUG="$STAMP-$KEBAB-$n"
  n=$((n + 1))
done

# Keep office data out of Git without any committed change in the project.
COMMON_DIR="$(git rev-parse --git-common-dir)"
case "$COMMON_DIR" in
  /*) ;;
  *) COMMON_DIR="$(cd "$COMMON_DIR" && pwd)" ;;
esac
EXCLUDE_FILE="$COMMON_DIR/info/exclude"
mkdir -p "$COMMON_DIR/info"
touch "$EXCLUDE_FILE"
for entry in "/.claude/office/" "/.claude/worktrees/"; do
  if ! grep -qxF "$entry" "$EXCLUDE_FILE"; then
    # Make sure the file ends with a newline before appending.
    if [ -s "$EXCLUDE_FILE" ] && [ -n "$(tail -c 1 "$EXCLUDE_FILE")" ]; then
      printf '\n' >>"$EXCLUDE_FILE"
    fi
    printf '%s\n' "$entry" >>"$EXCLUDE_FILE"
  fi
done

TASK_DIR="$OFFICE_DIR/$SLUG"
BASE_BRANCH="$CURRENT_BRANCH"
BASE_COMMIT="$(git rev-parse HEAD)"

if [ "$MODE" = "local" ]; then
  BRANCH="office/$SLUG"
  WORKTREE="$WORKTREES_DIR/$SLUG"
  mkdir -p "$WORKTREES_DIR"
  git -C "$REPO_ROOT" worktree add -q -b "$BRANCH" "$WORKTREE" "$BASE_COMMIT" >&2 \
    || die "git worktree add gagal untuk $WORKTREE."
else
  WORKTREE="$REPO_ROOT"
  BRANCH="$CURRENT_BRANCH"
  if office_is_protected "$CURRENT_BRANCH"; then
    BRANCH="office/$SLUG"
    git -C "$REPO_ROOT" checkout -q -b "$BRANCH" >&2 \
      || die "gagal membuat branch $BRANCH."
  fi
fi

mkdir -p "$TASK_DIR"
CREATED="$(date '+%Y-%m-%dT%H:%M:%S%z')"
{
  printf 'MODE="%s"\n' "$(office_quote "$MODE")"
  printf 'TITLE="%s"\n' "$(office_quote "$TITLE")"
  printf 'SLUG="%s"\n' "$(office_quote "$SLUG")"
  printf 'BASE_BRANCH="%s"\n' "$(office_quote "$BASE_BRANCH")"
  printf 'BASE_COMMIT="%s"\n' "$(office_quote "$BASE_COMMIT")"
  printf 'BRANCH="%s"\n' "$(office_quote "$BRANCH")"
  printf 'WORKTREE="%s"\n' "$(office_quote "$WORKTREE")"
  printf 'CREATED="%s"\n' "$(office_quote "$CREATED")"
} >"$TASK_DIR/meta.env"

printf 'MODE=%s\n' "$MODE"
printf 'TASK_DIR=%s\n' "$TASK_DIR"
printf 'WORKTREE=%s\n' "$WORKTREE"
printf 'BRANCH=%s\n' "$BRANCH"
printf 'BASE_COMMIT=%s\n' "$BASE_COMMIT"
