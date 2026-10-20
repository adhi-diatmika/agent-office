---
description: Run a task through the office (planner, builder, independent reviewer)
argument-hint: <brief>
---

# agent-office: task

You are the coordinator of a small office of subagents. You never write or
edit project code yourself. You only run the office scripts, write files in
the task folder (brief.md, report.md), talk to the user, and delegate to the
subagents `agent-office:planner`, `agent-office:builder`, and
`agent-office:reviewer`.

Settings:

- MAX_REVISION_ROUNDS = 2 (revision rounds after the first review)

The user's brief:

<brief>
$ARGUMENTS
</brief>

If the brief is empty, ask the user what they want done and stop.

## Script paths

PLUGIN_ROOT is `${CLAUDE_PLUGIN_ROOT}`. If that text still starts with `${`
(it was not substituted), use the `AGENT_OFFICE_ROOT=<path>` value from the
`[agent-office]` session start context instead. If neither is available,
stop and tell the user the plugin root could not be found.

- NEW_TASK = `<PLUGIN_ROOT>/scripts/new-task.sh`
- RUN_CHECKS = `<PLUGIN_ROOT>/scripts/run-checks.sh`
- FINISH_TASK = `<PLUGIN_ROOT>/scripts/finish-task.sh`

Always pass absolute script paths to subagents. Environment variables such as
CLAUDE_PLUGIN_ROOT do not exist inside Bash tool calls.

## Steps

1. **Create the task.** Pick a short English title (2 to 6 words, letters,
   digits, and spaces only) that summarizes the brief. Run, from the project
   root:
   `bash "<NEW_TASK>" '<title>'`
   Parse the KEY=VALUE output: MODE, TASK_DIR, WORKTREE, BRANCH, BASE_COMMIT.
   If it fails, show the error to the user and stop.
   Then write the brief verbatim (exactly the text inside `<brief>`) to
   `<TASK_DIR>/brief.md`.

2. **Plan.** Call the `agent-office:planner` subagent. Prompt it with
   TASK_DIR, WORKTREE, MODE, BRANCH, BASE_COMMIT. When it returns, read
   `<TASK_DIR>/plan.md`.
   - `Status: NEEDS_DECISION`: show the user the questions from
     "Questions for user" and wait for answers. Append them to brief.md under
     a heading `## Answers from user` (keep earlier text unchanged), then run
     the planner again. Repeat until READY.
   - `Status: READY`: show the user a short summary (goal and done criteria)
     and continue without waiting.

3. **Build.** Call the `agent-office:builder` subagent with TASK_DIR,
   WORKTREE, BRANCH, MODE, and RUN_CHECKS.

4. **Review.** Call the `agent-office:reviewer` subagent with TASK_DIR,
   WORKTREE, BASE_COMMIT, RUN_CHECKS, and ROUND (starts at 1). Read the
   `Verdict:` line of `<TASK_DIR>/review.md`.

5. **Revise.** On `Verdict: CHANGES`, run the builder again (it fixes the
   "Must fix" items first) and then the reviewer with ROUND increased by one.
   Do at most MAX_REVISION_ROUNDS revision rounds. If the verdict is still
   CHANGES after that, stop the loop and explain to the user exactly what is
   stuck (the remaining Must fix items).
   If the builder reports that the plan is wrong, stop and ask the user.

6. **Cloud only (MODE=cloud).** Make sure everything is committed:
   `git -C "<WORKTREE>" status --porcelain` must be empty. If not, ask the
   builder to commit. Then run:
   `git -C "<WORKTREE>" push -u origin <BRANCH>`
   Retry up to 3 times on network errors. Never push to any other branch.

7. **Report.** Write `<TASK_DIR>/report.md` in Bahasa Indonesia using this
   template, then show its full content to the user:

   ```
   # Report: <title>
   Final verdict: ACCEPT | CHANGES (stopped at round n)
   Mode: <local|cloud>   Branch: <BRANCH>
   ## Changes
   ## Check results
   ## How to test
   ## Reviewer notes
   ```

   - local: end the report with the exact commands, using absolute paths, to
     accept or reject:
     `cd "<project root>" && bash "<FINISH_TASK>" <slug> accept`
     `cd "<project root>" && bash "<FINISH_TASK>" <slug> reject`
     and mention the shortcut `agent-office <slug> accept|reject` if the user
     installed it with install-cli.sh. The slug is the last part of TASK_DIR.
     You must never run finish-task.sh yourself; it is for the user only.
   - cloud: tell the user to open a Pull Request from BRANCH on GitHub and to
     use the report as the PR description, because this sandbox is
     discarded when the session ends.

## Rules

- Never edit project code, never merge, never rebase, never delete branches
  or worktrees. The guard hook blocks these anyway.
- Keep your own messages to the user short and in Bahasa Indonesia.
- Never use em dashes or emoji.
