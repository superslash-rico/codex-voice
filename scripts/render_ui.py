#!/usr/bin/env python3
"""Render real SwiftUI views with isolated demo state; no engine, BLE or installed app."""
from pathlib import Path
import argparse
import json
import plistlib
import shutil
import subprocess
import tempfile

ROOT=Path(__file__).resolve().parents[1]
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--pet-preview',type=Path,help='Explicit optional image; default uses bundled demo artwork only')
args=parser.parse_args()
build=ROOT/'.build';build.mkdir(exist_ok=True)
output=build/'ui-design';output.mkdir(exist_ok=True)
sources=['VoicePanel.swift','SpeechSettingsView.swift','PanelChrome.swift','UsageView.swift','UsageGauge.swift','SubscriptionLinkView.swift','ReminderSettingsView.swift','PassportProtocol.swift','PassportPresenter.swift','PassportSettingsView.swift','AppPaths.swift']
with tempfile.TemporaryDirectory(prefix='ui-render-',dir=build) as temporary:
    root=Path(temporary);app=root/'InterfaceRenderer.app';resources=app/'Contents/Resources';binary=app/'Contents/MacOS/InterfaceRenderer'
    resources.mkdir(parents=True);binary.parent.mkdir()
    (app/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'local.rico.CodexVoice.InterfaceRenderer','CFBundleExecutable':'InterfaceRenderer','CFBundlePackageType':'APPL','LSUIElement':True}))
    shutil.copy2(ROOT/'assets/passport/ai-passport-front.png',resources/'AIPassport.png')
    shutil.copy2(ROOT/'assets/passport/nomi-idle.png',resources/'PetNOMI.png')
    state=root/'state';(state/'pet-cache').mkdir(parents=True)
    if args.pet_preview is not None:
        shutil.copy2(args.pet_preview.resolve(strict=True),state/'pet-cache/preview.png')
    command=['/usr/bin/xcrun','swiftc','-O','-module-cache-path',str(build/'swift-cache'),'-target','arm64-apple-macos13.0',*[str(ROOT/'src'/name) for name in sources],str(ROOT/'scripts/render_ui.swift'),'-framework','AppKit','-framework','SwiftUI','-framework','CryptoKit','-framework','ApplicationServices','-o',str(binary)]
    subprocess.run(command,check=True,cwd=ROOT)
    subprocess.run([str(binary),'--state-dir',str(state),'--output',str(output)],check=True,cwd=ROOT)
print(output)
