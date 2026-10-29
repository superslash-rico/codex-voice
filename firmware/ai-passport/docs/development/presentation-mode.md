<p align="right"><a href="presentation-mode.zh_CN.md">简体中文</a> · <strong>English</strong></p>

# Codex Companion Presentation Mode

Firmware `0.4.0-presenter` adds presentation controls over the existing encrypted companion GATT connection. It needs the matching Mac application; this is not a standalone HID keyboard. Host tests and builds do not establish on-device acceptance.

Hold DOWN for 1500 ms to request entering or leaving presentation mode. The BSP's 500 ms LONG callback only suppresses the subsequent click; the application polls the actual held state to trigger once at 1500 ms. The event callback only updates atomics and enqueues key events.

In presentation mode UP/DOWN request previous/next. The first click after dimming also pages. New alerts update the pending count without changing key roles or replacing the presentation page. OK does not acknowledge/open a task; dictation is suspended. Long UP still opens the local menu, where UP/DOWN remain local navigation. Leave presentation mode before using reminder menu actions.

The Mac exposes ready, focus paused, permission missing and preparing states. It waits for the speech engine's silence acknowledgement before reporting ready. It checks foreground application identity again immediately before posting a full left/right key pair. The first implementation recognizes PowerPoint, Keynote and the main WPS Mac bundle, with optional fixed target selection. The user starts playback and focuses the slide show. Neither slide contents, playback state nor page numbers are read.

## Protocol extension

- Device `hello`: `presenter: true`, `presenterSession`: a random 16-character hex boot identity.
- Host `state`: `presenterSupported`, `presenter`, `presenterReady`, `presenterStatus` (0 ready, 1 focus, 2 permissions, 3 preparing), `presenterTarget` (0 auto, 1 PowerPoint, 2 Keynote, 3 WPS), `presenterLease` (16-character hex).
- Device request: `v:1`, `type:"presenter"`, matching `epoch`, `session`, `lease`, positive increasing `seq` bounded by INT32_MAX, and `op` in `enable`, `disable`, `previous`, `next`.

The host issues short-lived leases with each state. It rejects requests older than 2.5 seconds, duplicates, old epochs/boots, unsupported operations, wrong focus, missing permissions or an unacknowledged silence request. Blocked valid sequence numbers are consumed, not saved for retry. The firmware refuses to send against stale state. No key request is resent or stored for reconnect. The host does not reset deduplication on repeated HELLO for the same boot. Disconnect, host restart and sleep clear the manual mode; reconnect does not restore it.

Both firmware and host reject reminder playback during presentation mode. The Mac temporarily suppresses automatic reminder panels and keeps pending tasks. Its speech engine uses a renewable eight-second runtime lease, preserving all existing preferences and counters. Silence ends if the owner stops renewing. None of these messages approves a Codex request.

The LVGL presentation page uses a dark stage-friendly palette, large vertical previous/next controls, a primary blue next control, a status indicator and a private pending-count summary. Rounded control zones and chevrons are drawn directly, sharing labels with the mutually exclusive task page to retain the existing 32 KiB LVGL configuration. It is independent of demo/test UI and retains the battery header. Validate new fixed Chinese strings against the generated fonts. Retain the existing partition map, bonding, nickname and pet assets during an explicitly approved segmented update.
