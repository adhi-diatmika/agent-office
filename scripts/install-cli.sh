#!/usr/bin/env bash
# agent-office: optional, run once by the user.
# Creates ~/.local/bin/agent-office, a symlink to finish-task.sh, so tasks can
# be accepted or rejected with `agent-office <slug> accept|reject`.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="${AGENT_OFFICE_BIN_DIR:-$HOME/.local/bin}"
LINK="$BIN_DIR/agent-office"

# Prefer the marketplace clone: its path stays the same across plugin
# updates, while the versioned install directory changes on every update.
STABLE="$HOME/.claude/plugins/marketplaces/agent-office/scripts/finish-task.sh"
if [ -f "$STABLE" ]; then
  TARGET="$STABLE"
else
  TARGET="$SCRIPT_DIR/finish-task.sh"
fi

[ -f "$TARGET" ] || { printf '[agent-office] GAGAL: %s tidak ditemukan.\n' "$TARGET" >&2; exit 1; }
chmod +x "$TARGET" 2>/dev/null || true

mkdir -p "$BIN_DIR"
if [ -e "$LINK" ] && [ ! -L "$LINK" ]; then
  printf '[agent-office] GAGAL: %s sudah ada dan bukan symlink. Hapus dulu secara manual.\n' "$LINK" >&2
  exit 1
fi
ln -sf "$TARGET" "$LINK"
printf '[agent-office] Perintah terpasang: %s -> %s\n' "$LINK" "$TARGET"

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *)
    printf '[agent-office] PERINGATAN: %s belum ada di PATH.\n' "$BIN_DIR"
    printf '[agent-office] Tambahkan baris ini ke ~/.zshrc atau ~/.bashrc:\n'
    printf '  export PATH="%s:$PATH"\n' "$BIN_DIR"
    ;;
esac
printf '[agent-office] Coba jalankan: agent-office   (dari dalam folder proyek)\n'
