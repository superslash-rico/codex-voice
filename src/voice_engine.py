#!/usr/bin/env python3
"""Local voice reminders with optional official account-quota reads; no model calls."""
from __future__ import annotations

import argparse
import collections
import datetime as dt
import hashlib
import json
import math
import os
from pathlib import Path
import queue
import re
import signal
import sqlite3
import subprocess
import sys
import threading
import time
import uuid

from speech_settings import SpeechSettings, system_voices
from codex_usage import UsageMonitor
from reminder_rules import KindRule, QuietHours, load_rules, update_rules
from reminder_recovery import RecoveryStore
from passport_output import PassportOutput, PASSPORT_UID, PASSPORT_NAME
from accessory_settings import PassportSettings, migrate_preferences

INTERVALS = (30, 60, 180)
PREVIEW_ID = "speech-preview"
USAGE_RESET_ID = "usage-reset:"
USAGE_RESET_PREVIEW_ID = USAGE_RESET_ID + "preview"
USAGE_LOW_ID = "usage-low:"
USAGE_LOW_PREVIEW_ID = USAGE_LOW_ID + "preview"
DEFAULT_PAUSE_MINUTES = 15
KINDS = {"approval": "等待审批", "question": "等待回答", "result": "已有结果", "blocked": "需要关注", "test": "播报测试"}
VERSION = "0.10.0-presenter.1"


def clean_label(value, fallback="当前任务"):
    value = re.sub(r"[\x00-\x1f<>]", "", str(value or "")).strip()
    # Keep private commands, URLs, and long text out of spoken labels.
    if not value or "http" in value or "/Users/" in value:
        return fallback
    return value[:24]


class ComputerSpeaker:
    def __init__(self, audio_device="", device_provider=None, device_uid="", voice_provider=None, passport_emit=None):
        self.process = None
        self.computer_alert_id = None
        self.audio_device = audio_device
        self.audio_device_uid = device_uid
        self.current_name = audio_device or "Mac 当前默认输出"
        self.device_id = None
        self.output_devices = []
        self.default_name = ""
        self.device_provider = device_provider
        self.available = not bool(audio_device)
        self.muted = False
        self.volume = None
        self.next_device_check = 0
        self.last_error = ""
        self.speech = SpeechSettings()
        self.voice_provider = voice_provider or system_voices
        self.voices = None
        self.voice_error = ""
        self.playback_error = ""

    def refresh_voices(self):
        try:
            self.voices = self.voice_provider()
            self.voice_error = "" if self.voices else "未找到可用的系统音色，请检查 macOS 的语音设置。"
        except (OSError, ValueError, subprocess.SubprocessError):
            self.voices = []
            self.voice_error = "无法读取系统音色，请点击刷新重试。"

    def speech_status(self):
        if self.voices is None:
            self.refresh_voices()
        error = self.voice_error
        if not error and not any(voice["id"] == self.speech.voice for voice in self.voices):
            error = "所选音色不可用，请选择其他音色或安装后刷新。"
        return {"voices": self.voices, "ready": not bool(error), "error": error or self.playback_error}

    def refresh_audio(self):
        if time.monotonic() < self.next_device_check:
            return
        self.next_device_check = time.monotonic() + 4
        try:
            if self.device_provider:
                provided = self.device_provider()
                if isinstance(provided, dict):
                    info = provided
                else:
                    info = {"connected": not self.audio_device or self.audio_device in provided, "name": self.audio_device, "muted": self.muted, "volume": self.volume, "devices": [{"name": name, "uid": "name:" + name, "connected": True} for name in provided]}
            else:
                helper = Path(__file__).resolve().parent / "AudioDeviceInfo"
                if helper.is_file():
                    args = [str(helper), self.audio_device]
                    if self.audio_device_uid:
                        args += ["--uid", self.audio_device_uid]
                    result = subprocess.run(args, capture_output=True, text=True, timeout=2, check=True)
                    info = json.loads(result.stdout)
                else:
                    result = subprocess.run(["/usr/bin/say", "-a", "?"], capture_output=True, text=True, timeout=2)
                    names = [m.group(1).strip() for line in result.stdout.splitlines() if (m := re.match(r"\s*\d+\s+(.+)", line))]
                    info = {"connected": not self.audio_device_uid and (not self.audio_device or self.audio_device in names), "name": self.audio_device, "devices": [{"name": name, "uid": "name:" + name, "connected": True} for name in names]}
            self.available = bool(info.get("connected"))
            self.current_name = info.get("name") or self.audio_device or "Mac 当前默认输出"
            self.device_id = info.get("id")
            self.output_devices = info.get("devices", [])
            self.default_name = info.get("defaultName", "")
            self.muted = bool(info.get("muted", False))
            self.volume = info.get("volume")
            self.last_error = "" if self.available else "所选扬声器未连接，已暂停播报"
            if self.available and self.muted:
                self.last_error = "所选扬声器处于静音，已暂停播报"
            elif self.available and self.volume == 0:
                self.last_error = "所选扬声器音量为零，已暂停播报"
            if self.last_error:
                ComputerSpeaker.stop(self)
        except (OSError, ValueError, subprocess.SubprocessError):
            self.available = False
            self.last_error = "无法读取扬声器状态，已暂停播报"
            ComputerSpeaker.stop(self)

    def set_device(self, name, uid=""):
        if not isinstance(name, str) or not isinstance(uid, str) or len(name) > 256 or len(uid) > 1024 or re.search(r"[\x00-\x1f]", name + uid):
            return False
        if name == self.audio_device and uid == self.audio_device_uid:
            return False
        ComputerSpeaker.stop(self)
        self.audio_device = name
        self.audio_device_uid = uid
        self.current_name = name or "Mac 当前默认输出"
        self.device_id = None
        self.muted = False
        self.volume = None
        self.next_device_check = 0
        self.refresh_audio()
        return True

    def audio_status(self):
        self.refresh_audio()
        return {"device": self.current_name, "selectedDevice": self.audio_device, "selectedUID": self.audio_device_uid, "followSystem": not bool(self.audio_device or self.audio_device_uid), "devices": self.output_devices, "defaultName": self.default_name, "available": self.available, "ready": self.available and not self.muted and self.volume != 0, "muted": self.muted, "volume": self.volume, "error": self.last_error}

    def busy(self):
        if self.process is None:
            return False
        status = self.process.poll()
        if status not in (None, 0, -15):
            self.playback_error = "语音播放未成功，请重新选择音色后试听。"
        return status is None

    def speak(self, alert_id, text):
        if ComputerSpeaker.busy(self):
            return False
        self.next_device_check = 0
        self.refresh_audio()
        if not self.available or self.muted or self.volume == 0:
            return False
        if not ComputerSpeaker.speech_status(self)["ready"]:
            return False
        args = ["/usr/bin/say", "-v", self.speech.voice, "-r", str(self.speech.rate)]
        if self.audio_device or self.audio_device_uid:
            args += ["-a", str(self.device_id) if self.device_id is not None else self.audio_device]
        try:
            self.process = subprocess.Popen(args + ["--", text], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except OSError:
            self.playback_error = "无法启动系统语音，请稍后重试。"
            return False
        self.playback_error = ""
        self.computer_alert_id = alert_id
        return True

    def stop(self, alert_id=None):
        if alert_id is None or self.computer_alert_id == alert_id:
            if self.process is not None and self.process.poll() is None:
                self.process.terminate()
            self.computer_alert_id = None


class Speaker(ComputerSpeaker):
    """One reminder scheduler, independently controlled computer/badge routes."""
    def __init__(self, audio_device="", device_provider=None, device_uid="", voice_provider=None, passport_emit=None):
        legacy = device_uid == PASSPORT_UID
        super().__init__("" if legacy else audio_device, device_provider,
                         "" if legacy else device_uid, voice_provider)
        self.passport = PassportOutput(passport_emit)
        self.passport_settings = PassportSettings(enabled=legacy, voiceEnabled=legacy)
        self.computer_enabled = not legacy
        self.legacy_passport_mode = legacy
        self.last_alert_id = None
        self.last_badge_started = False

    @property
    def alert_id(self):
        if ComputerSpeaker.busy(self):
            return self.computer_alert_id
        with self.passport.condition:
            p = self.passport.current
            if p and p["started"] and not p["finished"]:
                return p["alertId"]
        return self.last_alert_id

    @alert_id.setter
    def alert_id(self, value):
        self.last_alert_id = value
        self.computer_alert_id = value

    def active_alert_id(self):
        if ComputerSpeaker.busy(self):
            return self.computer_alert_id
        with self.passport.condition:
            p = self.passport.current
            return p["alertId"] if p and p["started"] and not p["finished"] else None

    def passport_feedback(self, event):
        if isinstance(event,dict) and event.get("kind")=="dictation" and event.get("active") is True:
            ComputerSpeaker.stop(self)
        self.passport.feedback(event)

    def configure_passport(self, patch):
        updated = self.passport_settings.update(patch)
        if (self.passport_settings.enabled and not updated.enabled) or (self.passport_settings.voiceEnabled and not updated.voiceEnabled):
            self.passport.stop()
        self.passport_settings = updated
        self.legacy_passport_mode = False

    def configure_computer(self, enabled):
        if type(enabled) is not bool:
            raise ValueError("电脑播报开关须为开启或关闭。")
        if not enabled:
            ComputerSpeaker.stop(self)
        self.computer_enabled = enabled
        self.legacy_passport_mode = False

    def passport_status(self):
        remote = self.passport.status()
        return dict(self.passport_settings.to_dict(), connected=remote["available"],
                    volume=remote["volume"], error=remote["error"],
                    firmware=self.passport.firmware, petNameSupported=self.passport.pet_name_supported,petSync=dict(self.passport.pet_sync))

    def audio_status(self):
        computer = ComputerSpeaker.audio_status(self)
        badge = self.passport.status()
        badge_on = self.passport_settings.enabled and self.passport_settings.voiceEnabled
        ready = (self.computer_enabled and computer["ready"]) or (badge_on and badge["available"])
        available = (self.computer_enabled and computer["available"]) or (badge_on and badge["available"])
        error = "" if ready else "；".join(x for x in [computer["error"] if self.computer_enabled else "",badge["error"] if badge_on else ""] if x)
        return dict(computer,available=bool(available),ready=bool(ready),error=error,
                    computerEnabled=self.computer_enabled,computerAvailable=computer["available"],
                    computerReady=computer["ready"],computerError=computer["error"],computerSpeaking=ComputerSpeaker.busy(self),
                    silent=not self.computer_enabled and not badge_on)

    def speech_status(self):
        computer = ComputerSpeaker.speech_status(self)
        badge_on = self.passport_settings.enabled and self.passport_settings.voiceEnabled
        ready = (self.computer_enabled and computer["ready"]) or (badge_on and self.passport.ready())
        return dict(computer,ready=bool(ready),computerReady=computer["ready"],
                    error="" if ready else computer["error"],computerError=computer["error"],fixedPhrases=not self.computer_enabled and badge_on)

    def busy(self):
        return ComputerSpeaker.busy(self) or (self.passport_settings.enabled and self.passport.busy())

    def speak_to(self, alert_id, text, kind, target=None):
        if self.busy():
            return False
        started = False
        if self.computer_enabled and target in (None,"computer"):
            started = ComputerSpeaker.speak(self,alert_id,text)
        self.last_badge_started = False
        if self.passport_settings.enabled and self.passport_settings.voiceEnabled and target in (None,"passport"):
            self.last_badge_started = self.passport.speak(alert_id,kind)
            started = self.last_badge_started or started
        if started:
            self.last_alert_id = alert_id
        return started

    def speak_kind(self,alert_id,text,kind):
        return self.speak_to(alert_id,text,kind)

    def speak(self,alert_id,text):
        # A custom-voice preview belongs to the computer. Legacy constructor
        # callers remain compatible; stored preferences migrate before init.
        if self.legacy_passport_mode:
            return self.speak_to(alert_id,text,"test",target="passport")
        return self.computer_enabled and ComputerSpeaker.speak(self,alert_id,text)

    def stop(self,alert_id=None):
        self.passport.stop(alert_id)
        ComputerSpeaker.stop(self,alert_id)
        if alert_id is None or self.last_alert_id==alert_id:
            self.last_alert_id = None


class Engine:
    def __init__(self, speaker, now=time.time, enabled=True, speech_settings=None, pause_minutes=DEFAULT_PAUSE_MINUTES, usage_reset_enabled=True, usage_low_enabled=True, usage_low_threshold=20, reminder_rules=None, quiet_hours=None):
        self.passport_error = ""
        self.output_error = ""
        self.speaker = speaker
        self.now = now
        self.enabled = enabled
        self.alerts = {}
        self.seen = collections.OrderedDict()
        self.muted_until = 0.0
        self.last_spoken = 0.0
        self.monitor = {"state": "starting", "detail": "正在连接本地事件", "files": 0, "lastEventAt": None, "hookLastSeen": None}
        self.history = collections.deque(maxlen=40)
        self.speech = SpeechSettings.load(speech_settings)
        self.speaker.speech = self.speech
        self.settings_error = ""
        self.preview_error = ""
        try:
            self.pause_minutes = self.valid_pause_minutes(pause_minutes)
        except ValueError:
            self.pause_minutes = DEFAULT_PAUSE_MINUTES
        self.pause_error = ""
        self.usage_reset_enabled = usage_reset_enabled if type(usage_reset_enabled) is bool else True
        self.usage_reset_queue = collections.deque(maxlen=8)
        self.usage_reset_error = ""
        self.last_usage_reset = {}
        self.usage_low_enabled = usage_low_enabled if type(usage_low_enabled) is bool else True
        self.usage_low_threshold = usage_low_threshold if type(usage_low_threshold) is int and 1 <= usage_low_threshold <= 99 else 20
        self.pending_usage_low = None
        self.spoken_usage_lows = collections.deque(maxlen=512)
        self.last_usage_low = {}
        self.usage_low_error = ""
        self.on_usage_low_spoken = lambda event: True
        self.rules = load_rules(reminder_rules)
        self.rules_error = ""
        self.quiet = QuietHours.load(quiet_hours)
        self.quiet_error = ""
        self.was_quiet = False
        self.verifying_threads = set()
        self.recovery = {"state": "ready", "restored": 0, "detail": "恢复记录已就绪"}
        self.sleeping = False
        self.presentation_until = 0.0
        self.activity = {}

    def rule(self, alert):
        return self.rules.get(alert["kind"], KindRule())

    def play(self, key, text, kind):
        if self.presentation_active():
            return False
        target = self.alerts.get(key,{}).get("outputTarget")
        accessory = getattr(self.speaker,"passport_settings",None)
        if ((accessory and accessory.enabled and accessory.voiceEnabled and target in (None,"passport"))
            or getattr(self.speaker,"audio_device_uid","") == PASSPORT_UID):
            prepare = getattr(self,"before_device_play",None)
            if prepare: prepare()
        if hasattr(self.speaker,"speak_to"):
            return self.speaker.speak_to(key,text,kind,target)
        method = getattr(self.speaker,"speak_kind",None)
        return method(key,text,kind) if method else self.speaker.speak(key,text)

    def presentation_active(self):
        return self.now() < self.presentation_until

    def quiet_blocks(self, kind=None):
        return self.presentation_active() or (self.quiet.active(self.now()) and not (kind == "approval" and self.quiet.allow_approval))

    def interrupt_current(self):
        key = self.speaker.alert_id if self.speaker.busy() else None
        if key in self.alerts:
            alert = self.alerts[key]
            alert["count"] = max(0, alert["count"] - 1)
            alert.pop("lastSpokenAt", None)
            alert["nextAt"] = self.now()
        return key

    def sync_quiet(self):
        active = self.quiet.active(self.now())
        if active:
            key = self.speaker.alert_id if self.speaker.busy() else None
            kind = self.alerts.get(key, {}).get("kind")
            if key and not (kind == "approval" and self.quiet.allow_approval):
                self.interrupt_current(); self.speaker.stop(key)
            self.discard_usage_resets(); self.discard_usage_lows()
        self.was_quiet = active

    def configure_rules(self, patch):
        try:
            updated = update_rules(self.rules, patch)
        except ValueError as error:
            self.rules_error = str(error)
            return False
        self.rules = updated; self.rules_error = ""
        for alert in self.alerts.values():
            if alert["kind"] not in patch:
                continue
            rule = self.rule(alert)
            if not rule.enabled and self.speaker.alert_id == alert["id"]:
                self.interrupt_current(); self.speaker.stop(alert["id"])
            if alert["state"] == "pending" and not alert.get("manualReplay"):
                schedule = rule.intervals or self.speech.intervals
                alert["nextAt"] = max(self.now(), alert.get("lastSpokenAt", self.now()) + schedule[min(max(0, alert["count"] - 1), 2)]) if alert["count"] else self.now()
        return True

    def configure_quiet(self, patch):
        try:
            self.quiet = self.quiet.update(patch)
        except ValueError as error:
            self.quiet_error = str(error)
            return False
        self.quiet_error = ""
        self.sync_quiet()
        return True

    def usage_period_label(self, event):
        periods = []
        for window in event.get("windows", []):
            minutes = window.get("windowMinutes")
            if type(minutes) not in (int, float) or not math.isfinite(minutes) or not 0 < minutes <= 10_000_000:
                continue
            name = "每周" if minutes == 10080 else "每日" if minutes == 1440 else f"{int(minutes / 60)}小时" if minutes % 60 == 0 else f"{minutes:g}分钟"
            periods.append(name)
        return "和".join(periods)

    def usage_reset_text(self, event, preview=False):
        prefix = self.speech.address + "，" if self.speech.address else ""
        label = self.usage_period_label(event)
        remaining = event.get("remainingPercent", 100)
        return prefix + ("这是额度重置提醒试听。" if preview else "") + f"Codex{label}额度已重置，当前总剩余用量百分之{remaining}。"

    def usage_low_text(self, event, preview=False):
        prefix = self.speech.address + "，" if self.speech.address else ""
        label = self.usage_period_label(event)
        threshold = event.get("threshold", self.usage_low_threshold)
        remaining = event.get("remainingPercent", max(0, threshold - 1))
        return prefix + ("这是低额度提醒试听。" if preview else "") + f"Codex{label}额度偏低，当前总剩余用量百分之{remaining}，已低于设置的百分之{threshold}。"

    def discard_usage_lows(self, stop=False):
        self.pending_usage_low = None
        if self.last_usage_low.get("state") == "queued":
            self.last_usage_low["state"] = "skipped"
        if stop and str(self.speaker.alert_id or "").startswith(USAGE_LOW_ID):
            self.speaker.stop(self.speaker.alert_id)

    def update_usage_low(self, event):
        if not event or not self.enabled or not self.usage_low_enabled or self.now() < self.muted_until or self.quiet_blocks() or self.sleeping:
            self.discard_usage_lows()
            return
        windows = [w for w in event["windows"] if w["key"] not in self.spoken_usage_lows]
        if not windows:
            self.discard_usage_lows()
            return
        identifier = hashlib.sha256(":".join(sorted(w["key"] for w in windows)).encode()).hexdigest()
        self.pending_usage_low = dict(event, id=identifier, windows=windows)
        if self.last_usage_low.get("id") != identifier or self.last_usage_low.get("state") != "queued":
            self.last_usage_low = {"id": identifier, "at": event["at"], "state": "queued", "threshold": event["threshold"]}

    def configure_usage_low(self, settings):
        if not isinstance(settings, dict) or set(settings) - {"enabled", "threshold"}:
            self.usage_low_error = "无法读取低额度提醒设置。"
            return False
        enabled = settings.get("enabled", self.usage_low_enabled)
        threshold = settings.get("threshold", self.usage_low_threshold)
        if type(enabled) is not bool or type(threshold) is not int or not 1 <= threshold <= 99:
            self.usage_low_error = "提醒阈值须为 1–99 之间的整数。"
            return False
        self.discard_usage_lows(stop=not enabled)
        self.usage_low_enabled, self.usage_low_threshold = enabled, threshold
        self.usage_low_error = ""
        return True

    def usage_reset(self, event):
        if not event.get("id") or not self.remember(USAGE_RESET_ID + event["id"]):
            return
        self.last_usage_reset = {"id": event["id"], "at": event["at"], "state": "queued"}
        self.history.append({"at": self.now(), "action": "usage_reset_detected", "id": event["id"]})
        if not self.enabled or not self.usage_reset_enabled or self.now() < self.muted_until or self.quiet_blocks() or self.sleeping:
            self.last_usage_reset["state"] = "skipped"
            return
        self.usage_reset_queue.append(event)

    def discard_usage_resets(self):
        self.usage_reset_queue.clear()
        if self.last_usage_reset.get("state") == "queued":
            self.last_usage_reset["state"] = "skipped"

    @staticmethod
    def valid_pause_minutes(value):
        if type(value) is not int or not 1 <= value <= 1440:
            raise ValueError("暂停时长须为 1–1440 分钟的整数。")
        return value

    def speech_text(self, title, phrase):
        prefix = self.speech.address + "，" if self.speech.address else ""
        return prefix + title + "，" + phrase + "。"

    def configure_speech(self, patch):
        try:
            updated = self.speech.update(patch)
            if updated.voice != self.speech.voice and hasattr(self.speaker, "speech_status"):
                if not any(voice["id"] == updated.voice for voice in self.speaker.speech_status()["voices"]):
                    raise ValueError("所选音色不可用，请刷新后重新选择。")
        except ValueError as error:
            self.settings_error = str(error)
            return False
        if updated.intervals != self.speech.intervals:
            for alert in self.alerts.values():
                if not alert["test"] and alert["count"] and alert["state"] == "pending" and self.rule(alert).intervals is None and not alert.get("manualReplay"):
                    interval = updated.intervals[min(alert["count"] - 1, 2)]
                    alert["nextAt"] = max(self.now(), alert["lastSpokenAt"] + interval)
        self.speech = self.speaker.speech = updated
        self.speaker.playback_error = ""
        self.settings_error = self.preview_error = ""
        return True

    def remember(self, key):
        if key in self.seen:
            return False
        self.seen[key] = self.now()
        while len(self.seen) > 5000:
            self.seen.popitem(last=False)
        return True

    def add(self, event):
        key = str(event.get("id") or uuid.uuid4())
        request = str(event.get("requestId", ""))
        if request and "resolved-request:" + str(event.get("thread", "")) + ":" + request in self.seen:
            return
        if not self.remember(key):
            return
        if not self.enabled:
            return
        kind = event.get("kind", "result")
        if kind not in KINDS:
            return
        created = self.now()
        # A new result supersedes older results for this chat only.
        if kind == "result":
            self.resolve_thread(str(event.get("thread", "")), kinds={"result"}, reason="已有更新结果")
        self.alerts[key] = {"id": key, "thread": str(event.get("thread", "")), "turn": str(event.get("turn", "")), "kind": kind, "title": clean_label(event.get("title")), "detail": str(event.get("detail", KINDS[kind]))[:150], "createdAt": created, "nextAt": created + max(0, float(event.get("delay", 0))), "count": 0, "state": "pending", "test": bool(event.get("test", False)), "requestId": str(event.get("requestId", "")), "source": str(event.get("source", "manual"))}
        if kind == "test" and event.get("outputTarget") in ("computer","passport"):
            self.alerts[key]["outputTarget"] = event["outputTarget"]
        self.alerts[key]["recoveryPending"] = self.alerts[key]["thread"] in self.verifying_threads
        self.history.append({"at": created, "action": "added", "id": key, "kind": kind})

    def resolve(self, key, reason="已处理"):
        alert = self.alerts.get(key)
        if alert:
            self.speaker.stop(key)
            del self.alerts[key]
            self.history.append({"at": self.now(), "action": reason, "id": key})

    def resolve_thread(self, thread, kinds=None, reason="任务已继续", turn=None):
        if not thread:
            return
        for key, alert in list(self.alerts.items()):
            if alert["thread"] == thread and (kinds is None or alert["kind"] in kinds) and (turn is None or not alert["turn"] or alert["turn"] == turn):
                self.resolve(key, reason)

    def event(self, event):
        action = event.get("action", "add")
        if action == "presentation_mode":
            if type(event.get("active")) is not bool:
                return False
            if event["active"] and not self.presentation_active():
                self.interrupt_current()
                self.speaker.stop()
            # A short, renewable lease is runtime-only. It changes no user mute,
            # quiet-hours, output or startup setting, and is never checkpointed.
            self.presentation_until = self.now() + 8 if event["active"] else 0.0
            return True
        if action == "desktop_approval":
            key = event.get("id", "")
            if not isinstance(key, str) or not re.fullmatch(r"desktop-approval:[0-9a-f-]{36}", key) or type(event.get("active")) is not bool:
                return False
            if event["active"]:
                title = clean_label(event.get("title", "应用访问授权"))
                self.add({"id": key, "kind": "approval", "title": "应用授权 · " + title,
                          "detail": "Computer Use 应用访问授权；请在 Codex 中处理，接手只停止提醒。", "source": "desktop-approval", "delay": 3})
            else:
                self.resolve(key, "授权卡片已离开当前界面")
            return True
        if action == "set_passport_settings":
            try:
                self.speaker.configure_passport(event.get("settings"))
                self.passport_error = ""
                return True
            except ValueError as error:
                self.passport_error = str(error); return False
        if action == "set_computer_audio_enabled":
            try:
                self.speaker.configure_computer(event.get("enabled"))
                self.output_error = ""
                return True
            except ValueError as error:
                self.output_error = str(error); return False
        if action == "add":
            self.add(event)
        elif action in ("ack", "resolve"):
            if isinstance(event.get("id"), str):
                self.remember(event["id"])
                self.resolve(event["id"], "已接手" if action == "ack" else "已处理")
        elif action == "resolve_thread":
            self.resolve_thread(event.get("thread"), set(event["kinds"]) if event.get("kinds") else None, event.get("reason", "任务已继续"), event.get("turn"))
        elif action == "resolve_request":
            if event.get("requestId"):
                self.remember("resolved-request:" + str(event.get("thread", "")) + ":" + str(event["requestId"]))
            for key, alert in list(self.alerts.items()):
                if alert["thread"] == event.get("thread") and alert["requestId"] == event.get("requestId"):
                    self.resolve(key)
        elif action == "snooze":
            alert = self.alerts.get(event.get("id"))
            if alert:
                if self.speaker.alert_id == alert["id"]:
                    self.interrupt_current()
                self.speaker.stop(alert["id"])
                alert["nextAt"] = self.now() + max(5, min(3600, float(event.get("seconds", 300))))
                alert["state"] = "snoozed"
                alert["manualReplay"] = True
        elif action == "replay":
            alert = self.alerts.get(event.get("id"))
            if alert and self.enabled:
                self.speaker.stop(alert["id"])
                alert["nextAt"] = self.now()
                alert["state"] = "pending"
                alert["manualReplay"] = True
                alert["recoveryPending"] = False
        elif action == "mute":
            try:
                raw_seconds = event.get("seconds", self.pause_minutes * 60)
                if isinstance(raw_seconds, bool):
                    raise ValueError()
                seconds = float(raw_seconds)
                if not math.isfinite(seconds) or not 0 < seconds <= 86400:
                    raise ValueError()
            except (ValueError, TypeError, OverflowError):
                self.pause_error = "暂停时长须大于 0 且不超过 24 小时。"
                return False
            self.pause_error = ""
            self.muted_until = self.now() + seconds
            self.interrupt_current()
            self.speaker.stop()
            self.discard_usage_resets()
            self.discard_usage_lows()
        elif action in ("set_pause_duration", "pause"):
            try:
                minutes = self.valid_pause_minutes(event.get("minutes"))
                if action == "pause" and not self.enabled:
                    raise ValueError("请先开启提醒，再暂停。")
            except ValueError as error:
                self.pause_error = str(error)
                return False
            self.pause_minutes = minutes
            self.pause_error = ""
            if action == "pause":
                self.muted_until = self.now() + minutes * 60
                self.interrupt_current()
                self.speaker.stop()
                self.discard_usage_resets()
                self.discard_usage_lows()
            return True
        elif action == "unmute":
            self.muted_until = 0
            self.pause_error = ""
        elif action == "ack_all":
            targets = event.get("ids")
            if not isinstance(targets, list) or not all(isinstance(key, str) for key in targets):
                targets = list(self.alerts)
            for key in targets:
                self.remember(key)
                self.resolve(key, "全部已接手")
        elif action == "test":
            key = "test-" + str(uuid.uuid4())
            target = event.get("target") if event.get("target") in ("computer","passport") else None
            title = "AI Passport 播报测试" if target == "passport" else "电脑播报测试" if target == "computer" else "语音提醒测试"
            self.add({"id":key,"thread":key,"kind":"test","title":title,"detail":"测试每隔 5、10、15 秒重复；点“已接手”应立即停止。","test":True,"outputTarget":target})
        elif action == "clear_tests":
            for key, alert in list(self.alerts.items()):
                if alert["test"]:
                    self.resolve(key, "测试已结束")
        elif action == "set_enabled":
            self.enabled = bool(event.get("enabled", True))
            if self.enabled:
                self.muted_until = 0
            if not self.enabled:
                self.speaker.stop()
                self.discard_usage_resets()
                self.discard_usage_lows()
                for key in list(self.alerts):
                    self.resolve(key, "提醒已关闭")
            self.history.append({"at": self.now(), "action": "enabled" if self.enabled else "disabled"})
        elif action == "set_audio_device":
            computer_busy = ComputerSpeaker.busy(self.speaker) if isinstance(self.speaker,Speaker) else self.speaker.busy()
            interrupted = self.speaker.alert_id if computer_busy else None
            retry = not getattr(self.speaker,"last_badge_started",False)
            changed = event.get("device","") != self.speaker.audio_device or event.get("uid","") != self.speaker.audio_device_uid
            if interrupted in self.alerts and changed and retry:
                self.interrupt_current()
            if self.speaker.set_device(event.get("device",""),event.get("uid","")):
                if interrupted in self.alerts and retry: self.alerts[interrupted]["nextAt"] = self.now()
                self.history.append({"at":self.now(),"action":"audio_device_changed","device":self.speaker.audio_device or "跟随系统输出"})
        elif action == "refresh_audio":
            self.speaker.next_device_check = 0
            self.speaker.refresh_audio()
        elif action == "set_speech_settings":
            return self.configure_speech(event.get("settings"))
        elif action == "refresh_voices":
            self.speaker.refresh_voices()
        elif action == "preview":
            self.preview_error = ""
            if self.sleeping or self.quiet_blocks():
                self.preview_error = "演示、休眠或定时免打扰生效，暂不试听。"
            elif not self.enabled or self.now() < self.muted_until:
                self.preview_error = "请先开启并恢复语音提醒，再试听。"
            else:
                self.speaker.stop(PREVIEW_ID)
                if self.speaker.busy():
                    self.preview_error = "正在播报提醒，请结束后再试听。"
                elif self.speaker.speak(PREVIEW_ID, (self.speech.address + "，" if self.speech.address else "") + "这是当前的播报声音。"):
                    self.last_spoken = self.now()
                else:
                    self.preview_error = "暂时无法试听，请检查扬声器和音色。"
        elif action == "stop_preview":
            self.speaker.stop(PREVIEW_ID)
            self.preview_error = ""
        elif action == "set_usage_reset_enabled":
            if type(event.get("enabled")) is not bool:
                self.usage_reset_error = "无法保存重置播报开关，请重试。"
                return False
            self.usage_reset_enabled = event["enabled"]
            self.usage_reset_error = ""
            if not self.usage_reset_enabled:
                self.discard_usage_resets()
                if str(self.speaker.alert_id or "").startswith(USAGE_RESET_ID):
                    self.speaker.stop(self.speaker.alert_id)
            return True
        elif action == "preview_usage_reset":
            self.usage_reset_error = ""
            if self.sleeping or self.quiet_blocks():
                self.usage_reset_error = "演示、休眠或定时免打扰生效，暂不试听。"
            elif not self.enabled or self.now() < self.muted_until:
                self.usage_reset_error = "请先开启并恢复语音提醒，再试听。"
            elif self.speaker.busy():
                self.usage_reset_error = "正在播报提醒，请结束后再试听。"
            elif self.speaker.speak(USAGE_RESET_PREVIEW_ID, self.usage_reset_text({}, preview=True)):
                self.last_spoken = self.now()
            else:
                self.usage_reset_error = "暂时无法试听，请检查扬声器和音色。"
        elif action == "stop_usage_preview":
            self.speaker.stop(USAGE_RESET_PREVIEW_ID)
            self.usage_reset_error = ""
        elif action == "set_usage_low_settings":
            return self.configure_usage_low(event.get("settings"))
        elif action == "preview_usage_low":
            self.usage_low_error = ""
            if self.sleeping or self.quiet_blocks():
                self.usage_low_error = "演示、休眠或定时免打扰生效，暂不试听。"
            elif not self.enabled or self.now() < self.muted_until:
                self.usage_low_error = "请先开启并恢复语音提醒，再试听。"
            elif self.speaker.busy():
                self.usage_low_error = "正在播报提醒，请结束后再试听。"
            elif self.speaker.speak(USAGE_LOW_PREVIEW_ID, self.usage_low_text({}, preview=True)):
                self.last_spoken = self.now()
            else:
                self.usage_low_error = "暂时无法试听，请检查扬声器和音色。"
        elif action == "stop_usage_low_preview":
            self.speaker.stop(USAGE_LOW_PREVIEW_ID)
            self.usage_low_error = ""
        elif action == "set_reminder_rules":
            return self.configure_rules(event.get("rules"))
        elif action == "set_quiet_hours":
            return self.configure_quiet(event.get("settings"))

    def tick(self):
        now = self.now()
        self.sync_quiet()
        if self.pending_usage_low and not -5 <= now - self.pending_usage_low["at"] < 180:
            self.discard_usage_lows()
        while self.usage_reset_queue and now - self.usage_reset_queue[0]["at"] > 120:
            expired = self.usage_reset_queue.popleft()
            if self.last_usage_reset.get("id") == expired["id"]:
                self.last_usage_reset["state"] = "expired"
        if self.presentation_active() or self.sleeping or not self.enabled or now < self.muted_until or self.speaker.busy() or now - self.last_spoken < 1.5:
            return
        due = [a for a in self.alerts.values() if a["nextAt"] <= now and not self.quiet_blocks(a["kind"]) and not a.get("recoveryPending")
               and (a.get("manualReplay") or (self.rule(a).enabled
                    and (self.rule(a).max_plays == 0 or a["count"] < self.rule(a).max_plays)))]
        due.sort(key=lambda a: (0 if a["kind"] in ("approval", "question", "blocked") else 1, a["nextAt"], a["createdAt"]))
        if not due:
            if self.quiet_blocks():
                return
            if self.usage_low_enabled and self.pending_usage_low:
                event = self.pending_usage_low
                if self.play(USAGE_LOW_ID + event["id"], self.usage_low_text(event), "usage-low"):
                    self.pending_usage_low = None
                    self.spoken_usage_lows.extend(w["key"] for w in event["windows"])
                    self.last_spoken = now
                    self.last_usage_low["state"] = "spoken"
                    if self.on_usage_low_spoken(event) is False:
                        self.usage_low_error = "已播报，暂时无法保存去重记录，重启后可能再次提醒。"
                    self.history.append({"at": now, "action": "usage_low_spoken", "id": event["id"]})
                return
            if self.usage_reset_enabled and self.usage_reset_queue:
                event = self.usage_reset_queue[0]
                if self.play(USAGE_RESET_ID + event["id"], self.usage_reset_text(event), "usage-reset"):
                    self.usage_reset_queue.popleft()
                    self.last_spoken = now
                    if self.last_usage_reset.get("id") == event["id"]:
                        self.last_usage_reset["state"] = "spoken"
                    self.history.append({"at": now, "action": "usage_reset_spoken", "id": event["id"]})
            return
        alert = due[0]
        phrase = {"approval": "需要你审批", "question": "有问题需要你回答", "result": "已有结果，请查看", "blocked": "需要你关注", "test": "请点已接手，测试停止播报"}[alert["kind"]]
        text = self.speech_text(alert["title"], phrase)
        if self.play(alert["id"], text, alert["kind"]):
            schedule = (5, 10, 15) if alert["test"] else self.rule(alert).intervals or self.speech.intervals
            alert["nextAt"] = now + schedule[min(alert["count"], len(schedule) - 1)]
            alert["lastSpokenAt"] = now
            alert["count"] += 1
            alert["state"] = "pending"
            alert["manualReplay"] = False
            self.last_spoken = now
            self.history.append({"at": now, "action": "spoken", "id": alert["id"], "count": alert["count"]})

    def snapshot(self):
        audio = self.speaker.audio_status() if hasattr(self.speaker, "audio_status") else {}
        speaking = self.speaker.active_alert_id() if hasattr(self.speaker,"active_alert_id") else self.speaker.alert_id if self.speaker.busy() else None
        speech = self.speech.to_dict()
        speech.update(self.speaker.speech_status() if hasattr(self.speaker, "speech_status") else {"ready": True, "voices": [], "error": ""})
        speech.update(settingsError=self.settings_error, previewError=self.preview_error, previewing=speaking == PREVIEW_ID)
        announcement = {"enabled": self.usage_reset_enabled, "previewing": speaking == USAGE_RESET_PREVIEW_ID, "error": self.usage_reset_error, "lastReset": self.last_usage_reset}
        low_announcement = {"enabled": self.usage_low_enabled, "threshold": self.usage_low_threshold, "previewing": speaking == USAGE_LOW_PREVIEW_ID, "error": self.usage_low_error, "lastWarning": self.last_usage_low}
        alerts = [dict(a, voiceEnabled=self.rule(a).enabled, playLimit=self.rule(a).max_plays,
                       limitReached=bool(self.rule(a).max_plays and a["count"] >= self.rule(a).max_plays)) for a in self.alerts.values()]
        return {"version": VERSION, "at": self.now(), "enabled": self.enabled, "mutedUntil": self.muted_until, "presentation": {"active":self.presentation_active()}, "pause": {"minutes": self.pause_minutes, "error": self.pause_error}, "speakingId": speaking, "audio": audio, "passport": dict(self.speaker.passport_status(),settingsError=self.passport_error) if hasattr(self.speaker,"passport_status") else {}, "outputError":self.output_error, "speech": speech, "usageAnnouncement": announcement, "usageLowAnnouncement": low_announcement, "reminderRules": {k:v.to_dict() for k,v in self.rules.items()}, "rulesError": self.rules_error, "quietHours": dict(self.quiet.to_dict(), active=self.quiet.active(self.now()), error=self.quiet_error), "recovery": self.recovery, "alerts": sorted(alerts, key=lambda a: a["createdAt"], reverse=True), "monitor": self.monitor, "activeTasks": list(self.activity.values())[:12], "history": list(self.history)}


class RolloutAdapter:
    """Compatibility adapter for current local JSONL records; ignores reasoning."""
    def __init__(self, engine, codex_dir):
        self.engine, self.codex_dir = engine, Path(codex_dir)
        self.positions = {}
        self.threads = {}
        self.last_scan = 0
        self.calls = {}
        self.started_at = engine.now()
        self.recovery_floor = None
        self.restore_since = None
        self.recovery_db_ready = False
        self.recovery_live_threads = set()
        self.reconcile_until = 0

    def begin_reconcile(self):
        self.recovery_db_ready = False
        self.last_scan = 0
        self.recovery_floor = max(self.started_at, self.engine.now() - 86400)
        self.reconcile_until = self.engine.now() + 15
        for cursor in self.positions.values():
            self.engine.verifying_threads.add(cursor["thread"])
        for alert in self.engine.alerts.values():
            if alert["thread"] and alert["source"] != "manual":
                alert["recoveryPending"] = True
        self.engine.recovery.update(state="checking", detail="正在同步唤醒后的任务状态")

    def metadata(self, thread):
        item = self.threads.get(thread)
        if item:
            return item
        return {"title": "当前任务", "cwd": ""}

    def title(self, thread):
        return clean_label(self.metadata(thread).get("title"))

    def discover(self):
        now = self.engine.now()
        if now - self.last_scan < 3:
            return
        self.last_scan = now
        try:
            candidates = list(self.codex_dir.glob("state_*.sqlite"))
            db = max(candidates, key=lambda p: p.stat().st_mtime) if candidates else self.codex_dir / "state_5.sqlite"
            connection = sqlite3.connect(db.as_uri() + "?mode=ro", uri=True, timeout=.2)
            columns = {row[1] for row in connection.execute("pragma table_info(threads)")}
            title = "coalesce(name,title)" if {"name", "title"} <= columns else "title" if "title" in columns else "'当前任务'"
            source = "source" if "source" in columns else "''"
            rows = connection.execute(f"select id,rollout_path,{title},cwd,{source} from threads where archived=0 and updated_at>=? order by updated_at desc limit 200", (int(now) - 3 * 86400,)).fetchall()
            pending = {a["thread"] for a in self.engine.alerts.values() if a.get("recoveryPending")}
            checking = list((self.engine.verifying_threads | pending))[:500]
            self.recovery_live_threads = set()
            if checking:
                recovered = connection.execute("select id,archived,rollout_path from threads where id in (" + ",".join("?" for _ in checking) + ")", checking).fetchall()
                found = {row[0] for row in recovered}
                for thread, archived, path in recovered:
                    if archived:
                        self.engine.resolve_thread(thread, reason="聊天已归档")
                        self.engine.verifying_threads.discard(thread)
                    else:
                        self.recovery_live_threads.add(thread)
                        if thread in pending and path and path not in self.positions:
                            file = Path(path)
                            if file.suffix == ".jsonl" and file.is_file():
                                self.positions[path] = {"offset": max(0, file.stat().st_size - 1048576), "thread": thread, "turn": "", "question": False, "since": self.restore_since or self.started_at}
                                self.engine.verifying_threads.add(thread)
                for thread in set(checking) - found:
                    self.engine.resolve_thread(thread, reason="聊天已不可用")
                    self.engine.verifying_threads.discard(thread)
            self.recovery_db_ready = True
            connection.close()
            for thread, path, title, cwd, source in rows:
                if "subagent" in str(source).lower():
                    continue
                self.threads[thread] = {"title": title, "cwd": cwd, "path": path}
                file = Path(path)
                if file.suffix == ".jsonl" and file.is_file() and path not in self.positions:
                    # Never replay old results when the app starts.
                    stat = file.stat()
                    offset = stat.st_size if stat.st_mtime < self.started_at else 0
                    if self.recovery_floor is not None:
                        offset = stat.st_size if stat.st_mtime < self.recovery_floor else max(0, stat.st_size - 1048576)
                    if not offset and getattr(stat, "st_birthtime", self.started_at) < self.started_at:
                        offset = max(0, stat.st_size - 1048576)
                    self.positions[path] = {"offset": offset, "thread": thread, "turn": "", "question": False}
                    if self.recovery_floor is not None:
                        self.positions[path]["since"] = self.recovery_floor
                        self.engine.verifying_threads.add(thread)
                self.recovery_live_threads.add(thread)
            self.engine.monitor.update(state="connected", detail="本地事件记录已连接", files=len(self.positions))
        except (sqlite3.Error, OSError, ValueError):
            self.engine.monitor.update(state="unavailable", detail="本地事件暂不可用；手动确认仍可使用")

    def poll(self):
        self.discover()
        for path, cursor in list(self.positions.items()):
            try:
                file = Path(path)
                if file.stat().st_size < cursor["offset"]:
                    cursor["offset"] = 0
                    cursor["truncated"] = True
                    cursor["since"] = self.engine.now()
                with file.open("rb") as stream:
                    stream.seek(cursor["offset"])
                    for _ in range(500):
                        line = stream.readline()
                        if not line or not line.endswith(b"\n"):
                            break
                        cursor["offset"] = stream.tell()
                        try:
                            record = json.loads(line)
                        except (ValueError, UnicodeError):
                            continue
                        self.record(record, cursor)
                if (self.recovery_db_ready and cursor["thread"] in self.recovery_live_threads
                        and not cursor.get("truncated") and cursor["offset"] >= file.stat().st_size):
                    self.engine.verifying_threads.discard(cursor["thread"])
                    for alert in self.engine.alerts.values():
                        if alert["thread"] == cursor["thread"]:
                            alert["recoveryPending"] = False
            except OSError:
                continue
        pending = sum(bool(a.get("recoveryPending")) for a in self.engine.alerts.values())
        if not self.engine.verifying_threads or self.engine.now() >= self.reconcile_until:
            self.recovery_floor = None
        checking = bool(self.engine.verifying_threads and self.engine.now() < self.reconcile_until)
        self.engine.recovery.update(state="checking" if checking else "partial" if pending else "ready",
                                    unverified=pending, detail="正在核对任务事件" if checking else "部分事项待核验，暂不自动播报" if pending else "事项状态已同步")

    def record(self, record, cursor):
        # An old chat may become active in a different project long after this
        # app started. Its existing history must never be replayed as new work.
        stamp = record.get("timestamp")
        if isinstance(stamp, str):
            try:
                if dt.datetime.fromisoformat(stamp.replace("Z", "+00:00")).timestamp() < cursor.get("since", self.started_at):
                    return
            except ValueError:
                pass
        thread = cursor["thread"]
        payload = record.get("payload") or {}
        kind = record.get("type")
        if kind == "event_msg":
            event = payload.get("type")
            if event in {"task_started", "task_complete", "turn_aborted"}:
                self.engine.monitor["lastEventAt"] = self.engine.now()
            if event == "task_started":
                self.engine.activity[thread] = {"title": self.title(thread), "thread": thread}
                cursor["turn"] = payload.get("turn_id", "")
                cursor["question"] = False
                # Only a real composer turn acknowledges prior reminders.
                trigger = (payload.get("turn_attribution") or {}).get("turn_trigger")
                if trigger == "composer":
                    cursor.pop("truncated", None)
                    self.engine.resolve_thread(thread, reason="你已在此聊天继续操作")
            elif event == "task_complete":
                self.engine.activity.pop(thread, None)
                turn = payload.get("turn_id", cursor["turn"])
                self.engine.resolve_thread(thread, {"approval"}, turn=turn)
                if not cursor["question"]:
                    self.engine.add({"id": "result:" + thread + ":" + turn, "thread": thread, "turn": turn, "title": self.title(thread), "kind": "result", "source": "local-events"})
            elif event == "turn_aborted":
                self.engine.activity.pop(thread, None)
                self.engine.resolve_thread(thread, reason="本轮已取消", turn=cursor["turn"])
            return
        if kind != "response_item":
            return
        if payload.get("type") == "message" and payload.get("role") == "user":
            text = "\n".join(item.get("text", "") for item in payload.get("content", []) if isinstance(item, dict))
            match = re.search(r"<send_user_message_question_reply>\s*(.*?)\s*</send_user_message_question_reply>", text, re.S)
            if match:
                try:
                    for reply in json.loads(match.group(1)):
                        reference = json.loads(reply["questionItemId"])
                        self.engine.event({"action": "resolve_request", "thread": thread, "requestId": reference[1]})
                    cursor["question"] = any(a["thread"] == thread and a["kind"] == "question" for a in self.engine.alerts.values())
                    self.engine.monitor["lastEventAt"] = self.engine.now()
                except (ValueError, KeyError, IndexError, TypeError):
                    pass
            return
        # Structured question calls work for direct tool calls. Code-mode calls
        # are covered by the hook bridge, not by evaluating arbitrary JavaScript.
        if payload.get("type") == "function_call":
            name = str(payload.get("name", ""))
            if "request_user_input" in name:
                call = payload.get("call_id", "")
                self.calls[call] = (thread, cursor["turn"])
                cursor["question"] = True
                self.engine.add({"id": "question:" + thread + ":" + call, "thread": thread, "turn": cursor["turn"], "requestId": call, "title": self.title(thread), "kind": "question", "source": "local-events"})
        elif payload.get("type") == "function_call_output" and payload.get("call_id") in self.calls:
            # Async question tools returning immediately are NOT an answer.
            pass


def handle_hook(raw, engine, adapter):
    name = raw.get("hook_event_name", "")
    thread = str(raw.get("session_id", ""))
    turn = str(raw.get("turn_id", ""))
    request = str(raw.get("tool_use_id", ""))
    tool = str(raw.get("tool_name", ""))
    engine.monitor["hookLastSeen"] = engine.now()
    if name == "PreToolUse" and "request_user_input" in tool:
        engine.add({"id": "question:" + thread + ":" + request, "thread": thread, "turn": turn, "requestId": request, "kind": "question", "title": adapter.title(thread), "source": "hook"})
    elif name == "PostToolUse" and "request_user_input" in tool and "async" not in tool:
        engine.event({"action": "resolve_request", "thread": thread, "requestId": request})
    elif name == "UserPromptSubmit":
        engine.resolve_thread(thread, reason="你已在此聊天回复")
    elif name == "Interrupt":
        engine.resolve_thread(thread, reason="本轮已取消", turn=turn)
    elif name == "PermissionRequest":
        # A permission hook does not prove a human is waiting: auto review can
        # handle it. Enable only on hosts explicitly using the user reviewer.
        if raw.get("voice_reviewer") == "user":
            title = raw.get("project_title") or adapter.title(thread)
            engine.add({"id": "approval:" + thread + ":" + request, "thread": thread, "turn": turn, "requestId": request, "title": title, "kind": "approval", "delay": 1, "source": "hook"})
    elif name == "PostToolUse" and request and "request_user_input" not in tool:
        engine.event({"action": "resolve_request", "thread": thread, "requestId": request})


def atomic_json(path, value):
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(value, ensure_ascii=False), encoding="utf-8")
    os.replace(temporary, path)


def save_preferences(path, settings, engine):
    settings.update(enabled=engine.enabled, audio_device=engine.speaker.audio_device, audio_device_uid=engine.speaker.audio_device_uid, speech=engine.speech.to_dict(), pause_minutes=engine.pause_minutes, usage_reset_announcement=engine.usage_reset_enabled, usage_low_announcement=engine.usage_low_enabled, usage_low_threshold=engine.usage_low_threshold)
    if hasattr(engine.speaker,"passport_settings"):
        settings.update(passport=engine.speaker.passport_settings.to_dict(),computer_audio_enabled=engine.speaker.computer_enabled)
    settings.update(reminder_rules={kind:rule.to_dict() for kind,rule in engine.rules.items()}, quiet_hours=engine.quiet.to_dict())
    atomic_json(path, settings)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--state-dir", required=True)
    parser.add_argument("--codex-dir", default=str(Path.home() / ".codex"))
    parser.add_argument("--usage", action="store_true", help="Read account quotas on a separate worker")
    args = parser.parse_args()
    try:
        os.setsid()
    except OSError:
        pass
    state_dir = Path(args.state_dir)
    inbox = state_dir / "inbox"
    inbox.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(state_dir, 0o700)
    import fcntl
    lock = (state_dir / "engine.lock").open("w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        print(json.dumps({"error": "语音提醒已经在运行"}), flush=True)
        return 1
    try:
        settings = json.loads((state_dir / "settings.json").read_text())
    except (OSError, ValueError):
        settings = {}
    if not isinstance(settings, dict):
        settings = {}
    migrated = migrate_preferences(settings)
    if migrated != settings:
        settings = migrated; atomic_json(state_dir / "settings.json",settings)
    engine = Engine(Speaker(str(settings.get("audio_device", "")), device_uid=str(settings.get("audio_device_uid", "")),
                    passport_emit=lambda event: print(json.dumps({"passportCommand": event}), flush=True)),
                    enabled=bool(settings.get("enabled", True)), speech_settings=settings.get("speech"),
                    pause_minutes=settings.get("pause_minutes", DEFAULT_PAUSE_MINUTES), usage_reset_enabled=settings.get("usage_reset_announcement", True),
                    usage_low_enabled=settings.get("usage_low_announcement", True), usage_low_threshold=settings.get("usage_low_threshold", 20),
                    reminder_rules=settings.get("reminder_rules"), quiet_hours=settings.get("quiet_hours"))
    engine.speaker.configure_passport(settings["passport"])
    engine.speaker.configure_computer(settings["computer_audio_enabled"])
    adapter = RolloutAdapter(engine, args.codex_dir)
    store = RecoveryStore(state_dir / "reminder-state.json")
    store.load(engine, adapter)
    inbox_since = time.time() - 86400 if adapter.restore_since is not None else adapter.started_at
    usage = UsageMonitor(args.codex_dir, low_state_file=state_dir / "usage-low-alerts.json") if args.usage else None
    if usage:
        engine.on_usage_low_spoken = usage.mark_low_announced
        usage.start()
    commands = queue.Queue()
    def prepare_device_state():
        value = engine.snapshot()
        if usage:
            value["usage"] = usage.snapshot()
        print(json.dumps(value, ensure_ascii=False), flush=True)
    engine.before_device_play = prepare_device_state
    signal.signal(signal.SIGTERM, lambda *_: commands.put({"action":"quit"}))
    signal.signal(signal.SIGINT, lambda *_: commands.put({"action":"quit"}))

    def read_commands():
        for line in sys.stdin:
            try:
                command = json.loads(line)
                if isinstance(command, dict):
                    if command.get("action") == "passport_feedback":
                        engine.speaker.passport_feedback(command.get("event"))
                    else:
                        commands.put(command)
            except ValueError:
                pass
        commands.put({"action": "quit"})

    threading.Thread(target=read_commands, daemon=True).start()
    previous = ""
    last_emit = 0
    last_flight = None
    def dispatch(event):
        if event.get("action") == "refresh_usage":
            if usage:
                usage.request_refresh()
            return
        if event.get("action") == "prepare_sleep":
            engine.sleeping = True
            engine.presentation_until = 0.0
            engine.interrupt_current(); engine.speaker.stop()
            store.save(engine, adapter, force=True)
            return
        if event.get("action") == "wake":
            engine.sleeping = False
            engine.interrupt_current(); engine.speaker.stop()
            engine.speaker.next_device_check = 0
            adapter.begin_reconcile()
            if usage:
                usage.request_refresh()
            return
        accepted = engine.event(event)
        if event.get("action") in ("set_enabled", "set_audio_device") or (event.get("action") in ("set_passport_settings", "set_computer_audio_enabled", "set_speech_settings", "set_pause_duration", "pause", "set_usage_reset_enabled", "set_usage_low_settings", "set_reminder_rules", "set_quiet_hours") and accepted):
            save_preferences(state_dir / "settings.json", settings, engine)
        store.save(engine, adapter, force=True)
    try:
        while True:
            while not commands.empty():
                command = commands.get()
                if command.get("action") == "quit":
                    return 0
                dispatch(command)
            entries = []
            for candidate in inbox.glob("*.json"):
                try:
                    entries.append((candidate.stat().st_mtime_ns, candidate.name, candidate))
                except OSError:
                    pass
            for _, _, event_file in sorted(entries)[:100]:
                try:
                    event = json.loads(event_file.read_text())
                    if not isinstance(event, dict):
                        raise ValueError()
                    # Stale spool entries from an old run must not start shouting.
                    panel_action = event_file.name.startswith("panel-") and event.get("action") in ("ack", "ack_all", "resolve", "snooze")
                    if (panel_action or inbox_since <= float(event.get("sentAt", 0)) <= time.time() + 5) and engine.remember("spool:" + event_file.name):
                        if event.get("action") == "hook":
                            if isinstance(event.get("event"), dict):
                                handle_hook(event["event"], engine, adapter)
                        else:
                            dispatch(event)
                        store.save(engine, adapter, force=True)
                    event_file.unlink()
                except (OSError, ValueError, TypeError):
                    try:
                        event_file.unlink()
                    except OSError:
                        pass
            adapter.poll()
            if usage:
                for reset in usage.drain_reset_events():
                    engine.usage_reset(reset)
                engine.update_usage_low(usage.low_warning(engine.usage_low_threshold) if engine.usage_low_enabled else None)
            engine.tick()
            flight = engine.speaker.alert_id if engine.speaker.busy() else None
            store.save(engine, adapter, force=flight != last_flight)
            last_flight = flight
            snapshot = engine.snapshot()
            snapshot["service"] = {"pid": os.getpid(), "processGroup": os.getpgrp(), "sleeping":engine.sleeping, "checkpointError":store.error}
            if usage:
                snapshot["usage"] = usage.snapshot()
            marker = json.dumps({k:v for k,v in snapshot.items() if k != "at"}, ensure_ascii=False)
            if marker != previous or time.time() - last_emit > 2:
                atomic_json(state_dir / "status.json", snapshot)
                print(json.dumps(snapshot, ensure_ascii=False), flush=True)
                previous, last_emit = marker, time.time()
            time.sleep(.2)
    finally:
        store.save(engine, adapter, force=True)
        engine.speaker.stop()
        if usage:
            usage.close()


if __name__ == "__main__":
    raise SystemExit(main())
