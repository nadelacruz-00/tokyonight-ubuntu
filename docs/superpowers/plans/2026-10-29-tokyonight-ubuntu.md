# tokyonight-ubuntu Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A public, idempotent, reversible `install.sh` that reproduces the Rewaita Tokyo Night desktop (GTK, Shell, Ptyxis, fonts, prompt, tool themes, wallpaper, GJS OSK, opt-in GDM) on Ubuntu 26.04 aarch64 GNOME, with a heavy automated test suite and no PII.

**Architecture:** Bash orchestrator (`install.sh` + `lib/*.sh` + one `modules/NN-name.sh` per component). Every mutation goes through a small set of lib primitives that honour `--dry-run`, count changes, and append to a per-run backup manifest; uninstall is a generic manifest replay. Parsing-heavy work lives in stdlib-only Python helpers. Tests: bats with a sandboxed `HOME`/`SYS_ROOT` and command stubs, Python `unittest`, shellcheck/shfmt/ruff, PII scan, and a real-dconf integration run (host sandbox + `ubuntu:26.04` arm64 container in CI).

**Tech Stack:** bash 5, Python 3.14 stdlib, bats-core v1.14.0 + bats-support v0.3.0 + bats-assert v2.2.4 + bats-file v0.4.0 (git submodules), shellcheck/shfmt/ruff from a gitignored dev venv (`make dev-deps`: `pip install shellcheck-py shfmt-py ruff`), GitHub Actions `ubuntu-24.04-arm`.

**Spec:** `docs/superpowers/specs/2026-10-29-tokyonight-ubuntu-design.md`

## Planning decisions (refine the spec; implement these, not the spec's original text)

1. **Ptyxis Storm palette is built in** (`Tokyo Night Storm`, from Gogh). No `assets/ptyxis/` dir.
2. **Pinned downloads** (`assets/checksums.sha256`):
   - `https://github.com/ryanoasis/nerd-fonts/releases/download/v3.5.1/JetBrainsMono.tar.xz` sha256 `04d5e8f903693f9dd13e16f867e994834e681eb3c72c0d337a770dcda09010cf`
   - `https://github.com/JanDeDobbeleer/oh-my-posh/releases/download/v31.8.0/posh-linux-arm64` sha256 `c7ee6d1075b625a4f151bf177defbaed55995b2fcd98e410c7990d2394c3fd80`
   - Never downgrade: an existing `oh-my-posh` with version ≥ 31.8.0 is kept.
3. **OSK layouts are generated for the active keymap** by `helpers/osk_layouts.py` (port of `~/Development/gjs-osk-gboard/gen_layouts.py`) from gjs-osk's keycode cache; a fixed `layouts.json` would only be right for `us+colemak`. Missing cache → layouts skipped with a warning, theme-sync still installed.
4. **All settings are written with `dconf` by key path** (not `gsettings`) so the manifest can record `UNSET` and uninstall can `dconf reset`. Integration tests read back through `gsettings` to catch wrong GVariant types.
5. **Module contract = `<name>_applies` + `<name>_apply`.** `--status` = dry-run apply per module (0 pending changes → `applied`, else `drifted (n)`). Removal is generic manifest replay.
6. **Uninstall replays every backup newest→oldest** (so `install; install --variant storm; --uninstall` returns to pre-install), then moves them to `backups/.restored/`. `--backup TS` replays only that one.
7. **Drift-aware restore:** a file/setting is restored only if it still holds the value we wrote; otherwise it is left alone and reported `kept (changed since install)`.
8. **Marked blocks and single-line edits never back up whole user files**; uninstall removes the block / restores the one line.
9. **GDM alternative priority 160** (beats a pre-existing 150 local `tokyonight` alternative).
10. **Screenshot capture is a human-in-the-loop task** (Task 11) done by the controller with the user, not a subagent.

## Global Constraints

- Target: Ubuntu `VERSION_ID=26.04`, `uname -m` = `aarch64`, GNOME; `--force` bypasses.
- Never run as root (EUID 0 → exit 3). Root actions only with `--system`, only via `as_root`.
- Without `--system`: nothing written outside `$HOME` (tested).
- Python helpers: stdlib only, `python3 -I`, read/write files as UTF-8 explicitly.
- All shell: `#!/usr/bin/env bash`, `set -Eeuo pipefail`, `shopt -s inherit_errexit`, `IFS=$'\n\t'`; shellcheck clean at `-S style`; `shfmt -i 2 -ci`.
- Marker lines exactly: `# >>> tokyonight-ubuntu >>>` and `# <<< tokyonight-ubuntu <<<`.
- State: `${XDG_STATE_HOME:-$HOME/.local/state}/tokyonight-ubuntu/{logs,backups,lock}`; cache: `${XDG_CACHE_HOME:-$HOME/.cache}/tokyonight-ubuntu/`.
- Exit codes: 0 ok, 1 module failure, 2 usage, 3 preflight, 4 lock held.
- Every absolute system path the code reads or writes is prefixed with `${SYS_ROOT:-}` (tests set it to a temp dir).
- No PII in any committed file: no `/home/<user>`, real name, email (except `noreply@anthropic.com`, `*@users.noreply.github.com`), hostname, UUIDs outside `assets/checksums.sha256`. Refer to local sources as `~/Development/...`.
- Commits: conventional prefix, trailer `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Commit only your own task's files with explicit `git add <paths>`; if `index.lock` exists, wait 2 s and retry (parallel tasks share the repo).
- Integration runs on the host must use a private bus (`dbus-run-session`) with `HOME`/`XDG_*` in a temp dir and `DBUS_SESSION_BUS_ADDRESS` unset first; they must never touch the real session's dconf.

## Review Focus

1. **Running on a machine that is already customised** (the author's own): unmarked `oh-my-posh init` already in `.zshrc`, a newer `~/.local/bin/oh-my-posh`, an existing `JetBrainsMonoNerd` font dir, an existing Ptyxis profile → no duplicate init, no downgrade, no duplicate profile, zero or minimal changes. Tests in Tasks 6 and 8.
2. **User edits after install, then uninstall** → edited files/settings are kept, not clobbered. Test in Task 2.
3. **Several installs with different options, then `--uninstall`** → exact pre-install state. Test in Task 5 and Task 10.
4. **Interrupted run** (SIGTERM mid-module) → lock released, manifest replayable, re-run converges. Test in Task 5.
5. **Awkward strings**: HOME with a space, emoji filenames (`Tokyonight Storm 🌪️.css`), apostrophes in GVariant strings (`Synthwave '84`), `LANG=C` → correct quoting/encoding everywhere. Tests in Tasks 2 and 3.

---

## Execution waves (max 5 concurrent subagents)

- Wave A: Task 1
- Wave B (parallel): Tasks 2, 3, 4
- Wave C: Task 5
- Wave D (parallel): Tasks 6, 7, 8, 9
- Wave E: Task 10, then Task 11 (controller + user), then Task 12

---

### Task 1: Repo scaffold and test harness

**Files:**
- Create: `Makefile`, `.gitignore`, `.gitmodules`, `LICENSE` (GPL-3.0 full text, fetched from `https://www.gnu.org/licenses/gpl-3.0.txt`), `.pii-denylist.example`, `tests/test_helper.bash`, `tests/stubs/bin/{dconf,flatpak,apt-get,dpkg-query,sudo,curl,fc-cache,update-alternatives,glib-compile-resources,gresource,uname,ptyxis,zsh,zellij,lig,oh-my-posh}`, `tests/bats/harness.bats`
- Submodules: `tests/bats/bats-core` (v1.14.0), `tests/bats/bats-support` (v0.3.0), `tests/bats/bats-assert` (v2.2.4), `tests/bats/bats-file` (v0.4.0)

**Interfaces:**
- Produces (`tests/test_helper.bash`, sourced by every `.bats`):
  - `setup_sandbox` — sets `HOME="$BATS_TEST_TMPDIR/home dir"` (note the space), `XDG_CONFIG_HOME/XDG_STATE_HOME/XDG_CACHE_HOME/XDG_DATA_HOME` under it, `SYS_ROOT="$BATS_TEST_TMPDIR/root"`, `STUB_LOG`, `STUB_STATE`, `TNU_ROOT` (repo root), `XDG_CURRENT_DESKTOP=ubuntu:GNOME`, `DBUS_SESSION_BUS_ADDRESS=unix:path=/dev/null`, writes `$SYS_ROOT/etc/os-release` (`ID=ubuntu`, `VERSION_ID="26.04"`), and `PATH="$BATS_TEST_TMPDIR/bin:$BATS_TEST_TMPDIR/sysbin"` where `sysbin` symlinks only real: bash env cat cp mv rm mkdir ln ls chmod stat touch mktemp date sleep sort uniq head tail tr cut wc grep sed awk find xargs cmp diff sha256sum tar xz python3 flock install readlink dirname basename id printf tee kill timeout.
  - `stub_enable NAME...` / `stub_disable NAME...` — symlink `tests/stubs/bin/NAME` into `$BATS_TEST_TMPDIR/bin` (default enabled: dconf curl fc-cache uname dpkg-query).
  - `dconf_get KEY` / `dconf_put KEY VALUE` — read/write stub dconf state directly.
  - `assert_stub_called NAME REGEX` / `refute_stub_called NAME [REGEX]` — grep `$STUB_LOG` (lines `NAME<TAB>arg1 arg2…`).
  - `tree_snapshot DIR` (prints sorted `sha256  relpath` for every file incl. mode) and `assert_tree_unchanged SNAPFILE DIR`.
  - `run_install ARGS...` — `run "$TNU_ROOT/install.sh" "$@"` with `TNU_EUID=1000`.
- Stub behaviour: every stub appends to `$STUB_LOG`. `dconf` supports `read KEY` (empty output if unset), `write KEY VALUE`, `reset [-f] KEY|DIR/`, `dump DIR/`, `list DIR/`, state in `$STUB_STATE/dconf.tsv`. `curl` copies `$STUB_STATE/downloads/<basename of URL>` to `-o` target or exits 22. `uname -m` prints `${STUB_UNAME_M:-aarch64}`. `sudo` strips its options and `--` and execs the rest (env preserved). `dpkg-query -W PKG` succeeds iff `$STUB_STATE/pkgs/PKG` exists. `oh-my-posh version` prints `${STUB_OMP_VERSION:-31.8.0}`. `update-alternatives`, `apt-get`, `flatpak`, `fc-cache`, `glib-compile-resources`, `gresource` log and succeed (`flatpak info APP` succeeds iff `$STUB_STATE/flatpak/APP` exists; `flatpak install` creates it). Others just log and exit 0.
- Makefile targets: `dev-deps` (venv `.venv-dev`), `lint`, `pii`, `test-bats`, `test-py`, `test` (= lint pii test-py test-bats), `test-integration`, `test-container` (skips with message if neither podman nor docker). `lint`/`pii`/`test-*` exist from now on even if their inputs are empty.

- [ ] **Step 1:** `git submodule add` the four bats repos at the pinned tags; create `.gitignore` (`.venv-dev/`, `.pii-denylist`, `__pycache__/`, `build/`, `*.log`).
- [ ] **Step 2: Write `tests/bats/harness.bats`** with tests: `sandbox HOME contains a space and is empty`; `dconf stub round-trips 'Synthwave '"'"'84'`; `disabled stub is not on PATH` (`refute command -v zsh` after `stub_disable zsh`); `curl stub fails with 22 when download missing`; `tree_snapshot detects a mode change`.
- [ ] **Step 3:** Run `make test-bats` → FAIL (helper missing).
- [ ] **Step 4:** Implement `tests/test_helper.bash`, stubs, Makefile.
- [ ] **Step 5:** `make dev-deps && make test` → harness tests PASS, lint clean.
- [ ] **Step 6:** Commit `chore: scaffold repo, bats harness and stubs`.

---

### Task 2: Core shell library

**Files:**
- Create: `lib/log.sh`, `lib/util.sh`, `lib/backup.sh`, `lib/settings.sh`
- Test: `tests/bats/lib_util.bats`, `tests/bats/lib_backup.bats`, `tests/bats/lib_settings.bats`

**Interfaces:**
- Consumes: Task 1 harness only. (`lib/edit.sh` and `ext_enable`, which need Task 3's helpers, are built in Task 5.)
- Globals read: `DRY_RUN` (0/1), `SYSTEM` (0/1), `OFFLINE` (0/1), `VERBOSE`, `MODULE`, `RUN_DIR`, `RUN_ID` (`date -u +%Y%m%dT%H%M%SZ`), `STATE_DIR`, `CACHE_DIR`, `TNU_ROOT`, `SYS_ROOT`.
- Produces:
  - `log.sh`: `log_init LOGFILE|-` , `log_info MSG`, `log_warn MSG`, `log_error MSG`, `log_debug MSG` (only when `VERBOSE=1`), `log_dry MSG` (prefix `[dry-run] `). Colour only when stderr is a TTY and `NO_COLOR` unset. All log output to stderr + log file.
  - `util.sh`: `die MSG [CODE=1]`; `have_cmd NAME`; `require_cmd NAME...` (die 3 listing missing); `run CMD...` (dry-run → `log_dry`, return 0); `note_change DESC` (appends `MODULE<TAB>DESC` to `$RUN_DIR/changes`, also in dry-run); `module_changes MODULE` (count); `sha256_of FILE`; `atomic_write DEST [MODE]` (stdin → temp in same dir → `mv`; keeps existing mode when MODE omitted; creates parent dirs, recording each created dir via `backup_record dir`); `install_file SRC DEST [MODE]` and `write_file DEST [MODE]` (stdin): no-op when content and mode already match; else `backup_file DEST`, `atomic_write`, `note_change`; `download_verified NAME` (looks up `NAME  sha  url` line in `assets/checksums.sha256` — format: `<sha256>  <name>  <url>`; uses cache if hash matches; else if `OFFLINE=1` die; else `curl --fail --location --proto '=https' --tlsv1.2 --retry 3 --retry-delay 2 -o tmp URL`, verify, mv into cache; mismatch → delete tmp, die "checksum mismatch for NAME"; echoes cached path); `as_root CMD...` (die unless `SYSTEM=1`; `run sudo -- CMD`); `sys_path PATH` (echo `${SYS_ROOT}${PATH}`).
  - `backup.sh`: `backup_dir` (lazily creates `$STATE_DIR/backups/$RUN_ID/` + `manifest.tsv` on first row; echoes it); `backup_record TYPE FIELD...` (rejects tabs/newlines in fields → die; appends row, `sync`s the file; no-op in dry-run); `backup_file PATH` (once per path per run: copies original to `files/<n>` or records `ABSENT`; installed hash appended later by `install_file`); `backup_list` (backup dirs newest first, excluding `.restored`); `backup_replay DIR [PURGE=0]` (rows in reverse). Row formats (TAB-separated):
    - `file  PATH  files/N|ABSENT  INSTALLED_SHA`
    - `dconf  KEY  OLD|UNSET  NEW`
    - `block  FILE  CREATED(0|1)` (written by Task 5's `edit.sh`; replay calls `block_remove`)
    - `line  FILE  MATCH_REGEX  OLD_LINE|ABSENT  NEW_LINE` (written by `set_line`; replay calls `textedit.py restore-line`)
    - `dir  PATH` (created by us; removed on replay only if empty, or recursively if it is listed in a `pkg` row)
    - `pkg  flatpak|fontdir|bin|sysdir  NAME_OR_PATH` (replay only when PURGE=1)
    - `alt  NAME  PATH` (`as_root update-alternatives --remove NAME PATH`)
    - `sysfile  PATH  files/N|ABSENT  INSTALLED_SHA` (restore via `as_root`)
    Drift rule: `file`/`sysfile`/`dconf`/`line` restore only when current == recorded new value; otherwise `log_warn "kept PATH (changed since install)"`.
  - `settings.sh`: `dset KEY VALUE` (VALUE is a canonical GVariant literal; compare with `dconf read`; equal → no-op; else `backup_record dconf KEY OLD|UNSET VALUE`, `run dconf write KEY VALUE`, `note_change`); `dget KEY`; `gv_str TEXT` (echo GVariant string literal: single quotes, `\` → `\\`, `'` → `\'`). When `DBUS_SESSION_BUS_ADDRESS` is empty, `dconf` is invoked as `dbus-run-session -- dconf` and `log_warn` once "no session bus: log out and back in to see changes".

- [ ] **Step 1: Write failing tests.** Names and key assertions:
  - `lib_util.bats`: `run in dry-run does not execute` (marker file not created; stderr contains `[dry-run]`); `install_file is a no-op when identical` (no manifest, `module_changes` 0); `install_file backs up and replaces` (backup copy byte-equal to original; manifest row `file`); `install_file preserves existing mode`; `atomic_write leaves no temp file on failure` (read-only dir → non-zero, no `.tmp*` left); `download_verified uses cache when hash matches` (curl stub not called); `download_verified deletes file on checksum mismatch` (exit non-zero, stderr `checksum mismatch`, cache empty); `download_verified offline without cache dies`; `as_root refuses without --system`; `HOME with a space works for install_file`.
  - `lib_backup.bats`: `no rows means no backup dir`; `field with tab is rejected`; `replay restores file byte-for-byte`; `replay deletes file that was ABSENT`; `replay keeps file changed since install` (stderr `kept`); `replay removes empty created dir but not non-empty one`; `pkg rows replay only with purge`; `manifest survives kill mid-write` (append rows, kill writer subshell, replay succeeds); `emoji path round-trips` (`Tokyonight Storm 🌪️.css` under `LANG=C`).
  - `lib_settings.bats`: `dset no-op when equal`; `dset records UNSET then replay resets` (stub dconf has no key after replay); `dset records old value then replay restores it`; `replay keeps setting changed after install`; `gv_str escapes apostrophe and backslash` (`Synthwave '84` → `'Synthwave \'84'`); `no bus uses dbus-run-session` (stub `dbus-run-session` called).
- [ ] **Step 2:** `make test-bats` → these FAIL.
- [ ] **Step 3:** Implement the four lib files to the interfaces above.
- [ ] **Step 4:** `make lint test-bats` → PASS.
- [ ] **Step 5:** Commit `feat(lib): logging, atomic writes, backups, dconf and text edits`.

---

### Task 3: Python helpers

**Files:**
- Create: `helpers/palette.py`, `helpers/prefs.py`, `helpers/textedit.py`, `helpers/gvlist.py`, `helpers/pii_scan.py`
- Test: `tests/python/test_palette.py`, `test_prefs.py`, `test_textedit.py`, `test_gvlist.py`, `test_pii_scan.py`, fixtures in `tests/fixtures/`

**Interfaces (CLI; all exit 0 = changed/ok, 3 = unchanged, 2 = usage, 1 = error; each also importable):**
- `palette.py CSS_FILE [--json]` → prints `KEY=#rrggbb` lines for `bg` (`--window-bg-color`), `fg` (`--window-fg-color`), `card` (`--card-bg-color`), `dark` (`--headerbar-bg-color`), `border` (`--sidebar-border-color`), `accent` (`@define-color accent_bg_color`), `accent_fg` (`@define-color accent_fg_color`). Missing key → exit 1 naming it. Function `parse(text) -> dict[str,str]`.
- `prefs.py merge FILE KEY=JSON...` → loads FILE (missing → `{}`; invalid JSON → copy to `FILE.invalid-<ts>` and start from `{}`, warn on stderr), sets keys, writes with `indent=4, ensure_ascii=True` (matches Rewaita's own `\ud83d…` output), exit 3 if unchanged.
- `textedit.py block-upsert FILE --begin B --end E` (body on stdin) / `block-remove FILE --begin B --end E` / `set-line FILE --match REGEX --line TEXT [--section NAME]` (prints old matching line or `ABSENT` on stdout; inside `[NAME]` TOML section when given, creating the section if absent; ignores lines starting with `//` or `#`) / `restore-line FILE --match REGEX --old TEXT|--absent`. Preserves CRLF if the file uses it, preserves trailing-newline state, refuses binary (NUL) files with exit 1, errors if markers are unbalanced/duplicated.
- `gvlist.py add|remove|has LITERAL ITEM` → prints new GVariant `as` literal (`['a', 'b']`; empty → `@as []`); `has` exits 0/3. Parses only string arrays; anything else exit 1.
- `pii_scan.py [--history] [--denylist FILE] [--ocr] PATH...` → prints `file:line: rule: excerpt` per hit, exit 1 if any. Rules: `email` (allow `noreply@anthropic.com`, `@users.noreply.github.com`), `home-path` (`/home/([a-z_][a-z0-9_.-]*)` and `/Users/([A-Za-z][\w.-]*)`, allowing the names `user`, `someone`, `example`, `runner`, `tester`, `demo`), `uuid` (8-4-4-4-12 and bare 32-hex; allow inside `assets/checksums.sha256` and lines containing `sha256`), `mac`, `ipv4` (allow 127.0.0.0/8, 0.0.0.0, 192.0.2/24, 198.51.100/24, 203.0.113/24), `denylist` (case-insensitive literals). Skips `.git/`, `tests/bats/bats-*`, `tests/fixtures/pii/` (planted positives live only there), and binary files except PNG (PNG: checks tEXt/iTXt/zTXt/eXIf chunks exist → rule `png-metadata`; with `--ocr` and `tesseract` present, OCRs and scans text). `--history` scans `git log -p --all` output and commit author/committer emails. Allow pragma: a line containing `pii-scan: allow` is skipped.

- [ ] **Step 1: Write failing tests** (`python3 -m unittest discover -s tests/python`): palette parses both `tests/fixtures/gtk4-tokyonight.css` and `gtk4-storm.css` (copy from Task 4 assets when available; until then a trimmed fixture containing the 7 keys with `bg=#1a1b26` / `#24283b`) and fails naming `card` when removed; prefs merge preserves unknown keys, exit 3 on second run, invalid JSON backed up, emoji value round-trips as `🗼`; textedit upsert/replace/remove/CRLF/no-trailing-newline/duplicate-marker error/`set-line` in `[ui]` section/commented `// theme "x"` ignored; gvlist add to `@as []`, idempotent add, remove last → `@as []`, item with apostrophe; pii_scan (positives read from `tests/fixtures/pii/`) hits a planted email, `/home/alice/x`, a uuid4, a MAC, `10.1.2.3`, a denylist word, a PNG with a tEXt chunk; no hit for `noreply@anthropic.com`, `/home/runner/work`, `${HOME}/x`, `~/Development/x`, a checksum line, a `pii-scan: allow` line.
- [ ] **Step 2:** Run → FAIL.
- [ ] **Step 3:** Implement the helpers.
- [ ] **Step 4:** `make test-py lint` → PASS (ruff clean).
- [ ] **Step 5:** Wire `make pii` = `python3 -I helpers/pii_scan.py --denylist .pii-denylist .` (denylist flag only if file exists); commit `feat(helpers): palette, prefs, text edit, gvariant list and PII scan`.

---

### Task 4: Vendored assets

**Files:**
- Create: `tools/regen-assets.sh`, `assets/rewaita/{tokyonight,storm}/{gtk4.css,gtk3.css,gnome-shell.css}`, `assets/omp/tokyonight_storm.omp.json`, `assets/osk/gjsosk-theme-sync@nadelacruz-00.github.io/{extension.js,palette.js,metadata.json}`, `assets/osk/gjsosk-split-flush`, `assets/osk/99erhai-gjsosk-split-flush`, `assets/checksums.sha256`, `assets/SOURCES.md`, `CREDITS.md`
- Test: `tests/bats/assets.bats`, `tests/gjs/theme-sync.test.js` (moved from `~/Development/gjs-osk-gboard/theme-sync/test.js`, path-adjusted)

**Interfaces:**
- Produces: the asset paths above (consumed by Tasks 6–9). `checksums.sha256` lines `<sha256>  <name>  <url>` for the two downloads in Planning decision 2 **and** `<sha256>  <relpath>` lines for every vendored file under `assets/` (except itself).
- `tools/regen-assets.sh` (maintainer, run on a desktop with Rewaita installed): for each variant `tokyonight-storm` then `tokyonight`, runs `flatpak run io.github.swordpuffin.rewaita --theme --theme=<name>`, copies `~/.config/gtk-4.0/gtk.css`, `~/.config/gtk-3.0/gtk.css`, `~/.local/share/themes/rewaita/gnome-shell/gnome-shell.css` into `assets/rewaita/<variant>/`; first backs up the three live files and restores them byte-for-byte on exit (trap), so the desktop ends where it started. Regenerates `checksums.sha256` vendored lines.

- [ ] **Step 1: Write `tests/bats/assets.bats`:** `vendored checksums verify` (`sha256sum -c` on the relpath lines); `tokyonight gtk4 has #1a1b26 window bg`; `storm gtk4 has #24283b window bg`; `variants differ`; `palette.py parses both variants` (skip if Task 3 not merged yet); `theme-sync metadata uuid matches dir name`; `assets contain no PII` (`pii_scan.py assets`); `omp json is valid JSON`; `gjs theme-sync test` (skip unless `gjs` present).
- [ ] **Step 2:** Run → FAIL.
- [ ] **Step 3:** Write `tools/regen-assets.sh`, run it on this desktop, verify with `sha256sum` that the live three files are unchanged afterwards. Copy omp json from `~/.config/oh-my-posh/`, theme-sync from `~/Development/gjs-osk-gboard/theme-sync/`, split-flush files from `~/Development/gjs-osk-gboard/patch/`. Remove any PII found (paths, names) and record origin + licence per file in `assets/SOURCES.md` and `CREDITS.md` (Rewaita GPL-3.0, Tokyo Night by folke MIT, Nerd Fonts OFL-1.1, oh-my-posh MIT, GJS OSK + its licence, Ptyxis palettes from Gogh MIT).
- [ ] **Step 4:** `make test-bats pii` → PASS.
- [ ] **Step 5:** Commit `feat(assets): vendor Rewaita Tokyo Night CSS, prompt, OSK theme-sync`.

---

### Task 5: CLI, runner, detection, preflight

**Files:**
- Create: `install.sh`, `VERSION`, `lib/detect.sh`, `lib/runner.sh`, `lib/edit.sh`, `modules/00-preflight.sh`
- Modify: `lib/settings.sh` (add `ext_enable`), `lib/backup.sh` (replay of `block`/`line` rows)
- Test: `tests/bats/cli.bats`, `tests/bats/runner.bats`, `tests/bats/preflight.bats`, `tests/bats/lib_edit.bats`, fixture modules in `tests/fixtures/modules/`

**Interfaces:**
- Consumes: Task 2 libs, Task 3 `textedit.py` / `gvlist.py`.
- Produces:
  - `edit.sh`: `block_upsert FILE` (stdin = block body without markers; `python3 -I helpers/textedit.py block-upsert`; records `block FILE CREATED` on first change; `note_change`); `block_remove FILE`; `set_line FILE MATCH_REGEX NEW_LINE [SECTION]` (`textedit.py set-line`; records `line` row with the old line it prints; no-op on exit 3).
  - `settings.sh` addition: `ext_enable UUID` — adds UUID to `/org/gnome/shell/enabled-extensions` and removes it from `/org/gnome/shell/disabled-extensions` via `gvlist.py`, each through `dset`; prior `UNSET` → literal starts as `@as []`.
  - `RUN_DIR` = `mktemp -d` (removed on exit), so dry-run/status never create the state dir.
  - `install.sh` sources `lib/*.sh` then `modules/[0-9][0-9]-*.sh` (or `$TNU_MODULES_DIR` — tests point it at fixtures). Parses flags exactly as spec §4 (`--version` prints contents of `VERSION`, create `VERSION` = `0.1.0`). Validates `--variant tokyonight|storm`, module names, `--only`/`--skip` exclusivity, `--purge`/`--backup` only with `--uninstall` → exit 2. Exports `VARIANT DRY_RUN SYSTEM OFFLINE VERBOSE STRICT FORCE YES`. `YES=0` and stdin is a TTY → prints plan (modules + system yes/no) and asks `Proceed? [y/N]`; non-TTY without `-y` proceeds.
  - Module registration: each module file calls `register_module NAME ORDER SYSTEM_ONLY(0|1)` and defines `NAME_applies` (return 0, or print reason and return 1) and `NAME_apply`. Module names: `preflight fonts rewaita gtk shell-theme wallpaper ptyxis prompt osk gdm` (function names use `_` for `-`: `shell_theme_apply`).
  - `lib/runner.sh`: `run_modules` — preflight always runs first in the parent shell (exit 3 on failure); others each in a subshell `( MODULE=…; NAME_applies && NAME_apply )` with ERR trap printing `MODULE file:line: command` → result `OK` (0 changes), `CHANGED n`, `SKIPPED reason`, `FAILED`; system-only modules without `--system` → `SKIPPED needs --system`. `--strict` stops at first failure. Prints a summary table and `log: PATH`. Exit 1 if any FAILED.
  - Lock: `flock -n` on `$STATE_DIR/lock` (fd 9) for apply/uninstall (not dry-run/status) → exit 4 "another install is running". `trap` on INT/TERM: log "interrupted", exit 130, lock auto-released.
  - `--status`: forces `DRY_RUN=1`, runs modules, prints `applied` / `drifted (n)` / `n/a: reason`.
  - `--uninstall`: replays `backup_list` (or `--backup TS`) newest→oldest with `PURGE`, moves each replayed dir to `backups/.restored/`; "nothing to uninstall" exit 0 if none.
  - `lib/detect.sh` sets and exports: `IS_ERHAI` (`$SYS_ROOT/usr/share/gnome-shell/theme/erhai/gnome-shell-theme.gresource` exists or `dpkg-query -W oneplus-erhai-desktop`), `HAS_ZSH`, `HAS_PTYXIS`, `HAS_FLATPAK`, `HAS_ZELLIJ`, `HAS_LIG` (`have_cmd`), `HAS_GJSOSK` (dir `gjsosk@vishram1123.com` under `$SYS_ROOT/usr/share/gnome-shell/extensions` or `$HOME/.local/share/gnome-shell/extensions`), `HAS_USER_THEME` (same for `user-theme@gnome-shell-extensions.gcampax.github.com`), `HAS_SESSION_BUS`.
  - `modules/00-preflight.sh`: checks per spec §5 preflight; EUID from `${TNU_EUID:-$EUID}`; free space via `df -Pk "$HOME"` (add `df` to harness sysbin) ≥ 204800 KB; `--force` downgrades OS/arch/desktop failures to warnings (never root or missing python3).

- [ ] **Step 1: Write failing tests.**
  - `cli.bats`: `--help exits 0 and lists every flag`; `unknown flag exits 2`; `--only with --skip exits 2`; `--variant bogus exits 2`; `--purge without --uninstall exits 2`; `--only nosuch exits 2`; `--version prints 0.1.0`; `--dry-run writes nothing` (snapshot of `$HOME` and `$SYS_ROOT` unchanged, no state dir).
  - `runner.bats` (fixture modules `alpha` changes a file, `beta` fails, `gamma` system-only, `delta` not applicable): `summary shows CHANGED/FAILED/SKIPPED`; `failure does not stop later modules`; `--strict stops after beta`; `exit 1 when a module failed`; `second run reports OK 0 changes and creates no backup`; `--status reports drifted then applied`; `lock held exits 4` (hold lock with `flock` in background); `SIGTERM mid-module releases lock and re-run converges` (alpha sleeps; kill; rerun; uninstall restores); `uninstall after two runs with different content restores original` (Review Focus 3); `uninstall --backup TS replays only that one`; `uninstall with nothing exits 0`.
  - `lib_edit.bats`: `block_upsert creates file and records CREATED=1`; `block_upsert replaces existing block in place`; `block_upsert second run no change`; `uninstall removes block and deletes file it created when only block remained`; `set_line replaces only uncommented key`; `uninstall restores old line`; `CRLF file keeps CRLF`; `ext_enable adds once and removes from disabled list` (run twice → one entry; start from UNSET).
  - `preflight.bats`: `refuses root` (TNU_EUID=0 → exit 3); `rejects 24.04`; `rejects x86_64` (`STUB_UNAME_M=x86_64`); `--force allows 24.04 with warning`; `--force never allows root`; `rejects non-GNOME desktop`; `detect sets IS_ERHAI from gresource file`.
- [ ] **Step 2:** Run → FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** `make lint test-bats` → PASS.
- [ ] **Step 5:** Commit `feat: CLI, module runner, lock, status, uninstall, preflight`.

---

### Task 6: fonts and prompt modules

**Files:**
- Create: `modules/10-fonts.sh`, `modules/70-prompt.sh`
- Test: `tests/bats/mod_fonts.bats`, `tests/bats/mod_prompt.bats`, fixtures `tests/fixtures/downloads/` (tiny fake `JetBrainsMono.tar.xz` with 2 ttf files and fake `posh-linux-arm64` script; tests rewrite the checksum file via `TNU_CHECKSUMS` override — add that override to `download_verified` if Task 2 lacks it)

**Interfaces:**
- Consumes: `download_verified`, `install_file`, `backup_record pkg|dir`, `block_upsert`, `set_line`, `HAS_*`.
- Behaviour:
  - fonts: dest `$HOME/.local/share/fonts/JetBrainsMonoNerd/`. Extract tarball to a temp dir, `install_file` each `*.ttf` (mode 0644). If dest dir did not exist → `backup_record pkg fontdir DEST`. Run `fc-cache -f DEST` only if any file changed. Dry-run without cached tarball → `note_change "download JetBrainsMono"`.
  - prompt binary: if `have_cmd oh-my-posh` and its `oh-my-posh version` ≥ `31.8.0` (compare with `sort -V`) → keep, log. Else download and `install_file … "$HOME/.local/bin/oh-my-posh" 0755`, `backup_record pkg bin PATH` when newly created.
  - prompt config: `install_file assets/omp/tokyonight_storm.omp.json "$HOME/.config/oh-my-posh/tokyonight_storm.omp.json" 0644`.
  - rc blocks: for zsh when `HAS_ZSH=1` or `~/.zshrc` exists; for bash when `~/.bashrc` exists. Skip a file (log `already configured`) if it contains an unmarked line matching `oh-my-posh init` outside our markers. Block body for SHELL in zsh|bash:
    ```
    if command -v oh-my-posh >/dev/null 2>&1; then _omp=oh-my-posh; else _omp="$HOME/.local/bin/oh-my-posh"; fi
    [ -x "$(command -v "$_omp")" ] && eval "$("$_omp" init SHELL --config "$HOME/.config/oh-my-posh/tokyonight_storm.omp.json")"
    unset _omp
    ```
  - zellij: if `HAS_ZELLIJ=1` and `~/.config/zellij/config.kdl` exists → `set_line FILE '^theme\s+"' 'theme "tokyo-night-storm"'`.
  - lig: if `HAS_LIG=1` and `~/.config/lig/config.toml` exists → `set_line FILE '^theme\s*=' 'theme = "tokyonight"' ui`.

- [ ] **Step 1: Write failing tests:** `fonts install into empty HOME and fc-cache runs`; `fonts second run no change and no fc-cache`; `fonts existing identical dir → 0 changes, no pkg row` (Review Focus 1); `fonts checksum mismatch fails module` ; `fonts uninstall --purge removes dir only when we created it`; `prompt keeps newer oh-my-posh` (`STUB_OMP_VERSION=31.9.0`, curl not called); `prompt installs binary when absent`; `prompt adds zsh block only when zsh present`; `prompt skips rc with existing unmarked oh-my-posh init`; `prompt block idempotent`; `prompt uninstall removes block and leaves user lines intact`; `zellij theme line replaced, commented example untouched, uninstall restores old line`; `zellij absent → config untouched`; `lig theme set under [ui]`.
- [ ] **Step 2:** Run → FAIL. **Step 3:** Implement. **Step 4:** `make lint test-bats` → PASS.
- [ ] **Step 5:** Commit `feat(modules): fonts and prompt`.

---

### Task 7: rewaita, gtk, shell-theme, wallpaper modules

**Files:**
- Create: `modules/20-rewaita.sh`, `modules/30-gtk.sh`, `modules/40-shell-theme.sh`, `modules/50-wallpaper.sh`
- Test: `tests/bats/mod_rewaita.bats`, `mod_gtk.bats`, `mod_shell_theme.bats`, `mod_wallpaper.bats`

**Interfaces:**
- Consumes: `install_file`, `dset`, `gv_str`, `ext_enable`, `as_root`, `run`, `prefs.py`, `HAS_FLATPAK`, `HAS_USER_THEME`, `VARIANT`.
- Values (variant dir `assets/rewaita/$VARIANT/`):
  - rewaita applies: `HAS_FLATPAK=1` (or `SYSTEM=1`, which first runs `as_root apt-get install -y flatpak`; apt packages get no `pkg` row and are never removed) and `OFFLINE=0`. Steps: `run flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo`; if `flatpak info --user io.github.swordpuffin.rewaita` fails → `run flatpak install --user -y --noninteractive flathub io.github.swordpuffin.rewaita`, `backup_record pkg flatpak io.github.swordpuffin.rewaita`, `note_change`. prefs merge at `$HOME/.var/app/io.github.swordpuffin.rewaita/data/prefs.json`: `dark-theme` `"Tokyonight 🗼.css"` or `"Tokyonight Storm 🌪️.css"`, `light-theme` `"Tokyonight 🗼.css"`, `window-controls` `"mint"`, `accent` `"'blue'"`, `modify-gtk3-theme` true, `modify-gnome-shell` true — via `backup_file` + `prefs.py merge` (exit 3 → no change).
  - gtk: `install_file gtk4.css ~/.config/gtk-4.0/gtk.css 0644`, `gtk3.css → ~/.config/gtk-3.0/gtk.css`; `dset /org/gnome/desktop/interface/color-scheme "'prefer-dark'"`, `accent-color "'purple'"`, `gtk-theme "'Yaru-purple-dark'"`, `icon-theme "'Yaru-purple-dark'"`.
  - shell-theme applies: `HAS_USER_THEME=1` (or `SYSTEM=1` → `as_root apt-get install -y gnome-shell-extensions`). `install_file gnome-shell.css ~/.local/share/themes/rewaita/gnome-shell/gnome-shell.css`; `ext_enable user-theme@gnome-shell-extensions.gcampax.github.com`; `dset /org/gnome/shell/extensions/user-theme/name "'rewaita'"`.
  - wallpaper: `W=/usr/share/backgrounds/osselo-Ask_a_friend.jpg`; applies if `$(sys_path $W)` exists or `SYSTEM=1` (then `as_root apt-get install -y ubuntu-wallpapers-resolute`). `dset` `/org/gnome/desktop/background/picture-uri`, `picture-uri-dark`, `/org/gnome/desktop/screensaver/picture-uri` to `"'file:///usr/share/backgrounds/osselo-Ask_a_friend.jpg'"`, `/org/gnome/desktop/background/picture-options "'zoom'"`.

- [ ] **Step 1: Write failing tests:** for each module: `applies/skips with reason`; `clean HOME apply` (exact dconf values via `dconf_get`, file bytes equal asset); `existing user gtk.css backed up and restored on uninstall`; `second run zero changes`; `--variant storm installs storm css and storm prefs name`; `switching variant then uninstall restores pre-install` ; `rewaita prefs keeps unknown keys`; `rewaita skipped offline`; `rewaita purge uninstalls flatpak` (stub `flatpak uninstall` called); `shell-theme enable list gets uuid once`; `wallpaper skipped when file missing without --system`; `wallpaper --system installs package via sudo` (assert stub `sudo` then `apt-get install -y ubuntu-wallpapers-resolute`).
- [ ] **Step 2:** FAIL. **Step 3:** Implement. **Step 4:** `make lint test-bats` PASS.
- [ ] **Step 5:** Commit `feat(modules): rewaita, gtk, shell theme, wallpaper`.

---

### Task 8: ptyxis and osk modules

**Files:**
- Create: `modules/60-ptyxis.sh`, `modules/80-osk.sh`, `helpers/osk_layouts.py`
- Test: `tests/bats/mod_ptyxis.bats`, `tests/bats/mod_osk.bats`, `tests/python/test_osk_layouts.py`, fixtures `tests/fixtures/osk/{us.json,us+colemak.json}` (keycode caches; take `us+colemak` from `~/.cache/gjs-osk/keycodes/` and produce `us` by running gjs-osk or hand-building from xkb `us`)

**Interfaces:**
- Consumes: `dset`, `dget`, `gv_str`, `ext_enable`, `install_file`, `backup_record dir`, `as_root`, `gvlist.py`, `HAS_PTYXIS`, `HAS_GJSOSK`, `IS_ERHAI`.
- ptyxis applies: `HAS_PTYXIS=1`. UUID = `dget /org/gnome/Ptyxis/default-profile-uuid` (strip quotes) → else first of `profile-uuids` → else new `python3 -c 'import uuid;print(uuid.uuid4().hex)'`, then `dset profile-uuids "['$U']"`, `dset default-profile-uuid "'$U'"`, `dset /org/gnome/Ptyxis/Profiles/$U/label "'Tokyo Night'"`. Always: `dset /org/gnome/Ptyxis/Profiles/$U/palette` `"'Tokyo Night'"` (tokyonight) or `"'Tokyo Night Storm'"` (storm); `dset /org/gnome/Ptyxis/font-name "'JetBrainsMono Nerd Font 10'"`, `use-system-font false`, `interface-style "'dark'"`.
- `osk_layouts.py merge --keycodes FILE --current LITERAL_OR_EMPTY` → stdout JSON `{"custom_layout": "<GVariant as literal>", "split_index": N}`; replaces existing entries whose JSON options `name` starts with `gboard-qwerty`, appends `gboard-qwerty-split` then `gboard-qwerty-portrait`; `split_index = 10 + position of split in the list` (10 built-ins). Layout geometry identical to `gen_layouts.py` (port it; keep its constants).
- osk applies: `HAS_GJSOSK=1`. Steps: install theme-sync files to `~/.local/share/gnome-shell/extensions/gjsosk-theme-sync@nadelacruz-00.github.io/` (record `dir` if created); `ext_enable gjsosk-theme-sync@nadelacruz-00.github.io`; keymap = first `('xkb', 'X')` of `dget /org/gnome/desktop/input-sources/sources` (default `us`); cache `~/.cache/gjs-osk/keycodes/<keymap>.json` → if present `dset /org/gnome/shell/extensions/gjsosk/custom-layout`, `layout-landscape` and `layout-portrait` to `split_index`, else `log_warn "open the on-screen keyboard once, then re-run to apply the split layout"`. Always `dset` under `/org/gnome/shell/extensions/gjsosk/` (literal types must match `org.gnome.shell.extensions.gjsosk.gschema.xml`: read each key's type from the schema and prefix e.g. `uint32 ` / `@d `-style as required; integration readback via `gsettings` must equal the intended value): `landscape-width-percent 48`, `landscape-height-percent 28`, `portrait-width-percent 100`, `portrait-height-percent 35`, `outer-spacing-px 6`, `border-spacing-px 2`, `font-size-px 16`, `font-bold true`, `round-key-corners false`, `show-icons false`, `system-accent-col false`. Never `default-monitor`. With `SYSTEM=1 && IS_ERHAI=1`: install `assets/osk/gjsosk-split-flush` → `/usr/local/sbin/gjsosk-split-flush` (0755) and `99erhai-gjsosk-split-flush` → `/etc/apt/apt.conf.d/` (0644) via `as_root install` with `sysfile` rows (with `SYS_ROOT` prefix), then `as_root /usr/local/sbin/gjsosk-split-flush reapply`. Log "log out and back in to load new extensions" when an extension dir was created.

- [ ] **Step 1: Write failing tests:** ptyxis `creates profile with fresh 32-hex uuid when none`; `reuses existing default profile, no new uuid` (Review Focus 1); `storm palette name`; `second run zero changes`; `uninstall resets created keys to UNSET`; osk `skipped without gjsosk`; `installs extension and enables it`; `writes sizing keys and never default-monitor`; `missing keycode cache warns and still succeeds`; `layouts index points at split entry` (python + bats); `re-run keeps one copy of gboard layouts` (merge idempotent); `split-flush only with --system on erhai`; python `colemak cache places QWERTY letters on the right physical keys` (for every letter key in the split layout, the fixture's `layers.default` of that key equals the intended QWERTY letter, e.g. the layout's 'e' slot is the key whose default is `e`), `us cache maps identity` (the 'e' slot is `AD03`), `existing non-gboard custom layouts preserved`.
- [ ] **Step 2:** FAIL. **Step 3:** Implement. **Step 4:** `make lint test-py test-bats` PASS.
- [ ] **Step 5:** Commit `feat(modules): ptyxis profile and GJS OSK theme/layout`.

---

### Task 9: GDM module

**Files:**
- Create: `helpers/gresource.py`, `modules/90-gdm.sh`
- Test: `tests/python/test_gresource.py`, `tests/fixtures/gdm/expected-overrides-tokyonight.css` (golden), `tests/bats/mod_gdm.bats`

**Interfaces:**
- Consumes: `palette.parse`, `as_root`, `backup_record sysfile|alt|dir`, `sys_path`, `assets/rewaita/$VARIANT/gtk4.css`.
- `gresource.py build --base GRESOURCE --palette CSS --wallpaper IMG --out OUT_GRESOURCE` — port of `~/Development/gdm-tokyonight/build.py`, minus its gsettings/`~/.config` reads: lists + extracts every resource under `/org/gnome/shell/theme` with `gresource`, copies wallpaper as `tokyonight-bg.<ext>`, appends the override block (marker `/* tokyonight-ubuntu overrides */`, replacing an older block if present) to `Yaru/gnome-shell-dark.css`, `Yaru/gnome-shell.css`, `gdm.css` when they exist, writes `gnome-shell-theme.gresource.xml`, runs `glib-compile-resources`. Pure functions to test: `overrides(palette: dict, bg_name: str) -> str`, `resource_xml(files: list[str]) -> str`, `apply_overrides(css: str, block: str) -> str` (idempotent).
- gdm module: `SYSTEM_ONLY=1`. Base = `$(sys_path /usr/share/gnome-shell/theme/erhai/gnome-shell-theme.gresource)` if exists else `…/Yaru/gnome-shell-theme.gresource` (missing both → fail "no base GDM theme"). Requires `glib-compile-resources`/`gresource` — if missing `as_root apt-get install -y libglib2.0-dev-bin`. Build into `$RUN_DIR/gdm/`, then if differs from installed: `as_root install -D -m 0644 OUT $(sys_path /usr/share/gnome-shell/theme/tokyonight-ubuntu/gnome-shell-theme.gresource)` (`sysfile` row, `dir` row if created) and `as_root update-alternatives --install /usr/share/gnome-shell/gdm-theme.gresource gdm-theme.gresource /usr/share/gnome-shell/theme/tokyonight-ubuntu/gnome-shell-theme.gresource 160` (`alt` row). Logs "applies at next GDM start (log out or reboot)".

- [ ] **Step 1: Write failing tests:** python `overrides golden for tokyonight palette`; `apply_overrides twice equals once`; `resource_xml lists every file with prefix`; `build end-to-end` (skip unless real `glib-compile-resources`+`gresource`; build a tiny base gresource in setUp, assert output contains `tokyonight-bg.jpg` and marker). bats `skipped without --system`; `uses erhai base when present else Yaru`; `fails cleanly when no base`; `installs via sudo with priority 160`; `second run no reinstall`; `uninstall removes alternative and file`.
- [ ] **Step 2:** FAIL. **Step 3:** Implement. **Step 4:** `make lint test-py test-bats` PASS.
- [ ] **Step 5:** Commit `feat(modules): GDM login theme`.

---

### Task 10: Boundary guard, integration tests, CI

**Files:**
- Create: `tests/bats/boundary.bats`, `tests/integration/run.sh`, `tests/integration/Containerfile`, `.github/workflows/ci.yml`
- Modify: `Makefile` (`test-integration`, `test-container`)

**Interfaces:**
- `tests/integration/run.sh [--system] [--real-network]`: requires real `dconf`, `dbus-run-session`, `gsettings`. Creates temp HOME (with a space), `unset DBUS_SESSION_BUS_ADDRESS`, then inside `dbus-run-session`: seeds a pre-existing `.zshrc` line and gtk.css; snapshots `tree_snapshot HOME` + `dconf dump /`; runs `./install.sh -y --skip rewaita,fonts,prompt` (with `--real-network`: `--skip rewaita` only, fonts/prompt downloading for real); asserts with `gsettings get` that `org.gnome.desktop.interface color-scheme` = `'prefer-dark'`, `user-theme name` = `'rewaita'`, Ptyxis palette set (if ptyxis schema installed); second run summary contains no `CHANGED`; `--variant storm` run; `--uninstall`; asserts HOME tree and `dconf dump /` equal snapshots. With `--system` (container only, as non-root user with passwordless sudo) also asserts `update-alternatives --query gdm-theme.gresource` `Value:` is the tokyonight-ubuntu path, then uninstall restores the previous value. Prints `INTEGRATION PASS` on success.
- `Containerfile`: `FROM ubuntu:26.04`; installs `dconf-cli dbus libglib2.0-bin libglib2.0-dev-bin python3 curl xz-utils zsh ptyxis gnome-shell-extensions gnome-shell-common yaru-theme-gnome-shell ubuntu-wallpapers-resolute fontconfig sudo git`; non-root `tester` with NOPASSWD sudo.
- `ci.yml` jobs (all `runs-on: ubuntu-24.04-arm`, checkout with `submodules: recursive`, `fetch-depth: 0`): `lint` (dev-deps, `make lint`), `pii` (`pii_scan.py --history .`), `unit` (`make test-py test-bats`), `integration` (container `ubuntu:26.04`: install Containerfile deps, run `tests/integration/run.sh` as `tester`, then `--system`), `network` (`continue-on-error: true`, integration with `--real-network` and real Rewaita via Flathub). Cache `~/.cache/tokyonight-ubuntu` keyed on `assets/checksums.sha256`.

- [ ] **Step 1: Write `boundary.bats`:** `user-level full install never calls sudo/apt-get/update-alternatives`; `user-level install leaves SYS_ROOT unchanged` (tree snapshot); `no stub argv contains /usr/, /etc/ or /var/ paths outside SYS_ROOT reads`; `dry-run full install mutates nothing` (HOME and SYS_ROOT snapshots, no `write`/`reset` in dconf stub log).
- [ ] **Step 2:** Run → fix any module leaks found until PASS.
- [ ] **Step 3:** Write `run.sh`; run `make test-integration` on this host → `INTEGRATION PASS`. Verify afterwards the real session is untouched: `gsettings get org.gnome.desktop.interface gtk-theme` unchanged and real `~/.config/gtk-4.0/gtk.css` sha256 unchanged.
- [ ] **Step 4:** Write Containerfile + ci.yml; `make test-container` (skips locally if no podman/docker).
- [ ] **Step 5:** Commit `test: boundary guard, integration run, CI workflow`.

---

### Task 11: Screenshots and README (controller + user; not a subagent)

**Files:**
- Create: `tools/screenshots.sh`, `docs/screenshots/*.png`, `README.md`
- Test: `tests/bats/readme.bats`

**Interfaces:**
- `tools/screenshots.sh SHOT...` (`desktop`, `overview`, `quick-settings`, `ptyxis`, `osk`): captures the primary monitor through Mutter ScreenCast/`org.gnome.Shell.Screenshot` D-Bus (reuse capture approach from `~/Development/showcase/walkthrough.py`) to `docs/screenshots/<shot>-<variant>.png` or `<shot>.png`; strips PNG metadata chunks with a python stdlib rewrite; runs `pii_scan.py --ocr` on outputs. If D-Bus capture is refused, prints which shot to take manually and the target path.
- README sections, in order: title + one-line description; screenshots grid ("What you get"); Requirements; Quick start (`git clone --recursive https://github.com/nadelacruz-00/tokyonight-ubuntu && cd tokyonight-ubuntu && ./install.sh`, then `./install.sh --system`); Options table (every flag from Task 5); What each module changes (paths + settings); Uninstall; erhai / OnePlus Pad 3 extras; Troubleshooting (re-login, extensions on Wayland, no session bus, Flathub offline, OSK keycode cache); Regenerating assets; Development & tests (`make dev-deps test test-integration`); Credits & licences (link CREDITS.md); License (GPL-3.0).

- [ ] **Step 1: Write `readme.bats`:** `every image referenced in README exists`; `every image ≤ 1.5 MB`; `no PNG metadata chunks` (`pii_scan.py docs/screenshots`); `README documents every install.sh flag` (parse `--help` flags, grep README); `README has no PII` (pii scan).
- [ ] **Step 2:** Write `tools/screenshots.sh` and README text (images pending).
- [ ] **Step 3 (with the user):** ask the user to create or approve a throwaway `demo` account (hostname shown generic) and log into it; run `./install.sh` there, then `tools/screenshots.sh` for each shot and both variants; GDM shot taken at the greeter or omitted with a README note. Review every image with the user before committing.
- [ ] **Step 4:** `make test` → PASS.
- [ ] **Step 5:** Commit `docs: README with screenshots`.

---

### Task 12: Publish

- [ ] **Step 1:** `make test && make test-integration && python3 -I helpers/pii_scan.py --history --denylist .pii-denylist .` → all PASS, zero PII hits (local denylist contains the owner's real name, username, hostname, email).
- [ ] **Step 2:** `gh repo create nadelacruz-00/tokyonight-ubuntu --public --source . --description "Tokyo Night (Rewaita) theme installer for Ubuntu 26.04 aarch64 GNOME" --push`; `gh repo edit --add-topic tokyonight,gnome,ubuntu,aarch64,rewaita,dotfiles`.
- [ ] **Step 3:** `gh run watch` the CI run → `lint`, `pii`, `unit`, `integration` green (`network` may fail; report it). Fix and push until green.
- [ ] **Step 4:** Report repo URL and CI status to the user.
