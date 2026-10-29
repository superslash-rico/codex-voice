<p align="right"><a href="README.zh_CN.md">简体中文</a> · <strong>English</strong></p>

# AI Passport for Codex Voice

This is the complete source snapshot for the optional FoloToy AI Passport accessory in [Codex Voice](../../README.md), not the upstream demonstration firmware. Current source firmware: **0.4.0-presenter**, matching Mac source **0.10.0-presenter.1**. The published package remains Mac **0.9.2-approval.1** with firmware **0.3.0-pets**, which does not include presentation controls.

Use the [step-by-step accessory guide](../../docs/AI_PASSPORT.md) for download, flashing, pairing, buttons, local dictation and troubleshooting. The root project guide is currently in Simplified Chinese; the engineering documents in this directory are paired in English and Chinese.

## Hardware and behavior

Target: FoloToy AI Passport, ESP32-C3, **8 MB Flash, no PSRAM**, its onboard display, microphone, speaker and three buttons. Task cards, quota rings, pet screensaver, acknowledgement buttons and encrypted BLE services are implemented specifically for Codex Voice. This is not firmware for arbitrary ESP32 boards.

The Mac app independently controls computer and badge speech. It synchronizes the selected Codex pet in the background and only activates verified resources. Local Mandarin dictation requires macOS 26 or later and an installed on-device model; transcription stays on the Mac and does not send messages automatically. The Mac app applies the default nickname `Codex` on first connection and preserves an existing saved nickname when upgraded.

## Presentation remote

Hold DOWN for about 1.5 seconds to enter or leave presentation mode; short UP/DOWN presses send previous/next steps to the foreground presentation application. The Mac settings provide the same mode switch and automatic or fixed application selection. Start the slide show and keep its window focused before using the badge.

The dark remote screen emphasizes the next control in blue, dims controls when paused and shows only a pending reminder count. New tasks remain pending while both speech outputs and automatic reminder panels are deferred. Dictation and task-opening actions resume after leaving the mode. The first key after dimming can also page. No delayed key is replayed after reconnect.

PowerPoint and Keynote were confirmed on the development Mac on 2026-10-29, including paging, first dimmed key, exit and subsequent dictation/cues. WPS recognition is implemented but not physically tested; complex animations and an external projector still need dedicated acceptance. See [presentation controls and protocol](docs/development/presentation-mode.md).

## Build

Read [AGENTS.md](AGENTS.md), activate **ESP-IDF 5.5.3**, and install the prerequisites documented in [environment setup](docs/development/engineering/environment-setup.md).

```sh
source /path/to/esp-idf-v5.5.3/export.sh
idf.py --version
./tools/validate.sh
```

The complete gate runs repository checks, host tests, an isolated firmware build and merged-image verification. It produces `build/FoloToy-AI-Passport-full.bin` and a matching content-addressed archive under `build/firmware/`. It does not flash USB hardware. `idf.py build` alone is not a merged-image delivery check.

Flash the validated `build/FoloToy-AI-Passport-full.bin` at **offset `0x0`** for a complete refresh. The older published `AI-Passport-Codex-0.3.0-pets-full.bin` has no presentation feature. Never flash the application-only image there. A complete merged flash can reset NVS and pairing; segmented upgrades require a verified compatible partition layout. Do not routinely erase the entire chip. See [firmware layout and stored data](docs/development/engineering/firmware-layout.md).

This variant uses factory application `0x10000` / `0x5F0000` and a two-MiB `pet_assets` partition at `0x600000`, with two validated resource slots. NVS and PHY remain at `0x9000` and `0xF000`.

## Source provenance and licenses

The base is [FoloToy/ai-passport](https://github.com/FoloToy/ai-passport) commit `006c2279852e352a8433b2c21e5e09be2ca36f77`. [provenance.json](provenance.json) records the imported source snapshot and modification areas. This directory is included directly, so cloning Codex Voice does not require submodule setup.

Changes add a separate Codex UI, task/quota controls, authenticated BLE control/audio/image channels, clean dictation cues, pet A/B storage, Chinese resources, audio recovery, battery behavior, presentation gestures/state/remote UI and host tests. Build caches, generated device logs, personal settings, bonding data and matching local debug symbols are excluded.

Retain [LICENSE](LICENSE) for the upstream MIT code and the [font license](assets/fonts/NotoSansSC-OFL.txt). Custom pet artwork is separate from the FoloToy license and does not grant rights to third-party characters or OpenAI marks. The material source descriptions remain in [assets](assets/README.md). Historical design/validation notes under `docs/codex-*` describe their recorded development stage; use the root project guide and current release verification for current installation instructions.
