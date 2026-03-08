# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
