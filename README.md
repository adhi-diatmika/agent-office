# agent-office

Plugin Claude Code yang mengubah proyek Git apa pun menjadi "kantor" kecil berisi
tiga subagent AI:

| Peran | Agent | Model | Tugas |
| --- | --- | --- | --- |
| Perencana | `agent-office:planner` | opus | Membaca brief dan bagian proyek yang relevan, menulis `plan.md` dengan kriteria selesai yang bisa dicek. Pertanyaan yang hanya bisa dijawab user ditanyakan, tidak ditebak. |
| Pembangun | `agent-office:builder` | sonnet | Mengerjakan plan di worktree/branch task, menambah test, menjalankan pemeriksaan, lalu commit. |
| Reviewer | `agent-office:reviewer` | opus | Reviewer independen: membaca diff, menjalankan pemeriksaan, menulis `review.md` dengan verdict `ACCEPT` atau `CHANGES`. Tidak pernah mengubah kode. |

Sesi utama Claude hanya menjadi koordinator: membuat task, memanggil ketiga
agent secara bergantian (maksimal 2 ronde revisi), lalu menulis laporan.
Keputusan akhir (merge atau buang) selalu di tangan kamu.

## Instalasi

### Untuk semua proyek (sekali saja)

Di dalam sesi Claude Code:

```
/plugin marketplace add adhi-diatmika/agent-office
/plugin install agent-office@agent-office
```

Atau dari terminal:

```bash
claude plugin marketplace add adhi-diatmika/agent-office
claude plugin install agent-office@agent-office
```

Mulai sesi baru (atau jalankan `/reload-plugins`). Di awal sesi akan muncul
konteks `[agent-office] MODE=...`.

### Untuk satu proyek saja (lewat template)

Salin isi `templates/project-settings.json` ke `.claude/settings.json` di proyek
kamu (gabungkan jika file itu sudah ada), lalu commit:

```json
{
  "extraKnownMarketplaces": {
    "agent-office": {
      "source": { "source": "github", "repo": "adhi-diatmika/agent-office" }
    }
  },
  "enabledPlugins": {
    "agent-office@agent-office": true
  }
}
```

Setiap orang yang membuka proyek itu (dan mempercayai foldernya) akan
ditawari marketplace dan plugin ini secara otomatis. Lihat catatan mode cloud
di bawah: sesi Claude Code on the web tidak memasang plugin dari file ini.

## Pemakaian

### Mulai task

```
/agent-office:task Tambahkan validasi email di form registrasi beserta test-nya
```

Alurnya:

1. `new-task.sh` membuat task dan folder data task.
2. Planner menulis `plan.md`. Kalau ada keputusan yang harus kamu ambil,
   statusnya `NEEDS_DECISION` dan Claude akan bertanya. Jawabanmu ditambahkan
   ke `brief.md`, lalu planner dijalankan lagi.
3. Builder mengerjakan plan dan commit di branch task.
4. Reviewer memeriksa. Jika `CHANGES`, builder memperbaiki dan reviewer
   memeriksa ulang (maksimal 2 ronde revisi).
5. Claude menulis `report.md` dan menampilkannya.

### Lihat task yang masih terbuka

```
/agent-office:status
```

### Terima atau tolak task (mode local)

Laporan akhir selalu berisi perintah lengkap dengan path absolut. Bentuknya:

```bash
cd /path/ke/proyek
bash <AGENT_OFFICE_ROOT>/scripts/finish-task.sh                      # daftar task terbuka
bash <AGENT_OFFICE_ROOT>/scripts/finish-task.sh <slug> accept        # merge --no-ff ke branch asal
bash <AGENT_OFFICE_ROOT>/scripts/finish-task.sh <slug> reject        # buang worktree dan branch
```

`accept` menolak jalan jika worktree task masih kotor, jika kamu tidak sedang
berada di branch asal (`BASE_BRANCH`), atau jika working tree utama punya
perubahan yang belum di-commit. Sebelum merge, diff stat ditampilkan dan kamu
diminta konfirmasi `y/N`.

Agent tidak bisa menjalankan `finish-task.sh`; hook guard memblokirnya.

### Shortcut `agent-office` (opsional)

Jalankan sekali:

```bash
bash ~/.claude/plugins/marketplaces/agent-office/scripts/install-cli.sh
```

Script ini membuat symlink `~/.local/bin/agent-office` ke `finish-task.sh` dan
memberi peringatan jika `~/.local/bin` belum ada di `PATH`. Setelah itu:

```bash
agent-office                    # daftar task
agent-office <slug> accept
agent-office <slug> reject
```

## Mode local dan cloud

Mode dideteksi otomatis oleh `scripts/office-mode.sh`:

1. Variabel `OFFICE_MODE` (`local` atau `cloud`) menang jika di-set.
2. Jika tidak, `CLAUDE_CODE_REMOTE=true` berarti cloud.
3. Selain itu local.

| | local | cloud |
| --- | --- | --- |
| Workspace | git worktree per task di `.claude/worktrees/<slug>` | root repo di sandbox |
| Branch | branch baru `office/<slug>` | branch sesi saat ini (jika sedang di `main`, `master`, `develop`, atau `trunk`, dibuat `office/<slug>`) |
| Task paralel | bisa | satu task per sesi |
| Akhir task | tidak ada push | commit, lalu `git push -u origin <BRANCH>` |
| Cara kamu menerima | `finish-task.sh` | Pull Request di GitHub |

Data per task ada di `<repo>/.claude/office/<slug>/`: `brief.md`, `plan.md`,
`review.md`, `report.md`, `meta.env` (dan `DONE` setelah selesai). Proyek
tidak perlu diubah atau di-commit apa pun: `new-task.sh` menambahkan
`/.claude/office/` dan `/.claude/worktrees/` ke `.git/info/exclude` (sekali
saja, tidak dobel).

### Catatan penting untuk Claude Code on the web

Menurut dokumentasi resmi, sesi cloud **tidak** memasang plugin yang
diaktifkan lewat `.claude/settings.json` repo maupun lewat user settings,
dan perintah `/plugin` tidak tersedia di sesi cloud. Jadi template di atas
belum cukup untuk sesi web. Pilihan yang bisa dicoba:

- Tambahkan ke setup script environment cloud kamu (belum diverifikasi):

  ```bash
  claude plugin marketplace add adhi-diatmika/agent-office
  claude plugin install agent-office@agent-office
  ```

- Atau salin `agents/`, `commands/`, dan hook ke folder `.claude/` di repo
  (komponen di `.claude/` repo ikut termuat di sesi cloud).

Di sesi cloud, hook SessionStart juga mencoba memasang dependensi proyek
(tanpa mengubah lockfile) dan menulis log ke `/tmp/agent-office-install.log`.

## Pemeriksaan (checks)

`scripts/run-checks.sh [dir]` dipakai builder dan reviewer:

- Jika ada `.claude/checks.sh` di proyek, **hanya** file itu yang dijalankan.
  Cocok untuk proyek dengan perintah khusus, contoh:

  ```bash
  # .claude/checks.sh
  set -e
  make lint
  make test
  ```

- Jika tidak ada, toolchain dideteksi otomatis: Node (npm/pnpm/yarn/bun sesuai
  lockfile; script `lint`, `typecheck`, `test`; `tsc --noEmit` jika ada
  `tsconfig.json` tanpa script typecheck), Python (ruff, mypy jika
  dikonfigurasi, pytest; memakai `.venv` jika ada), Go (`vet`, `test`), Rust
  (`clippy -D warnings`, `test`), Swift (`build`, `test`), PHP (composer,
  phpunit).
- Dependensi hanya dipasang jika belum ada, dan tanpa mengubah lockfile
  (`npm ci`, `npm install --no-package-lock`, `--frozen-lockfile`).
- Setiap langkah dicetak `PASS` atau `FAIL` (60 baris log terakhir saat gagal),
  diakhiri blok `===== CHECK SUMMARY =====`. Exit non-zero jika ada yang gagal.

## Mengubah model dan batas revisi

Plugin yang terpasang ada di cache dan akan tertimpa saat update, jadi cara
yang aman adalah fork repo ini, lalu ubah:

- Model: baris `model:` di `agents/planner.md`, `agents/builder.md`,
  `agents/reviewer.md` (misalnya `opus`, `sonnet`, `haiku`, atau `inherit`).
- Batas ronde revisi: `MAX_REVISION_ROUNDS = 2` di `commands/task.md`.

Naikkan `version` di `.claude-plugin/plugin.json`, lalu pasang dari fork kamu
(`/plugin marketplace add <user>/agent-office`).

## Update plugin

```
/plugin marketplace update agent-office
```

atau dari terminal `claude plugin marketplace update agent-office`, lalu mulai
sesi baru. Jika kamu memakai shortcut `agent-office`, symlink-nya mengarah ke
salinan marketplace sehingga tetap berlaku setelah update. Jika tidak,
jalankan `install-cli.sh` lagi.

## Keamanan

- Hook `PreToolUse` (`hooks/guard-bash.sh`) adalah **pagar pengaman, bukan
  sandbox**. Ia memblokir (exit 2) perintah Bash seperti `git push` di mode
  local, force push dan push ke branch terlindungi di mode cloud, `git merge`,
  `pull`, `rebase`, `cherry-pick`, `reset --hard`, `clean -f`, hapus branch
  atau worktree, checkout ke branch terlindungi, memindahkan atau menimpa
  branch terlindungi (`branch -f/-M`, `update-ref`, `fetch x:main`),
  `gh pr merge/close`, `sudo`, `rm -r` ke `/`, `~`, `$HOME`, atau `..`,
  `curl | sh`, dan `npm publish`. Guard juga memeriksa perintah di dalam
  `$(...)`, `bash -c`, wrapper seperti `env`/`timeout`/`xargs`, dan here-doc
  yang dikirim ke shell, serta mengikuti `cd` di perintah yang sama.
  Perintah yang disamarkan dengan cukup kreatif tetap bisa lolos. Tetap review
  hasilnya sebelum menerima.
- `git pull` diblokir untuk agent karena sama dengan merge atau rebase. Pakai
  `git fetch` jika perlu melihat perubahan terbaru.
- Guard berlaku di **semua** sesi tempat plugin aktif, termasuk saat kamu
  bekerja biasa dengan Claude. Untuk mematikannya sementara, set
  `AGENT_OFFICE_GUARD=off` di environment Claude Code (misalnya lewat `env`
  di settings), bukan di perintah Bash.
- Daftar branch terlindungi bisa diubah lewat `AGENT_OFFICE_PROTECTED`
  (default `main master develop trunk`).
- Tiga subagent dengan model opus dan sonnet memakai **kuota lebih banyak**
  daripada satu sesi biasa. Pakai untuk task yang memang layak direncanakan
  dan direview.

## Pengembangan

```bash
bash tests/run-tests.sh          # semua test (butuh git, jq, node)
claude plugin validate .         # validasi marketplace dan plugin
claude --plugin-dir .            # coba plugin tanpa memasang
```

## Lisensi

MIT. Lihat [LICENSE](LICENSE).
