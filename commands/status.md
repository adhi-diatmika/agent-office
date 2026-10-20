---
description: List open agent-office tasks in this repository (read-only)
---

# agent-office: status

Show the open agent-office tasks of this repository. This command is
read-only: do not create, change, or delete any file, and do not run git
commands that change state.

1. Find the main repository root. Run `git rev-parse --git-common-dir`; if it
   ends with `.git`, the root is its parent directory, otherwise use
   `git rev-parse --show-toplevel`.
2. Look for task folders `<root>/.claude/office/*/` that contain `meta.env`
   and do not contain a `DONE` file. Use Glob and Read.
3. For each task read from `meta.env`: TITLE, MODE, BRANCH, CREATED. Read the
   `Verdict:` and `Round:` lines from `review.md` if it exists (otherwise
   "belum direview"), and the `Status:` line from `plan.md` if it exists.
4. Show a table in Bahasa Indonesia with columns: Slug, Judul, Mode, Branch,
   Plan, Verdict terakhir. If there are no open tasks, say so.
5. For local tasks, end with how to accept or reject:
   `bash "${CLAUDE_PLUGIN_ROOT}/scripts/finish-task.sh" <slug> accept|reject`
   (run by the user from the project root, or `agent-office <slug> accept`
   if the shortcut is installed). If `${CLAUDE_PLUGIN_ROOT}` above was not
   substituted, use AGENT_OFFICE_ROOT from the session start context. For
   cloud tasks, remind the user that acceptance happens via a Pull Request.

Never use em dashes or emoji.
