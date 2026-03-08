"""
Launcher module — locates the bundled ``verisync.sh`` and exec's it,
passing through any command-line arguments.
"""

from __future__ import annotations

import importlib.resources
import os
import sys
import tempfile


def main() -> None:
    """Entry point for the ``verisync`` console script."""
    try:
        # Python 3.9+: files() API
        ref = importlib.resources.files("verisync").joinpath("verisync.sh")
        with importlib.resources.as_file(ref) as script_path:
            _exec_script(script_path)
    except AttributeError:
        # Python 3.8 fallback
        here = os.path.dirname(__file__)
        script_path = os.path.join(here, "verisync.sh")
        if not os.path.isfile(script_path):
            sys.exit(
                "verisync: could not locate verisync.sh inside the installed package. "
                "Please reinstall with: pip install --force-reinstall verisync"
            )
        _exec_script(script_path)


def _exec_script(script_path: "os.PathLike[str]") -> None:
    """Normalise line endings, write a clean temp script, then exec it."""
    import platform

    if platform.system() == "Windows":
        sys.exit(
            "verisync is a Bash script and is not supported on Windows.\n"
            "Please use WSL2 or a Linux/macOS environment."
        )

    with open(str(script_path), "rb") as fh:
        raw = fh.read()

    # Always strip ALL carriage returns before exec — guards against CRLF or
    # CR-only line endings regardless of how the wheel was built or unpacked.
    clean = raw.replace(b"\r", b"")

    tmp = tempfile.NamedTemporaryFile(
        prefix="verisync_", suffix=".sh", delete=False
    )
    tmp.write(clean)
    tmp.close()
    os.chmod(tmp.name, 0o755)

    # Replace current process with bash — preserves TTY, signals, exit codes
    os.execv("/bin/bash", ["/bin/bash", tmp.name] + sys.argv[1:])
