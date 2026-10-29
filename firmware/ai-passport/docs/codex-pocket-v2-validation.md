<p align="right"><a href="codex-pocket-v2-validation.zh_CN.md">简体中文</a> · <strong>English</strong></p>

# Codex Pocket implementation and validation — 2026-10-24

**Currently accepted: firmware 0.2.2-pocket + Mac 0.7.0-pocket.4.** The user confirms normal insertion, no automatic panel, and clean ready/completion cues. Earlier build snapshots and pending notes below preserve chronology; the final acceptance is at the end.

Build: PASS  
Host tests: PASS  
Device tests: IN PROGRESS; flash, startup, new UI, BLE and live voice recognition passed; insertion read-back is being diagnosed  
Unverified: physical voice throughput, on-device UI/cues, actual microphone accuracy, cross-app insertion, focus changes, reconnect, heap/stack soak, battery life and range.

## Exact approved and flashed build

- Firmware: 0.2.0-pocket, ESP-IDF 5.5.3, ESP32-C3, 8 MB flash.
- Full-image SHA-256: `27e96e8b21ebf61506605e2161d7f075dfe49336809047a35cc8542b1e54d657`.
- Matching ELF SHA-256: `2cf3edad5962d65effa0a2da60ccc846864fc1303ecf0df24904a5513a5b3b71`.
- Verified merged image (`../build/firmware/27e96e8b21ebf61506605e2161d7f075dfe49336809047a35cc8542b1e54d657/FoloToy-AI-Passport-full.bin`; retained locally; not included in public source): 5,482,000 bytes, flash at 0x0. Application 5,416,464 / 8,323,072 bytes. The retained archive includes the matching ELF, MAP, application, bootloader, partition table and manifest; separate archive verification passed.
- The target chip and 8 MB capacity were rechecked on the locally detected USB serial port before flashing; the machine-specific port label is omitted from this public record. The subsequent announced nine-second startup monitor is closed and is not reopened during pairing or recording.
- The previous 0.1.0-codex archive (`07400e491bff…`) is retained. The user has now explicitly approved and flashed the exact new image above; full write-hash verification passed.
- A merged flash replaces the badge program and may reset NVS / Bluetooth pairing. No full-chip erase or original-firmware readback is planned. Original validated artifacts remain available.
- Mac companion: 0.7.0-pocket.2, a separately named Passport test application, identifier `local.rico.CodexVoice.Passport`, bundle build 21, universal arm64/x86_64. The installed original app and hooks are not replaced.

## Implemented behavior

1. The user's original NOMI is the startup/idle screensaver. Original idle, running, ready, waiting and blocked frames map to known task states. Idle starts after 30 seconds; any short key wakes without acknowledging an alert, and a hold continues directly into dictation.
2. The quota home uses a large number, remaining-value ring, actual period, reset countdown and freshness. UP/DOWN changes returned periods; the tightest valid window is the default. Unknown/stale/reset data never becomes a fake zero or full ring.
3. One task card displays kind, sanitized title, next step and queue position. UP/DOWN selects; short OK acknowledges the ID captured on key-down and opens a validated UUID Codex thread. Approval decisions remain in Codex. Long UP opens the existing reminder operations.
4. Hold OK prepares capture and the Mac session. A 100 ms single tone permits speech only after both ends are ready. Release ends recording; a matching result is successful only after final text is written and read back. Success uses ascending two-note audio. Failure/retention uses a low attention cue. No spoken dictation prompts or automatic Return.
5. The badge sends bounded IMA-ADPCM packets; the Mac verifies ID, sequence, totals and final completeness, then uses the already installed Chinese SpeechAnalyzer model. Input target/draft/selection changes retain text for manual copying. Ambiguous insertion is not retried. Retained text lives in process memory, not across quit. Audio is not stored or uploaded.

## Evidence

- Complete repository gate `./tools/validate.sh`: PASS, plus content-addressed archive verification.
- Real UI rendered with LVGL 9.5 using the same C implementation, fonts, sprite bytes, 240×320 resolution, 40-row draw buffer and rounded display mask. Contact sheet (`../build/pocket-ui/actual-firmware-ui.png`; retained locally; not included in public source). Preview quota values are illustrative. Widget pool usage was 19,616 / 28,312 usable bytes; this is host layout evidence, not a device heap measurement.
- Python: 169 unit tests PASS. Native protocol tests cover lowercase epoch, minimized metadata, fresh quota windows and unknown/reset handling. Native audio tests cover fragmentation, bounds, missing/duplicate blocks and UTF-16 draft selection.
- Firmware C encoded a 204-frame existing speech fixture. Swift decoding matches C PCM byte for byte. The synthetic codec-quality test exceeds 18 dB SNR.
- On this Mac, local transcription of the 4.08-second decoded fixture prepared in approximately 0.10 s and recognized in 0.13 s on the observed warm run. The result includes a homophone for the Chinese badge noun; this is one fixed synthetic speech sample, not an accuracy or latency guarantee. This host fixture test did not capture a microphone; subsequent live user recordings verified the uplink and recognition.
- Final packaged-app verification passed relocation, deep signature, both architectures, embedded Python 3.14.8, isolated hook handling, unchanged trust and existing settings persistence. Packaged-engine tests use simulated radio acknowledgements; physical BLE is explicitly NOT RUN.
- The user explicitly authorized Accessibility for the temporary app, and the current signature has been registered through System Settings. The local SpeechAnalyzer path does not request server-recognition or Mac microphone permission. [Apple guidance](https://developer.apple.com/documentation/speech/asking-permission-to-use-speech-recognition).

## Next acceptance step

After explicit approval for the exact image above: verify the physical target, flash from 0x0, confirm boot identity and UI, reconnect/pair, guide Accessibility setup, then test hold/single cue/speech/release/text/no-send/two-note confirmation, retained drafts, notification interruption and reconnection. Do not label the feature hardware-accepted before these checks.

No commit, push, publication, model download, automatic message send or global Codex configuration change was performed.

## Physical debugging checkpoint

The user explicitly approved this exact build and temporary Mac debugging. Chip identity and 8 MB capacity matched; writing 5,482,000 bytes passed the esptool hash check. The announced bounded serial startup check is closed: version 0.2.0-pocket, boot ELF prefix 2cf3edad5 matches the archive; audio, keys, battery and BLE initialized, boot free heap 89,956 bytes. The user confirms the new UI renders.

The Mac pairing record was rebuilt and runtime status confirms the badge is connected. The user has performed a real hold-to-talk recording; recognized speech is visible in the retained-text window. Input read-back was not confirmed, and no automatic retry occurred. The original field result is being checked before changing input adaptation. End-to-end dictation acceptance is still pending.

## Mac insertion compatibility repair

The user screenshot and observation confirmed that 0.7.0-pocket.1 retained recognized text without inserting it. Version 0.7.0-pocket.2 uses one normal Paste operation, snapshots all readable pasteboard formats, marks temporary contents current-host-only, and restores only if the user has not copied something newer. Target/draft/selection checks and read-back success are retained; no automatic duplicate retry. Diagnostics contain stage, lengths and permission state, never draft/transcript text. Private-pasteboard tests pass formats, restoration, size bounds and newer-copy protection.

The rebuilt app passes signature/relocation and simulated-engine regression. The old TCC entry did not match the new signature. The user explicitly authorized removal/re-addition of this same application; after registration through System Settings, the in-app model and Accessibility checks pass. Other permissions are unchanged. Automation did not acquire a real foreground input target in the test document and did not write text; the user is now asked to click the Codex composer manually for live insertion/cue retest. The firmware remains the approved 27e96e8b21eb… build and has not been reflashed.

## 2026-10-25: false success-negative, panels and cues

The user confirms real insertion, but an automatic retained-text panel still appeared and neither cue was audible. Diagnostics show original length 1, expected 17, observed 16; the old comparison only allowed a newly appended terminal newline, not removal of a rich-text empty paragraph placeholder. Version 0.7.0-pocket.3 compares logical paragraph/placeholder boundaries while preserving body text, spaces and internal line breaks; regression cases reject lost real drafts and different same-length text. Dictation failures/retention no longer open a window or steal focus; drafts are opened explicitly in Settings.

Firmware 0.2.1-pocket aligns cues to 240-sample DMA blocks, primes/drains with 120 ms silence, and uses a 120 ms ready note and 90+30+90 ms completion notes. Cue-only volume is 70 with PCM peak 10000 (previously 45 / 5200). The false insertion-negative also prevented the completion path. BLE cue acknowledgements prove playback data was submitted, not physical audibility.

Full firmware gate, independent archive verification, waveform energy/envelope/alignment, native placeholder regression, 169 Python tests, Mac package/signature/relocation, simulated radio and private-pasteboard checks pass. Full image SHA-256: `ab8c8a5afbff77f2812e6c2504a4b8e51f7ed825581ef3b95a3696be39950697`; matching ELF: `c4c24de41fa84ba100c31282bda938979a019e23aabbaaecabc0363fede10be2`. The badge still runs the previous 27e96e8b21eb… build; the fix is not yet flashed. Archived partition tables match. After approval, compare the physical table before segmented flashing of the exact archived bootloader/table/application, retaining NVS/PHY without a full-chip erase. The new Mac signature needs input permission registration. Physical quiet insertion and both cues remain acceptance checks.

## 2026-10-25: clean cues and final-payload acknowledgement

The user confirms no automatic panel and audible but rough/popping sound on 0.2.1. One Mac 0.7.0-pocket.3 result had original/expected/observed lengths 13/22/9, and the cue branch was attention, not complete. Version 0.7.0-pocket.4 retains pre-paste target protection and also accepts an exact final payload in that same field, provided it was not already identical before pasting. Equal lengths or unrelated substrings never count as proof.

Firmware 0.2.2 replaces per-sample floating-point trig with interpolated Q15 and zero-slope envelopes at cue volume 65. DAC mute covers recreation/clocks, pre-roll and drain. The audio path stays muted/ready while paired; RX is enabled only for effective recording and paused at release, so waiting for transcription does not cycle codec power. Disconnect mutes and sleeps. RX gating uses the public data interface to keep enabled flags synchronized; close skips a known already-paused input instead of reporting a false I2S failure.

Acoustic quality remains a physical check; the suspected causes are not presented as uniquely measured. The complete gate, mute/pre-roll/drain/failure ordering, RX-pause/TX-clock/closed-muted-reopen/I2C-recovery tests pass. Steady waveform SNR against the ideal sine exceeds 55 dB with no runtime trig. Mac package, 169 Python checks, native input and private-pasteboard regressions pass. Full SHA: `a69103cbf1dc7a013f3cdc6fc757de97f5c310e4567774f4b3300d02e51118d4`; ELF: `bbd8ee81147db28b32a548540bf09d95212e08127eb8802f2334314bd8b770d8`. This build is not yet approved or flashed. Paired-standby power and battery runtime remain unmeasured.

The user explicitly approved 0.2.2 (a69103cbf1dc…) and Mac 0.7.0-pocket.4. Device identity, 8 MB and the physical partition table match; all three segmented images passed write-hash checks, excluding NVS/PHY. Boot reports 0.2.2-pocket and ELF prefix bbd8ee811, matching the archive; audio/keys/battery/BLE initialize, free boot heap 89,924 bytes. Serial observation is closed. System Settings is currently awaiting user Touch ID/password verification; Mac permission registration and acoustic acceptance are pending.

## Physical acceptance: 0.2.2 / Mac 0.7.0-pocket.4

The user completed system authentication and the exact test app was registered. In-app checks confirm Accessibility and the installed Chinese model. The original 0.6.0-beta.2 was found owning the shared runtime; it was quit normally through its UI before launching the separate test app. Final status confirms connected 0.7.0-pocket.4 with no error; the installed original and other app permissions remain unchanged.

The user explicitly confirms everything works with clean effects. Live insertion reports inserted=true using exactFinalText; the complete observed target has 33 characters versus stale AX original/constructed lengths 13/46, so rich-text snapshot differences no longer produce a false negative. The badge reports kind=complete, ok=true, volume=65, maximum producer gap 1,422 microseconds. This is feed timing, not an acoustic distortion or battery measurement. Panel metadata is visible=false. No transcript content or audio was retained in the acceptance record.

Build: PASS. Host tests: PASS. Device tests: PASS for direct insertion, no automatic panel and clean ready/completion cues. Unverified: paired-standby power, battery/runtime, range, long soak; the complete physical reminder-menu/chat-navigation matrix was not repeated in this sound fix. The test app remains running, the installed original is preserved, and no commit, push or release was performed.

## 2026-10-25: login startup and stable installation

The user explicitly requested automatic login startup and reconnection after reboot. The accepted 0.7.0-pocket.4 app was copied unchanged to the personal Applications directory; the main binary hash matches and deep signature verification passes. No rebuild or binary edit was required. The user LaunchAgent at ~/Library/LaunchAgents/local.rico.CodexVoice.login.plist uses RunAtLoad, Aqua and --background, associated with local.rico.CodexVoice.Passport. No prior plist/job existed. The label stays compatible with the built-in startup toggle.

After the source instance quit normally, launchd started the stable executable with parent PID 1 and running state. The fresh 0.7.0-pocket.4 engine automatically reconnected to the badge without pairing. Initial/final panels are hidden; the in-app login toggle is on and Accessibility remains allowed. See the machine setup/validation record (`../../codex-voice/.build/passport-login-validation.json`; retained locally; not included in public source). No actual reboot or logout was performed; the verified scope is real launchd background startup and automatic reconnection.
