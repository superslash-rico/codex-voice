"""Atomic local checkpoints for reminder state and read-only transcript cursors."""
import copy
import json
import math
import os
from pathlib import Path
import time


def number(value):
    return type(value) in (int, float) and math.isfinite(value)


class RecoveryStore:
    def __init__(self, path, now=time.time):
        self.path = Path(path)
        self.now = now
        self.marker = None
        self.last_write = 0
        self.error = ""

    def load(self, engine, adapter):
        try:
            if not self.path.exists():
                return 0
            if self.path.stat().st_size > 2 * 1024 * 1024:
                raise ValueError()
            saved = json.loads(self.path.read_text())
            if not isinstance(saved, dict) or saved.get("version") != 1 or not number(saved.get("at")):
                raise ValueError()
            age = self.now() - saved["at"]
            if age < -5:
                engine.recovery.update(state="fresh", detail="恢复记录时间异常，等待新的任务事件")
                return 0
            if not isinstance(saved.get("seen", []), list):
                raise ValueError()
            for key in saved.get("seen", [])[:5000]:
                if isinstance(key, str) and len(key) <= 512:
                    engine.seen[key] = saved["at"]
            if engine.enabled:
                until = saved.get("mutedUntil", 0)
                if number(until) and self.now() < until <= self.now() + 86400:
                    engine.muted_until = until
                alerts = saved.get("alerts", [])
                if not isinstance(alerts, list):
                    raise ValueError()
                for raw in alerts[:500]:
                    alert = self.valid_alert(raw)
                    if not alert:
                        continue
                    if alert["id"] == saved.get("inFlight") and alert["count"]:
                        alert["count"] -= 1
                        alert["nextAt"] = max(self.now() + 1, alert["nextAt"] if alert["state"] == "snoozed" else 0)
                    alert["recoveryPending"] = bool(alert["thread"] and alert["source"] != "manual") or age > 86400
                    engine.alerts[alert["id"]] = alert
                    engine.seen[alert["id"]] = saved["at"]
            positions = saved.get("positions", {})
            if not isinstance(positions, dict):
                raise ValueError()
            for path, raw in list(positions.items())[:200]:
                if (not isinstance(path, str) or len(path) > 4096 or not path.endswith(".jsonl")
                        or not isinstance(raw, dict) or type(raw.get("offset")) is not int or raw["offset"] < 0
                        or not isinstance(raw.get("thread"), str) or len(raw["thread"]) > 256):
                    continue
                cursor = {"offset": raw["offset"], "thread": raw["thread"],
                          "turn": str(raw.get("turn", ""))[:256], "question": bool(raw.get("question", False)), "since": 0}
                adapter.positions[path] = cursor
                engine.verifying_threads.add(cursor["thread"])
            calls = saved.get("calls", {})
            if isinstance(calls, dict):
                adapter.calls = {key: tuple(value) for key, value in list(calls.items())[-500:]
                                 if isinstance(key, str) and isinstance(value, list) and len(value) == 2 and all(isinstance(v, str) for v in value)}
            adapter.recovery_floor = max(saved["at"] - 5, self.now() - 86400)
            adapter.restore_since = adapter.recovery_floor
            adapter.reconcile_until = engine.now() + 15
            engine.recovery.update(state="checking", restored=len(engine.alerts), detail="正在核对未处理事项")
            return len(engine.alerts)
        except (OSError, ValueError, TypeError, KeyError, RecursionError):
            # Treat recovery as a transaction: malformed state must not partly restore.
            engine.alerts.clear(); engine.seen.clear(); engine.verifying_threads.clear()
            engine.muted_until = 0
            adapter.positions.clear(); adapter.calls.clear(); adapter.recovery_floor = None
            self.error = "恢复记录无法读取，已跳过；新提醒仍可正常接收。"
            engine.recovery.update(state="fresh", detail=self.error)
            return 0

    @staticmethod
    def valid_alert(raw):
        if not isinstance(raw, dict) or raw.get("kind") not in {"result", "approval", "question", "blocked"} or raw.get("test") or raw.get("source") == "desktop-approval":
            return None
        for key in ("id", "thread", "turn", "title", "detail", "requestId", "source"):
            if not isinstance(raw.get(key, ""), str) or len(raw.get(key, "")) > (512 if key == "detail" else 256):
                return None
        if not raw.get("id") or any(not number(raw.get(key)) for key in ("createdAt", "nextAt")):
            return None
        if type(raw.get("count")) is not int or not 0 <= raw["count"] <= 1_000_000:
            return None
        alert = {key: raw.get(key, "") for key in ("id", "thread", "turn", "kind", "title", "detail", "requestId", "source")}
        alert.update(createdAt=raw["createdAt"], nextAt=raw["nextAt"], count=raw["count"], test=False,
                     state="snoozed" if raw.get("state") == "snoozed" else "pending",
                     manualReplay=raw.get("state") == "snoozed" and raw.get("manualReplay") is True)
        if number(raw.get("lastSpokenAt")):
            alert["lastSpokenAt"] = raw["lastSpokenAt"]
        return alert

    def save(self, engine, adapter, force=False):
        if not force and time.monotonic() - self.last_write < .75:
            return
        data = {"version": 1, "alerts": [a for a in engine.alerts.values() if not a["test"] and a.get("source") != "desktop-approval"],
                "seen": list(engine.seen)[-5000:], "mutedUntil": engine.muted_until,
                "positions": adapter.positions, "calls": dict(list(adapter.calls.items())[-500:]),
                "inFlight": engine.speaker.alert_id if engine.speaker.busy() and engine.speaker.alert_id in engine.alerts else None}
        marker = json.dumps(data, ensure_ascii=False, sort_keys=True)
        if marker == self.marker:
            return
        try:
            data = copy.deepcopy(data); data["at"] = self.now()
            temporary = self.path.with_suffix(".tmp")
            temporary.write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")
            temporary.chmod(0o600)
            os.replace(temporary, self.path)
            self.marker, self.last_write = marker, time.monotonic()
            self.error = ""
        except OSError:
            self.error = "暂时无法保存恢复记录，请检查本机可用空间。"
