#!/usr/bin/env bash
# agent-office PreToolUse hook for the Bash tool.
#
# Reads the hook input JSON on stdin, inspects tool_input.command, and exits
# with code 2 (block) plus a message on stderr when the command is not allowed
# for agents. Exit 0 lets the command run.
#
# This is a guardrail against mistakes, not a sandbox.
# Set AGENT_OFFICE_GUARD=off in the Claude Code environment to disable it.
set -u
set -f

ROOT="${CLAUDE_PLUGIN_ROOT:-}"
if [ -z "$ROOT" ] || [ ! -d "$ROOT/scripts" ]; then
  ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fi
# shellcheck source=../scripts/office-mode.sh
. "$ROOT/scripts/office-mode.sh"

INPUT="$(cat)"

[ "${AGENT_OFFICE_GUARD:-on}" = "off" ] && exit 0

json_field() {
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$INPUT" | jq -r "$1 // empty" 2>/dev/null
  elif command -v python3 >/dev/null 2>&1; then
    printf '%s' "$INPUT" | python3 -c '
import json, sys
try:
    v = json.load(sys.stdin)
    for k in sys.argv[1].lstrip(".").split("."):
        v = v.get(k) if isinstance(v, dict) else None
    sys.stdout.write("" if v is None else str(v))
except Exception:
    pass
' "$1"
  else
    printf '[agent-office] PERINGATAN: jq dan python3 tidak ada, guard dilewati.\n' >&2
    exit 0
  fi
}

COMMAND="$(json_field .tool_input.command)"
HOOK_CWD="$(json_field .cwd)"
[ -n "$HOOK_CWD" ] && [ -d "$HOOK_CWD" ] || HOOK_CWD="$PWD"
[ -n "$COMMAND" ] || exit 0

MODE="$(office_mode)"

block() {
  printf 'BLOCKED by agent-office (%s): %s\n' "$MODE" "$1" >&2
  exit 2
}

# Split a shell command into words and separators, honoring quotes.
# Output: one item per line, "W<word>" for words and "S" for separators
# (; & | ( ) and newlines). Quotes are removed from words.
tokenize() {
  awk '
    { buf = buf $0 "\n" }
    END {
      n = length(buf); word = ""; inword = 0; q = ""
      for (i = 1; i <= n; i++) {
        c = substr(buf, i, 1)
        if (q == "\047") {
          if (c == "\047") { q = "" } else { word = word (c == "\n" ? " " : c) }
          continue
        }
        if (q == "\"") {
          if (c == "\\") {
            d = substr(buf, i + 1, 1)
            if (d == "\"" || d == "\\" || d == "$" || d == "`") { word = word d; i++ }
            else { word = word c }
          } else if (c == "\"") { q = "" }
          else { word = word (c == "\n" ? " " : c) }
          continue
        }
        if (c == "\\") {
          d = substr(buf, i + 1, 1); i++
          if (d != "\n") { word = word d; inword = 1 }
          continue
        }
        if (c == "\047" || c == "\"") { q = c; inword = 1; continue }
        if (c == " " || c == "\t") {
          if (inword) { print "W" word; word = ""; inword = 0 }
          continue
        }
        if (c == "#" && !inword) {
          while (i <= n && substr(buf, i, 1) != "\n") i++
          i--
          continue
        }
        if (c == ";" || c == "&" || c == "|" || c == "(" || c == ")" || c == "\n" || c == "`") {
          if (c == "(" && word == "$") { word = ""; inword = 0 }
          if (inword) { print "W" word; word = ""; inword = 0 }
          print "S"
          continue
        }
        word = word c; inword = 1
      }
      if (inword) print "W" word
    }
  '
}

is_shell() {
  case "$1" in
    sh|bash|zsh|dash|ksh) return 0 ;;
  esac
  return 1
}

# Strip a remote prefix such as origin/main -> main when "origin" is a remote.
strip_remote() {
  local ref="$1" dir="$2" r
  case "$ref" in
    */*)
      for r in $(git -C "$dir" remote 2>/dev/null); do
        case "$ref" in
          "$r"/*) printf '%s' "${ref#"$r"/}"; return ;;
        esac
      done
      ;;
  esac
  printf '%s' "$ref"
}

short_cluster_has() {
  # short_cluster_has <token> <letters>: -xyz style token containing any letter.
  case "$1" in
    --*|-) return 1 ;;
    -*) ;;
    *) return 1 ;;
  esac
  case "$1" in
    *[$2]*) return 0 ;;
  esac
  return 1
}

check_git() {
  # $@ = words after "git"
  local dir="$HOOK_CWD" sub="" t
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -C)
        shift
        case "${1:-}" in
          /*) dir="$1" ;;
          *) dir="$HOOK_CWD/${1:-}" ;;
        esac
        ;;
      -c|--git-dir|--work-tree|--namespace|--config-env|--super-prefix) shift ;;
      -*) ;;
      *) sub="$1"; shift; break ;;
    esac
    [ "$#" -gt 0 ] && shift
  done
  [ -n "$sub" ] || return 0

  case "$sub" in
    merge|rebase|cherry-pick)
      for t in "$@"; do
        case "$t" in --abort|--quit) return 0 ;; esac
      done
      block "git $sub tidak diizinkan untuk agent. Penggabungan dilakukan oleh user."
      ;;
    reset)
      for t in "$@"; do
        [ "$t" = "--hard" ] && block "git reset --hard dapat menghapus pekerjaan. Tidak diizinkan."
      done
      ;;
    clean)
      for t in "$@"; do
        if [ "$t" = "--force" ] || short_cluster_has "$t" f; then
          block "git clean -f menghapus file yang belum di-track. Tidak diizinkan."
        fi
      done
      ;;
    branch)
      for t in "$@"; do
        if [ "$t" = "--delete" ] || short_cluster_has "$t" dD; then
          block "menghapus branch (git branch -d/-D) tidak diizinkan untuk agent."
        fi
      done
      ;;
    worktree)
      for t in "$@"; do
        case "$t" in
          -*) ;;
          remove|prune) block "git worktree $t tidak diizinkan. Worktree dikelola oleh finish-task.sh (user)." ;;
          *) break ;;
        esac
      done
      ;;
    checkout|switch)
      check_switch "$dir" "$sub" "$@"
      ;;
    push)
      check_push "$dir" "$@"
      ;;
  esac
  return 0
}

check_switch() {
  local dir="$1" sub="$2" newbranch="" expect_new=0 first="" saw_dashdash=0 after_dashdash=0 t
  shift 2
  for t in "$@"; do
    if [ "$expect_new" = "1" ]; then
      newbranch="$t"; expect_new=0; continue
    fi
    if [ "$saw_dashdash" = "1" ]; then
      after_dashdash=1; continue
    fi
    case "$t" in
      -b|-B|-c|-C|--orphan) expect_new=1 ;;
      --) saw_dashdash=1 ;;
      -*) ;;
      *) [ -z "$first" ] && first="$t" ;;
    esac
  done
  if [ -n "$newbranch" ]; then
    office_is_protected "$newbranch" \
      && block "membuat branch terlindungi '$newbranch' tidak diizinkan."
    return 0
  fi
  # "git checkout <ref> -- <paths>" restores files and does not switch.
  [ "$after_dashdash" = "1" ] && return 0
  [ -n "$first" ] || return 0
  if office_is_protected "$(strip_remote "$first" "$dir")"; then
    block "git $sub ke branch terlindungi '$first' tidak diizinkan. Agent bekerja di branch task."
  fi
  return 0
}

check_push() {
  local dir="$1" t remote="" refspec dst src cur expect_arg=0
  local refspecs=""
  shift
  if [ "$MODE" = "local" ]; then
    block "git push tidak diizinkan di mode local. User yang menerima task lewat finish-task.sh."
  fi
  for t in "$@"; do
    if [ "$expect_arg" = "1" ]; then expect_arg=0; continue; fi
    case "$t" in
      -f|--force|--force-with-lease|--force-with-lease=*|--force-if-includes)
        block "force push ($t) tidak diizinkan." ;;
      -d|--delete) block "menghapus branch remote ($t) tidak diizinkan." ;;
      --all|--mirror|--prune|--tags) block "git push $t tidak diizinkan." ;;
      -o|--push-option|--repo|--receive-pack|--exec) expect_arg=1 ;;
      --*) ;;
      -*)
        if short_cluster_has "$t" fd; then
          block "git push $t (force/delete) tidak diizinkan."
        fi
        ;;
      *)
        if [ -z "$remote" ]; then
          remote="$t"
        else
          refspecs="$refspecs $t"
        fi
        ;;
    esac
  done

  if git -C "$dir" rev-parse --git-dir >/dev/null 2>&1; then
    cur="$(office_current_branch "$dir")"
    [ -n "$cur" ] || block "git push dari detached HEAD tidak diizinkan."
    office_is_protected "$cur" \
      && block "git push dari branch terlindungi '$cur' tidak diizinkan. Gunakan branch sesi atau office/<slug>."
  else
    cur=""
  fi

  for refspec in $refspecs; do
    case "$refspec" in
      +*) block "force push lewat refspec '$refspec' tidak diizinkan." ;;
      :*) block "menghapus branch remote lewat refspec '$refspec' tidak diizinkan." ;;
    esac
    case "$refspec" in
      *:*) src="${refspec%%:*}"; dst="${refspec#*:}" ;;
      *) src="$refspec"; dst="$refspec" ;;
    esac
    [ "$dst" = "HEAD" ] && dst="$cur"
    dst="${dst#refs/heads/}"
    if office_is_protected "$dst"; then
      block "git push ke branch terlindungi '$dst' tidak diizinkan."
    fi
    : "$src"
  done
  return 0
}

check_rm() {
  local recursive=0 t targets="" end_opts=0
  for t in "$@"; do
    if [ "$end_opts" = "0" ]; then
      case "$t" in
        --) end_opts=1; continue ;;
        -r|-R|--recursive) recursive=1; continue ;;
        --*) continue ;;
        -*) short_cluster_has "$t" rR && recursive=1; continue ;;
      esac
    fi
    case "$t" in
      /|/\*|//|"~"|"~/"|"~/*"|'$HOME'|'$HOME/'|'$HOME/*'|'${HOME}'|'${HOME}/'|'${HOME}/*'|..|../|../\*|../*)
        targets="$targets $t" ;;
    esac
  done
  if [ "$recursive" = "1" ] && [ -n "$targets" ]; then
    block "rm rekursif ke target berbahaya (${targets# }) tidak diizinkan."
  fi
  return 0
}

check_positional_is() {
  # check_positional_is <expected first positional> <words...>
  local want="$1" t expect_arg=0
  shift
  for t in "$@"; do
    if [ "$expect_arg" = "1" ]; then expect_arg=0; continue; fi
    case "$t" in
      -R|--repo) expect_arg=1 ;;
      -*) ;;
      *) [ "$t" = "$want" ]; return ;;
    esac
  done
  return 1
}

check_gh() {
  local t expect_arg=0 seen_pr=0
  for t in "$@"; do
    if [ "$expect_arg" = "1" ]; then expect_arg=0; continue; fi
    case "$t" in
      -R|--repo) expect_arg=1 ;;
      -*) ;;
      *)
        if [ "$seen_pr" = "1" ]; then
          case "$t" in
            merge|close) block "gh pr $t tidak diizinkan. Keputusan PR ada di tangan user." ;;
          esac
          return 0
        fi
        [ "$t" = "pr" ] || return 0
        seen_pr=1
        ;;
    esac
  done
  return 0
}

# check_segment <words...>: one simple command.
check_segment() {
  local cmd base t
  # Skip environment assignments and transparent wrappers.
  while [ "$#" -gt 0 ]; do
    case "$1" in
      [A-Za-z_]*=*) shift ;;
      env|command|builtin|exec|nohup|time|nice|then|do|else|"!"|"{") shift ;;
      timeout) shift; [ "$#" -gt 0 ] && shift ;;
      *) break ;;
    esac
  done
  [ "$#" -gt 0 ] || return 0
  cmd="$1"
  shift
  base="${cmd##*/}"

  case "$base" in
    sudo|doas) block "sudo tidak diizinkan." ;;
    finish-task.sh|agent-office)
      block "finish-task.sh hanya boleh dijalankan oleh user, bukan agent." ;;
    git) check_git "$@" ;;
    gh) check_gh "$@" ;;
    rm) check_rm "$@" ;;
    npm|pnpm|yarn|bun)
      if check_positional_is publish "$@"; then
        block "$base publish tidak diizinkan."
      fi
      ;;
    source|.)
      case "${1:-}" in
        *finish-task.sh) block "finish-task.sh hanya boleh dijalankan oleh user, bukan agent." ;;
      esac
      ;;
    eval)
      check_string "$*"
      ;;
  esac

  if is_shell "$base"; then
    local expect_c=0
    for t in "$@"; do
      if [ "$expect_c" = "1" ]; then
        check_string "$t"
        expect_c=0
        continue
      fi
      case "$t" in
        -c|-*c) expect_c=1 ;;
        *finish-task.sh) block "finish-task.sh hanya boleh dijalankan oleh user, bukan agent." ;;
      esac
    done
  fi
  return 0
}

# check_string <command string>: tokenize and check every simple command.
# Runs in a subshell per call so recursion does not clobber state; a block
# inside exits that subshell with 2, which is propagated here.
check_string() {
  local rc
  (
    words=()
    count=0
    while IFS= read -r item; do
      case "$item" in
        S)
          if [ "$count" -gt 0 ]; then
            check_segment "${words[@]}"
          fi
          words=()
          count=0
          ;;
        W*)
          words[$count]="${item#W}"
          count=$((count + 1))
          ;;
      esac
    done <<EOF_TOKENS
$(printf '%s\n' "$1" | tokenize)
EOF_TOKENS
    if [ "$count" -gt 0 ]; then
      check_segment "${words[@]}"
    fi
    exit 0
  )
  rc=$?
  [ "$rc" -eq 2 ] && exit 2
  return 0
}

# Pipelines that download and execute a script.
FLAT="$(printf '%s' "$COMMAND" | tr '\n\t' '  ' | tr -s ' ')"
if printf '%s' "$FLAT" | grep -Eq '(curl|wget)[^|;&]*\|[[:space:]]*(sudo[[:space:]]+)?(env[[:space:]]+)?([^[:space:]|]*/)?(ba|z|da|k)?sh([[:space:]]|$)'; then
  block "mengunduh lalu menjalankan skrip (curl/wget | sh) tidak diizinkan."
fi
if printf '%s' "$FLAT" | grep -Eq '(ba|z|da|k)?sh[[:space:]]+(-c[[:space:]]+)?["'"'"']?(<\(|\$\()[[:space:]]*(curl|wget)'; then
  block "mengunduh lalu menjalankan skrip (sh <(curl ...)) tidak diizinkan."
fi

check_string "$COMMAND"
exit 0
