"""Run against a built engine. Never authenticates or reads a real user cache."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile

binary = Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix="tops-engine-smoke-") as temporary:
    directory = Path(temporary) / "session"
    requests = [
        {"id": 1, "method": "status", "params": {}},
        {"id": 2, "method": "play", "params": {"uri": "spotify:track:invalid"}},
        {"id": 3, "method": "authContext", "params": {}},
        {"id": 4, "method": "partnerAuthContext", "params": {}},
        {"id": 5, "method": "trimMemory", "params": {}},
        {"id": 6, "method": "shutdown", "params": {}},
    ]
    process = subprocess.run(
        [str(binary), "--data-dir", str(directory)],
        input="bad-json\n" + "\n".join(map(json.dumps, requests)) + "\n",
        capture_output=True, text=True, timeout=10,
    )
    assert process.returncode == 0, process.stderr
    messages = [json.loads(line) for line in process.stdout.splitlines()]
    assert messages[0]["event"] == "ready", messages
    assert len(messages) == 8, messages
    assert messages[1] == {"id": None, "error": "Invalid JSON request"}, messages
    assert messages[2]["result"]["connected"] is False, messages
    assert messages[3]["id"] == 2 and "error" in messages[3], messages
    assert messages[4]["id"] == 3 and "error" in messages[4], messages
    assert messages[5] == {"id": 4, "error": "Sign in with Spotify first"}, messages
    assert messages[6]["id"] == 5 and messages[6]["result"]["released_bytes"] >= 0, messages
    assert messages[7] == {"id": 6, "result": {"stopped": True}}, messages
    assert directory.stat().st_mode & 0o777 == 0o700
    device = directory / "device-id"
    assert device.stat().st_mode & 0o777 == 0o600
    identity = device.read_text()
    # EOF must terminate without orphaning a daemon, and identity must remain stable.
    second = subprocess.run(
        [str(binary), "--data-dir", str(directory)],
        input="", capture_output=True, text=True, timeout=10,
    )
    assert second.returncode == 0, second.stderr
    assert device.read_text() == identity
    assert not (directory / "oauth.json").exists()
print("Passed: JSON protocol, unauthenticated errors, 0700/0600 permissions, stable identity, shutdown and EOF.")
