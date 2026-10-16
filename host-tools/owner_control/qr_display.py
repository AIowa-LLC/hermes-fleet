"""Private local QR presentation. The bearer is input data, never a process argument."""
from __future__ import annotations

import os
import json
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tempfile
from urllib.parse import parse_qs, urlsplit

try:
    from .readiness import normalise_origin
except ImportError:
    from readiness import normalise_origin


class DisplayFailure(RuntimeError):
    def __init__(self):
        super().__init__("private local QR display failed")


def validate_link(link: str, invitation_id: str) -> None:
    if not link.isascii() or len(link) > 2048 or any(ord(c) <= 32 for c in link):
        raise DisplayFailure()
    try:
        parts = urlsplit(link)
        normalise_origin(f"{parts.scheme}://{parts.netloc}")
        fields = parse_qs(parts.fragment, strict_parsing=True)
        if (parts.path != "/pair" or parts.query or set(fields) != {"v", "i", "s"}
                or fields["v"] != ["1"] or fields["i"] != [invitation_id]
                or not re.fullmatch(r"[A-Za-z0-9_-]{22}", invitation_id)
                or len(fields["s"]) != 1 or not re.fullmatch(r"[A-Za-z0-9_-]{43}", fields["s"][0])):
            raise DisplayFailure()
    except (ValueError, KeyError):
        raise DisplayFailure() from None


def display_capability(*, runner=subprocess.run) -> bool:
    # First release supports macOS user GUI only. SSH/headless sessions never count as a display.
    if sys.platform != "darwin" or os.environ.get("SSH_CONNECTION") or os.environ.get("SSH_TTY"):
        return False
    if not shutil.which("qrencode") or not Path("/usr/bin/qlmanage").is_file():
        return False
    try:
        result = runner(["/bin/launchctl", "managername"], capture_output=True, timeout=5, check=False)
        return result.returncode == 0 and result.stdout.strip() == b"Aqua"
    except (OSError, subprocess.SubprocessError):
        return False


def render_private(link: str, *, invitation_id: str, home: Path, runtime_dir: Path,
                   runner=subprocess.run, capability=display_capability) -> bool:
    """Show in Quick Look until closed/expiry; always remove the private PNG.

    A successful process proves launch/exit only. The owner's separate current
    observation receipt is required before issuance and proves private visibility.
    """
    validate_link(link, invitation_id)
    if not home.is_dir() or not runtime_dir.is_dir() or not capability():
        raise DisplayFailure()
    if runner is subprocess.run and capability is display_capability:
        # A main-thread helper can handle TERM/INT even when the plugin called us in to_thread.
        payload = json.dumps({"link": link, "invitation_id": invitation_id,
                              "home": str(home), "runtime_dir": str(runtime_dir)}).encode()
        try:
            result = subprocess.run([sys.executable, str(Path(__file__).resolve()), "--display-child"],
                                    input=payload, capture_output=True, timeout=620, check=False)
        except (OSError, subprocess.SubprocessError):
            raise DisplayFailure() from None
        if result.returncode != 0:
            raise DisplayFailure()
        return True
    qrencode = shutil.which("qrencode")
    if not qrencode:
        raise DisplayFailure()
    try:
        with tempfile.TemporaryDirectory(prefix="fleet-private-qr-") as directory:
            root = Path(directory)
            root.chmod(0o700)
            image = root / "invitation.png"
            # Precreate restrictive file before qrencode opens it; no exposure under a loose umask.
            descriptor = os.open(image, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            os.close(descriptor)
            generated = runner([qrencode, "-t", "PNG", "-o", str(image)], input=link.encode(),
                               capture_output=True, timeout=10, check=False)
            if generated.returncode != 0 or image.stat().st_size == 0:
                raise DisplayFailure()
            shown = runner(["/usr/bin/qlmanage", "-p", str(image)], capture_output=True,
                           timeout=600, check=False)
            if shown.returncode != 0:
                raise DisplayFailure()
            return True
    except (OSError, subprocess.SubprocessError):
        raise DisplayFailure() from None


def _child_main() -> int:
    def interrupted(_signal, _frame):
        raise DisplayFailure()
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    try:
        payload = json.loads(sys.stdin.buffer.read(8193))
        # A wrapper avoids recursively starting another child, retaining the same secure renderer.
        render_private(payload["link"], invitation_id=payload["invitation_id"],
                       home=Path(payload["home"]), runtime_dir=Path(payload["runtime_dir"]),
                       runner=lambda *args, **kwargs: subprocess.run(*args, **kwargs))
        return 0
    except (DisplayFailure, OSError, ValueError, TypeError, KeyError):
        return 2


if __name__ == "__main__":
    raise SystemExit(_child_main() if sys.argv[1:] == ["--display-child"] else 2)
