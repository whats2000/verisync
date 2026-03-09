# verisync — Interactive Directory Transfer with Checksum Verification

<div align="center">

[![PyPI version](https://badge.fury.io/py/verisync.svg)](https://badge.fury.io/py/verisync)
[![Python Versions](https://img.shields.io/pypi/pyversions/verisync)](https://pypi.org/project/verisync/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

**A general-purpose interactive file/directory transfer utility with end-to-end SHA-256 checksum verification over SSH.**  
Transfer files or directories to a remote server via rsync or tar.gz, then automatically verify every file's integrity — all from a single command.

</div>

---

## Table of Contents

- [Features](#features)
- [Requirements](#requirements)
- [Installation](#installation)
  - [Via pip (recommended)](#via-pip-recommended)
  - [Via pipx (isolated)](#via-pipx-isolated)
  - [Manual install](#manual-install)
- [Usage](#usage)
  - [Arguments](#arguments)
  - [Examples](#examples)
- [Transfer Steps](#transfer-steps)
- [Modes: rsync vs zip](#modes-rsync-vs-zip)
- [Contributing](#contributing)
- [License](#license)

---

## Features

- 📁 **File and directory** — transfer a single file or an entire directory tree
- 📦 **Batch mode** — transfer multiple sources in one run with flexible destination mapping
- ✅ **End-to-end SHA-256 verification** — a checksum manifest is generated locally and re-verified remotely after transfer
- ♻️ **rsync mode** (default) — incremental, resumable, and bandwidth-efficient
- 🗜️ **Zip mode** (`--zip`) — packs each source into a `.tar.gz`, uploads, and auto-extracts on the remote
- 🔌 **SSH multiplexing** — a single SSH control socket is reused across all remote operations, including 2FA/password auth flows
- 📏 **Space checks** — remote free disk space is measured before transfer; warns if total exceeds 100 GiB
- 🖥️ **Interactive + CLI** — all parameters can be supplied as CLI flags or entered interactively at runtime
- 🤖 **Auto-confirm** (`-y`) — skip prompts for scripted/non-interactive usage
- 🕒 **Elapsed time** — reports total transfer and verification duration

---

## Requirements

| Requirement    | Notes                                                              |
| -------------- | ------------------------------------------------------------------ |
| **Bash >= 4.0** | Required for string manipulations and `set -euo pipefail`        |
| **rsync**      | Used for incremental file transfer in default mode                 |
| **ssh**        | SSH client with multiplexing (`ControlMaster`) support             |
| **sha256sum**  | Standard coreutils tool, available on all Linux/macOS systems      |
| **bc**         | Used for human-readable size arithmetic                            |
| **tar**        | Only required when using `--zip` mode                              |

> **Note:** `verisync` only needs to be installed on the **source machine**. The remote side requires only `sha256sum` and standard POSIX shell tools — no remote installation needed.

---

## Installation

### Via pip (recommended)

```bash
pip install verisync
```

This places the `verisync` command on your `PATH`.

### Via pipx (isolated)

```bash
pipx install verisync
```

### Manual install

```bash
git clone https://github.com/whats2000/verisync.git
cd verisync
bash verisync.sh --help
```

---

## Usage

```
verisync [OPTIONS]
```

### Arguments

| Flag                  | Description                                               |
| --------------------- | --------------------------------------------------------- |
| `-s, --src <path>`    | Local source file or directory to transfer (repeat for batch) |
| `-u, --user <user>`   | Remote SSH username                                       |
| `-H, --host <host>`   | Remote SSH hostname or IP address                         |
| `-d, --dest <path>`   | Remote destination (1 shared dest OR one per --src)       |
| `--zip`               | Pack each source into `tar.gz` before transferring        |
| `-y, --yes`           | Auto-confirm all prompts (non-interactive mode)           |
| `-h, --help`          | Show usage and exit                                       |

Any flag not supplied on the command line will be prompted interactively.

### Examples

**Interactive mode** (prompts for all parameters):

```bash
verisync
```

**Fully specified via CLI**:

```bash
verisync --src /data/project --user alice --host hpc.example.com --dest /scratch/alice/
```

**Batch mode** (multiple sources to shared destination):

```bash
verisync -s /data/file1.txt -s /data/dir2 -d /remote/shared/ -u alice -H hpc.example.com
```

**Batch mode** (1:1 source-to-destination mapping):

```bash
verisync -s /local/a -s /local/b -d /remote/x -d /remote/y -u alice -H hpc.example.com
```

**Use zip mode for compressed uploads**:

```bash
verisync -s /data/project -u alice -H hpc.example.com -d /scratch/alice/ --zip
```

**Non-interactive mode** (auto-confirm all prompts):

```bash
verisync -s /data/project -u alice -H hpc.example.com -d /scratch/alice/ -y
```

---

## Transfer Steps

| Step | Description                                                                |
| ---- | -------------------------------------------------------------------------- |
| 1    | Collect source(s), destination(s), remote user, and host                   |
| 2    | Measure total local size; warn if > 100 GiB                               |
| 3    | Test SSH connectivity; check remote free disk space for each destination  |
| 4    | For each source: generate SHA-256 checksum manifest                       |
| 5    | For each source: transfer files + manifest via rsync (or tar.gz)          |
| 6    | For each source: verify checksums remotely                                |
| 7    | Print batch summary (pass/fail per source)                                |

---

## Modes: rsync vs zip

| Feature             | rsync (default)         | `--zip` mode              |
| ------------------- | ----------------------- | ------------------------- |
| Resumable?          | Yes                     | No                        |
| Incremental?        | Yes                     | No                        |
| Single archive?     | No                      | Yes (per source)          |
| Compression         | `-z` (inline)           | `gzip` (pre-compressed)   |
| Remote extraction   | Not needed              | Auto-extracted via `tar`  |

---

## Contributing

Bug reports and pull requests are welcome at [github.com/whats2000/verisync](https://github.com/whats2000/verisync).

---

## License

MIT — see [LICENSE](LICENSE) for details.