#!/usr/bin/env bash
# agent-office: accept or reject a finished task. Meant for the user only;
# the guard hook blocks agents from running it.
#
# Usage:
#   finish-task.sh                  list open tasks with their review verdict
#   finish-task.sh <slug> accept    merge the task branch into its base branch
#   finish-task.sh <slug> reject    discard the task branch and worktree
#
# Run it from inside the project's repository (main working tree).
set -u

# Follow symlinks (the optional `agent-office` command is one) without
# readlink -f, which macOS lacks.
SELF="$0"
while [ -L "$SELF" ]; do
  LINK="$(readlink "$SELF")"
  case "$LINK" in
    /*) SELF="$LINK" ;;
    *) SELF="$(dirname "$SELF")/$LINK" ;;
  esac
done
SCRIPT_DIR="$(cd "$(dirname "$SELF")" && pwd)"
# shellcheck source=office-mode.sh
. "$SCRIPT_DIR/office-mode.sh"

say() { printf '[agent-office] %s\n' "$*"; }
die() { printf '[agent-office] GAGAL: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<EOF
Pemakaian:
  agent-office                    daftar task yang masih terbuka
  agent-office <slug> accept      gabungkan (merge) task ke branch asalnya
  agent-office <slug> reject      buang task beserta branch dan worktree-nya

(atau jalankan langsung: $SCRIPT_DIR/finish-task.sh ...)
EOF
}

git rev-parse --git-dir >/dev/null 2>&1 || die "folder ini bukan repository Git. Jalankan dari dalam proyek."
REPO_ROOT="$(office_repo_root)" || die "tidak bisa menentukan root repository."
OFFICE_DIR="$REPO_ROOT/.claude/office"
MODE="$(office_mode)"

verdict_of() {
  local v
  v="$(grep -E '^Verdict:' "$1/review.md" 2>/dev/null | head -n 1 | sed -e 's/^Verdict:[[:space:]]*//')"
  [ -n "$v" ] || v="(belum direview)"
  printf '%s' "$v"
}

cloud_notice() {
  say "Task ini berjalan di mode cloud."
  say "Penerimaan dilakukan lewat Pull Request di GitHub dari branch: ${1:-<branch sesi>}"
  say "Buka PR, review, lalu merge di GitHub. Untuk menolak, tutup PR dan hapus branch-nya."
}

list_tasks() {
  local found=0 d slug
  if [ -d "$OFFICE_DIR" ]; then
    for d in "$OFFICE_DIR"/*/; do
      [ -f "$d/meta.env" ] || continue
      [ -f "$d/DONE" ] && continue
      if [ "$found" = "0" ]; then
        printf '%-45s %-6s %-45s %s\n' "SLUG" "MODE" "BRANCH" "VERDICT"
      fi
      found=1
      slug="$(basename "$d")"
      printf '%-45s %-6s %-45s %s\n' "$slug" \
        "$(office_meta_get "$d/meta.env" MODE)" \
        "$(office_meta_get "$d/meta.env" BRANCH)" \
        "$(verdict_of "$d")"
    done
  fi
  if [ "$found" = "0" ]; then
    say "Tidak ada task terbuka di $REPO_ROOT."
  fi
  printf '\n'
  usage
  if [ "$MODE" = "cloud" ]; then
    printf '\n'
    cloud_notice ""
  fi
}

confirm() {
  local answer=""
  printf '%s [y/N] ' "$1"
  read -r answer || answer=""
  case "$answer" in
    y|Y|yes|YES|ya|Ya|YA) return 0 ;;
  esac
  return 1
}

if [ "$#" -eq 0 ]; then
  list_tasks
  exit 0
fi

[ "$#" -eq 2 ] || { usage; exit 1; }
SLUG="$1"
ACTION="$2"
case "$SLUG" in
  */*|.*|"") die "slug tidak valid: $SLUG" ;;
esac
case "$ACTION" in
  accept|reject) ;;
  *) usage; exit 1 ;;
esac

TASK_DIR="$OFFICE_DIR/$SLUG"
META="$TASK_DIR/meta.env"
[ -f "$META" ] || die "task '$SLUG' tidak ditemukan di $OFFICE_DIR."
[ -f "$TASK_DIR/DONE" ] && die "task '$SLUG' sudah selesai ($(head -n 1 "$TASK_DIR/DONE"))."

T_MODE="$(office_meta_get "$META" MODE)"
T_TITLE="$(office_meta_get "$META" TITLE)"
T_BRANCH="$(office_meta_get "$META" BRANCH)"
T_BASE="$(office_meta_get "$META" BASE_BRANCH)"
T_WORKTREE="$(office_meta_get "$META" WORKTREE)"

if [ "$MODE" = "cloud" ] || [ "$T_MODE" = "cloud" ]; then
  cloud_notice "$T_BRANCH"
  exit 0
fi

[ -n "$T_BRANCH" ] && [ -n "$T_BASE" ] || die "meta.env tidak lengkap: $META"
case "$T_BRANCH" in
  office/*) ;;
  *) die "branch task tidak diawali office/: $T_BRANCH. Dibatalkan demi keamanan." ;;
esac

write_done() {
  printf '%s %s\n' "$1" "$(date '+%Y-%m-%dT%H:%M:%S%z')" >"$TASK_DIR/DONE"
}

remove_worktree() {
  if [ -d "$T_WORKTREE" ]; then
    git -C "$REPO_ROOT" worktree remove "$@" "$T_WORKTREE" || return 1
  else
    git -C "$REPO_ROOT" worktree prune
  fi
}

branch_exists() {
  git -C "$REPO_ROOT" show-ref --verify -q "refs/heads/$T_BRANCH"
}

if [ "$ACTION" = "accept" ]; then
  branch_exists || die "branch $T_BRANCH tidak ada."
  if [ -d "$T_WORKTREE" ] && [ -n "$(git -C "$T_WORKTREE" status --porcelain)" ]; then
    die "worktree $T_WORKTREE masih punya perubahan yang belum di-commit. Commit atau buang dulu."
  fi
  CURRENT="$(office_current_branch "$REPO_ROOT")"
  if [ "$CURRENT" != "$T_BASE" ]; then
    die "kamu sedang di branch '${CURRENT:-detached HEAD}', bukan '$T_BASE'. Jalankan: git -C \"$REPO_ROOT\" switch $T_BASE"
  fi
  if [ -n "$(git -C "$REPO_ROOT" status --porcelain --untracked-files=no)" ]; then
    die "working tree $REPO_ROOT punya perubahan yang belum di-commit. Commit atau stash dulu."
  fi

  say "Task   : $SLUG ($T_TITLE)"
  say "Merge  : $T_BRANCH -> $T_BASE"
  say "Verdict: $(verdict_of "$TASK_DIR")"
  printf '\n'
  git -C "$REPO_ROOT" --no-pager diff --stat "$T_BASE...$T_BRANCH"
  printf '\n'
  confirm "Gabungkan task ini ke $T_BASE?" || { say "Dibatalkan."; exit 1; }

  if ! git -C "$REPO_ROOT" merge --no-ff --no-edit -m "Merge office task $SLUG: $T_TITLE" "$T_BRANCH"; then
    git -C "$REPO_ROOT" merge --abort >/dev/null 2>&1 || true
    die "merge gagal (kemungkinan konflik). Merge dibatalkan; tidak ada yang berubah."
  fi
  remove_worktree || die "merge berhasil, tetapi worktree $T_WORKTREE gagal dihapus."
  git -C "$REPO_ROOT" branch -d "$T_BRANCH" >/dev/null || die "merge berhasil, tetapi branch $T_BRANCH gagal dihapus."
  write_done accepted
  say "Selesai. Task $SLUG sudah digabung ke $T_BASE."
  exit 0
fi

# reject
say "Task  : $SLUG ($T_TITLE)"
say "Branch: $T_BRANCH (akan dihapus beserta semua commit-nya)"
confirm "Buang task ini?" || { say "Dibatalkan."; exit 1; }
remove_worktree --force || die "worktree $T_WORKTREE gagal dihapus."
if branch_exists; then
  git -C "$REPO_ROOT" branch -D "$T_BRANCH" >/dev/null || die "branch $T_BRANCH gagal dihapus."
fi
write_done rejected
say "Selesai. Task $SLUG sudah dibuang."
exit 0
