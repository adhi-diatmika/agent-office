# Changelog

Semua perubahan penting pada agent-office dicatat di sini.

## [1.0.0] - 2026-10-20

### Added

- Plugin `agent-office` beserta marketplace-nya sendiri (`agent-office@agent-office`).
- Subagent `planner` (opus), `builder` (sonnet), dan `reviewer` (opus).
- Command `/agent-office:task <brief>` dan `/agent-office:status`.
- Mode local (git worktree per task, branch `office/<slug>`) dan mode cloud
  (branch sesi, push di akhir, diterima lewat Pull Request), terdeteksi otomatis.
- Script `new-task.sh`, `run-checks.sh`, `finish-task.sh`, `install-cli.sh`, `office-mode.sh`.
- Hook `SessionStart` (info mode, install dependensi di cloud) dan hook
  `PreToolUse` untuk Bash (guard terhadap push, merge, rebase, hapus branch, dan perintah berbahaya).
- Template `templates/project-settings.json` untuk mengaktifkan plugin per proyek.
- Test suite `tests/run-tests.sh`.
