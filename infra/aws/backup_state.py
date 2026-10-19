"""Private, atomic evidence shared by the backup worker and host monitor."""
import json
import os
import tempfile
from datetime import datetime, timezone


def utc_now():
    return datetime.now(timezone.utc).isoformat(timespec="microseconds")


def timestamp(value):
    if not isinstance(value, str):
        raise ValueError("timestamp missing")
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        raise ValueError("timestamp must have timezone")
    return parsed.timestamp()


def read_state(path):
    try:
        if path.is_symlink() or path.stat().st_size > 16384:
            return {}
        state = json.loads(path.read_text())
        return state if isinstance(state, dict) and state.get("schema_version") == 1 else {}
    except (OSError, ValueError):
        return {}


def atomic_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, temporary = tempfile.mkstemp(prefix=".status-", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as output:
            json.dump(value, output)
            output.write("\n")
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
        directory = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def capture_age(state, now):
    try:
        captured = timestamp(state.get("captured_at"))
        verified = timestamp(state.get("verified_at"))
        if not 0 < captured <= verified <= now + 60:
            raise ValueError("invalid backup timeline")
        return max(0, now - captured)
    except (TypeError, ValueError, OverflowError):
        return 1e12
