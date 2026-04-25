# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.3.0]  2026-04-25

### Added

- **Session discovery across login nodes** — `verisync ls` lists active sessions
  across all login nodes via shared markers in `$HOME/.verisync/sessions`,
  showing session, login node, age, and status (alive / stale / remote)
- **Cross-node reattach** — `verisync -r` / `--reattach` picks a session and
  reattaches. If it lives on the current node, `screen -r` runs locally; if on
  another login node, verisync SSHes there and runs `screen -r <session>`
  automatically (2FA prompt expected). When the screen session has disappeared
  in the meantime, the SSH falls back to a login shell instead of exiting
- Stale-marker pruning (`p` option in the reattach picker) and auto-cleanup of
  the session marker on transfer exit
- Hostname is now part of the session name (`verisync_<host>_<pid>`) to avoid
  PID collisions between login nodes
- **Duplicate-transfer detection** — before starting a transfer, verisync
  compares the remote target and each `(source → destination)` pair against
  active session markers. Any pair that overlaps a running batch is reported
  with its session and login node, and the user can abort, kill the
  conflicting session(s), or ignore. Kill applies to local-node sessions only;
  cross-node conflicts are reported but skipped on kill. Per-pair matching
  catches partial overlap (e.g. one shared source out of several) that
  whole-batch equality would miss
- **Pre-wrap duplicate check** — when full config is provided on the CLI, the
  duplicate-pair check runs *before* the screen/tmux wrap so abort messages
  reach the user's terminal instead of being eaten by a dying screen session;
  interactive runs still defer the check until after Step 1 inside the wrap

### Changed

- `--yes` no longer silently aborts on a duplicate-pair conflict — it prints
  an explicit "auto-confirms safe paths only" message pointing at the conflict
  list and suggests re-running interactively to choose abort/kill/ignore
- Session markers now record `REMOTE`, `SOURCES`, and `DESTS` (joined with US
  `\x1f` so paths with spaces are safe) to power cross-node duplicate detection

## [1.2.1]  2026-03-09

### Fixed

- **Help command** — improved output formatting and usage clarity; moved help handling before screen/tmux wrap for better responsiveness

## [1.2.0]  2026-03-09

### Added

- **Batch mode** — support for transferring multiple sources in a single run with `--src` repeatable
  and flexible destination mapping (1 shared dest for all sources, or 1:1 source-to-dest mapping)
- **Auto-confirm option** (`-y`, `--yes`) — skip all interactive prompts for scripted/non-interactive usage
- **Improved remote free space check** — validates existing directories by walking up to find the
  deepest existing ancestor, preventing false "0 B free" reports for non-existent paths

### Fixed

- Script header comment corrected from `transfer.sh` to `verisync.sh`

## [1.1.0]  2026-03-08

### Added

- **Disconnect guard** — automatically re-launches the script inside a `screen` or `tmux` session
  when neither is already active, preventing transfer loss on SSH disconnects; re-attach instructions
  are printed to the terminal and repeated in the session header
- **Remote verification log** — SHA-256 verification results are now written to a timestamped
  `.log` file on the remote host (`verify_<name>_<timestamp>.log`) containing a full per-file
  OK / MISSING / MISMATCH report with expected vs. actual hashes for failures, plus a summary
- Remote log path is surfaced in the final output as `<user>@<host>:<path>` for easy retrieval
- "Press Enter to exit" prompt at end of run so the terminal window stays open when invoked
  from a launcher

## [1.0.0]  2026-03-08

### Added

- Initial release of `verisync`
- Interactive file/directory transfer with end-to-end SHA-256 checksum verification over SSH
- **rsync mode** (default)  incremental, resumable, bandwidth-efficient transfer
- **Zip mode** (`--zip`)  pack source into a `.tar.gz`, upload, and auto-extract on the remote
- SSH multiplexing via `ControlMaster`/`ControlPersist`  single control socket shared across
  all remote operations, including 2FA/password authentication flows
- Pre-transfer checks: SSH connectivity test, remote free-disk-space comparison against source size
- 100 GiB size warning with interactive confirmation prompt
- Remote-side checksum verification with per-file pass/fail reporting and overall `STATUS=OK/FAIL`
- CLI option parsing (`--src`, `--user`, `--host`, `--dest`, `--zip`, `--help`) with fully
  interactive fallback when flags are omitted
- Support for transferring both individual **files** and **directory trees**
- Human-readable size output (B / KiB / MiB / GiB / TiB) without dependency on `numfmt`
- Elapsed time reporting at end of run
- Python launcher shim (`pip install verisync`) providing a `verisync` console-script entry point
  compatible with Python 3.8  3.12
