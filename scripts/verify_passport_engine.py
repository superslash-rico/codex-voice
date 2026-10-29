#!/usr/bin/env python3
"""Exercise the packaged engine with simulated BLE feedback and isolated data."""
import argparse
import json
import os
from pathlib import Path
import select
import subprocess
import tempfile
import time


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("app", type=Path)
    args = parser.parse_args()
    app = args.app.resolve()
    resources = app / "Contents/Resources"
    python = app / "Contents/Frameworks/Python.framework/Versions/3.14/bin/python3.14"
    environment = {k: v for k, v in os.environ.items() if not k.startswith("PYTHON") and k != "__PYVENV_LAUNCHER__"}
    environment.update(PYTHONHOME=str(python.parent.parent), PYTHONPATH=str(resources),
                       PYTHONNOUSERSITE="1", PYTHONDONTWRITEBYTECODE="1", PYTHONSAFEPATH="1",
                       PATH="/usr/bin:/bin:/usr/sbin:/sbin")
    with tempfile.TemporaryDirectory(prefix="codex-passport-engine-") as folder:
        root = Path(folder)
        state = root / "state"; state.mkdir()
        codex = root / "codex"; codex.mkdir()
        (state / "settings.json").write_text(json.dumps({
            "audio_device": "AI Passport", "audio_device_uid": "codex-passport:ble"}))
        process = subprocess.Popen([str(python), "-s", str(resources / "voice_engine.py"),
                                    "--state-dir", str(state), "--codex-dir", str(codex)],
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   env=environment)
        buffer = bytearray()
        def send(event):
            process.stdin.write((json.dumps(event) + "\n").encode())
            process.stdin.flush()
        def until(predicate):
            end = time.monotonic() + 12
            while time.monotonic() < end:
                if b"\n" not in buffer:
                    readable, _, _ = select.select([process.stdout], [], [], max(0, end-time.monotonic()))
                    if not readable: break
                    data = os.read(process.stdout.fileno(), 65536)
                    if not data: break
                    buffer.extend(data)
                while b"\n" in buffer:
                    line, _, remainder = buffer.partition(b"\n")
                    buffer[:] = remainder
                    value = json.loads(line)
                    if predicate(value): return value
            raise AssertionError("Timed out waiting for the packaged engine")
        try:
            initial = until(lambda v: "alerts" in v)
            assert not initial["audio"]["available"]
            assert initial["passport"]["enabled"] and initial["passport"]["voiceEnabled"]
            assert initial["passport"]["petName"] == "Codex"
            assert not initial["audio"]["computerEnabled"]
            assert initial["audio"]["selectedUID"] != "codex-passport:ble"
            send({"action":"passport_feedback", "event":{"kind":"link", "connected":True}})
            send({"action":"presentation_mode", "active":True})
            until(lambda v: v.get("presentation", {}).get("active") is True)
            send({"action":"test", "target":"passport"})
            held = until(lambda v: bool(v.get("alerts")))
            assert held["presentation"]["active"] and held["alerts"][0]["count"] == 0
            send({"action":"clear_tests"})
            until(lambda v: "alerts" in v and not v["alerts"])
            send({"action":"presentation_mode", "active":False})
            until(lambda v: v.get("presentation", {}).get("active") is False)
            send({"action":"test", "target":"passport"})
            command = until(lambda v: v.get("passportCommand", {}).get("op") == "play")["passportCommand"]
            assert command["phrase"] == "test"
            send({"action":"passport_feedback", "event":{"kind":"audio", "id":command["id"], "phase":"started"}})
            active = until(lambda v: any(a["count"] == 1 for a in v.get("alerts", [])))
            alert = active["alerts"][0]
            assert active["speakingId"] == alert["id"]
            send({"action":"ack", "id":alert["id"]})
            until(lambda v: v.get("passportCommand", {}).get("op") == "stop")
            until(lambda v: "alerts" in v and not v["alerts"])
            send({"action":"passport_feedback", "event":{"kind":"link", "connected":False}})
            send({"action":"test"})
            offline = until(lambda v: bool(v.get("alerts")) and not v.get("audio", {}).get("available", True))
            assert offline["alerts"][0]["count"] == 0
            send({"action":"clear_tests"})
            until(lambda v: "alerts" in v and not v["alerts"])
            send({"action":"set_passport_settings","settings":{"voiceEnabled":False,"petName":"Rico"}})
            quiet = until(lambda v: v.get("passport",{}).get("petName") == "Rico")
            assert quiet["passport"]["enabled"] and not quiet["passport"]["voiceEnabled"]
            assert quiet["audio"]["silent"]
            saved = json.loads((state/"settings.json").read_text())
            assert saved["passport"] == {"enabled":True,"voiceEnabled":False,"petName":"Rico"}
            print(json.dumps({"packagedEngine":True, "presentationSilenceHandshake":True, "simulatedStartAcknowledgement":True,
                              "acknowledgementStopsPlayback":True, "disconnectPreservesCounter":True,
                              "legacyMigration":True,"independentAccessorySettingsPersisted":True,
                              "physicalBLE":"NOT RUN"}))
        finally:
            if process.poll() is None: send({"action":"quit"})
            try:
                _, errors = process.communicate(timeout=8)
            except subprocess.TimeoutExpired:
                process.kill(); process.communicate(); raise
            assert process.returncode == 0, errors.decode(errors="replace")[-1000:]


if __name__ == "__main__":
    main()
