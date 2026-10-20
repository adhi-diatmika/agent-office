#!/usr/bin/env bash
# agent-office: run the project's checks (lint, typecheck, tests).
#
# Usage:
#   run-checks.sh [dir]                 run checks in dir (default: current dir)
#   run-checks.sh --install-only [dir]  only install missing dependencies
#
# If <dir>/.claude/checks.sh exists, only that file is run. Otherwise the
# toolchain is auto-detected. Dependencies are installed only when missing,
# and never in a way that changes lockfiles.
set -u

INSTALL_ONLY=0
if [ "${1:-}" = "--install-only" ]; then
  INSTALL_ONLY=1
  shift
fi

DIR="${1:-.}"
[ -d "$DIR" ] || { printf '[agent-office] Folder tidak ditemukan: %s\n' "$DIR" >&2; exit 1; }
DIR="$(cd "$DIR" && pwd)"
cd "$DIR" || exit 1

# Keep test runners out of watch mode.
export CI="${CI:-1}"

LOG_DIR="$(mktemp -d "${TMPDIR:-/tmp}/agent-office-checks.XXXXXX")"
trap 'rm -rf "$LOG_DIR"' EXIT

STEP_NAMES=()
STEP_RESULTS=()
STEP_COUNT=0
FAILED=0

have() { command -v "$1" >/dev/null 2>&1; }

record() {
  STEP_NAMES[$STEP_COUNT]="$1"
  STEP_RESULTS[$STEP_COUNT]="$2"
  STEP_COUNT=$((STEP_COUNT + 1))
}

# run_step <name> <command...>
run_step() {
  local name="$1" log
  shift
  log="$LOG_DIR/step-$STEP_COUNT.log"
  printf -- '----- %s: %s\n' "$name" "$*"
  if "$@" >"$log" 2>&1; then
    printf 'PASS  %s\n' "$name"
    record "$name" PASS
  else
    printf 'FAIL  %s\n' "$name"
    printf -- '----- 60 baris terakhir log %s -----\n' "$name"
    tail -n 60 "$log"
    printf -- '----- akhir log -----\n'
    record "$name" FAIL
    FAILED=1
  fi
}

skip_step() {
  printf 'SKIP  %s (%s)\n' "$1" "$2"
  record "$1" SKIP
}

# missing_step <name> <reason>: a required tool is missing. Counts as FAIL,
# because otherwise a run where nothing was tested would report PASS.
missing_step() {
  printf 'FAIL  %s (%s)\n' "$1" "$2"
  record "$1" FAIL
  FAILED=1
}

# has_files <find args...>: true when a matching file exists outside
# dependency and VCS folders.
has_files() {
  [ -n "$(find . \( -name node_modules -o -name .venv -o -name venv -o -name .git -o -name vendor \) -prune -o "$@" -print 2>/dev/null | head -n 1)" ]
}

# ---------- Node ----------

node_pm() {
  if [ -f pnpm-lock.yaml ]; then echo pnpm
  elif [ -f yarn.lock ]; then echo yarn
  elif [ -f bun.lockb ] || [ -f bun.lock ]; then echo bun
  else echo npm
  fi
}

# json_has <file> <dotted.path>: true when the key exists and is not empty.
json_has() {
  if have node; then
    node -e '
      const fs = require("fs");
      let v = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
      for (const k of process.argv[2].split(".")) { v = v == null ? undefined : v[k]; }
      const empty = v == null || (typeof v === "object" && Object.keys(v).length === 0);
      process.exit(empty ? 1 : 0);
    ' "$1" "$2" 2>/dev/null
  elif have jq; then
    jq -e --arg p "$2" 'getpath($p | split(".")) | select(. != null and . != {} and . != "")' "$1" >/dev/null 2>&1
  elif have python3; then
    python3 -c '
import json, sys
v = json.load(open(sys.argv[1]))
for k in sys.argv[2].split("."):
    v = v.get(k) if isinstance(v, dict) else None
sys.exit(0 if v else 1)
' "$1" "$2" 2>/dev/null
  else
    return 1
  fi
}

node_has_deps() {
  json_has package.json dependencies || json_has package.json devDependencies \
    || json_has package.json optionalDependencies
}

node_install() {
  local pm
  pm="$(node_pm)"
  [ -d node_modules ] && return 0
  node_has_deps || return 0
  have "$pm" || { missing_step "node: install" "$pm tidak terpasang"; return 0; }
  case "$pm" in
    npm)
      if [ -f package-lock.json ] || [ -f npm-shrinkwrap.json ]; then
        run_step "node: install (npm ci)" npm ci
      else
        run_step "node: install (npm, tanpa lockfile)" npm install --no-package-lock
      fi
      ;;
    pnpm) run_step "node: install (pnpm)" pnpm install --frozen-lockfile ;;
    yarn)
      if [ -f .yarnrc.yml ]; then
        run_step "node: install (yarn)" yarn install --immutable
      else
        run_step "node: install (yarn)" yarn install --frozen-lockfile
      fi
      ;;
    bun) run_step "node: install (bun)" bun install --frozen-lockfile ;;
  esac
}

node_checks() {
  local pm s
  pm="$(node_pm)"
  if ! have "$pm"; then
    missing_step "node" "$pm tidak terpasang"
    return 0
  fi
  for s in lint typecheck test; do
    if json_has package.json "scripts.$s"; then
      run_step "node: $s" "$pm" run "$s"
    fi
  done
  if [ -f tsconfig.json ] && ! json_has package.json scripts.typecheck; then
    if [ -x node_modules/.bin/tsc ]; then
      run_step "node: tsc --noEmit" node_modules/.bin/tsc --noEmit
    else
      skip_step "node: tsc --noEmit" "typescript belum terpasang di node_modules"
    fi
  fi
}

# ---------- Python ----------

is_python() {
  [ -f pyproject.toml ] || [ -f setup.py ] || [ -f setup.cfg ] || [ -f requirements.txt ]
}

python_bin() {
  if [ -x .venv/bin/python ]; then echo .venv/bin/python
  elif have python3; then echo python3
  elif have python; then echo python
  fi
}

py_has_module() { "$1" -c "import $2" >/dev/null 2>&1; }

python_install() {
  # Only lockfile driven installs that cannot change the lockfile.
  if [ ! -d .venv ] && [ -f uv.lock ] && have uv; then
    run_step "python: install (uv sync --frozen)" uv sync --frozen
  fi
}

mypy_configured() {
  [ -f mypy.ini ] || [ -f .mypy.ini ] \
    || { [ -f pyproject.toml ] && grep -q '^\[tool\.mypy' pyproject.toml; } \
    || { [ -f setup.cfg ] && grep -q '^\[mypy' setup.cfg; }
}

python_checks() {
  local py
  py="$(python_bin)"
  if [ -z "$py" ]; then
    missing_step "python" "python tidak ditemukan"
    return 0
  fi
  if py_has_module "$py" ruff; then
    run_step "python: ruff" "$py" -m ruff check .
  elif have ruff; then
    run_step "python: ruff" ruff check .
  fi
  if mypy_configured; then
    if py_has_module "$py" mypy; then
      run_step "python: mypy" "$py" -m mypy .
    else
      missing_step "python: mypy" "mypy dikonfigurasi tetapi belum terpasang"
    fi
  fi
  if py_has_module "$py" pytest; then
    run_step "python: pytest" "$py" -m pytest -q
  elif [ -d tests ] || [ -d test ] || has_files -name 'test_*.py' -o -name '*_test.py'; then
    missing_step "python: pytest" "ada file test tetapi pytest belum terpasang"
  else
    skip_step "python: pytest" "pytest belum terpasang dan tidak ada file test"
  fi
}

# ---------- PHP ----------

php_install() {
  [ -d vendor ] && return 0
  [ -f composer.lock ] || return 0
  have composer || { missing_step "php: install" "composer tidak terpasang"; return 0; }
  run_step "php: install (composer)" composer install --no-interaction --no-progress
}

php_checks() {
  if [ -x vendor/bin/phpunit ]; then
    run_step "php: phpunit" vendor/bin/phpunit
  elif have phpunit; then
    run_step "php: phpunit" phpunit
  elif [ -f phpunit.xml ] || [ -f phpunit.xml.dist ] || [ -d tests ]; then
    missing_step "php: phpunit" "ada test tetapi phpunit belum terpasang"
  else
    skip_step "php: phpunit" "phpunit belum terpasang dan tidak ada test"
  fi
}

# ---------- Main ----------

DETECTED=""

if [ "$INSTALL_ONLY" = "1" ]; then
  [ -f package.json ] && node_install
  is_python && python_install
  [ -f composer.json ] && php_install
  [ "$STEP_COUNT" -eq 0 ] && printf '[agent-office] Tidak ada dependensi yang perlu dipasang.\n'
  exit "$FAILED"
fi

if [ -f .claude/checks.sh ]; then
  DETECTED="custom"
  run_step "custom: .claude/checks.sh" bash .claude/checks.sh
else
  if [ -f package.json ]; then
    DETECTED="$DETECTED node"
    node_install
    node_checks
  fi
  if is_python; then
    DETECTED="$DETECTED python"
    python_install
    python_checks
  fi
  if [ -f go.mod ]; then
    DETECTED="$DETECTED go"
    if have go; then
      run_step "go: vet" go vet ./...
      run_step "go: test" go test ./...
    else
      missing_step "go" "go tidak terpasang"
    fi
  fi
  if [ -f Cargo.toml ]; then
    DETECTED="$DETECTED rust"
    if have cargo; then
      if cargo clippy --version >/dev/null 2>&1; then
        run_step "rust: clippy" cargo clippy --all-targets -- -D warnings
      else
        skip_step "rust: clippy" "clippy tidak terpasang"
      fi
      run_step "rust: test" cargo test
    else
      missing_step "rust" "cargo tidak terpasang"
    fi
  fi
  if [ -f Package.swift ]; then
    DETECTED="$DETECTED swift"
    if have swift; then
      run_step "swift: build" swift build
      run_step "swift: test" swift test
    else
      missing_step "swift" "swift tidak terpasang"
    fi
  fi
  if [ -f composer.json ]; then
    DETECTED="$DETECTED php"
    php_install
    php_checks
  fi
fi

if [ -z "$DETECTED" ]; then
  printf '[agent-office] Tidak ada pemeriksaan yang terdeteksi di %s.\n' "$DIR"
  printf '[agent-office] Tambahkan .claude/checks.sh untuk pemeriksaan kustom.\n'
  printf '===== CHECK SUMMARY =====\n'
  printf 'No checks detected\n'
  printf 'Result: PASS\n'
  exit 0
fi

printf '\n===== CHECK SUMMARY =====\n'
printf 'Directory: %s\n' "$DIR"
printf 'Detected: %s\n' "${DETECTED# }"
i=0
while [ "$i" -lt "$STEP_COUNT" ]; do
  printf '%-5s %s\n' "${STEP_RESULTS[$i]}" "${STEP_NAMES[$i]}"
  i=$((i + 1))
done
if [ "$FAILED" = "1" ]; then
  printf 'Result: FAIL\n'
  exit 1
fi
printf 'Result: PASS\n'
exit 0
