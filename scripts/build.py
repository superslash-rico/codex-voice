#!/usr/bin/env python3
"""Build a relocatable universal2 macOS app without installing Python system-wide."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import platform
import shutil
import subprocess
import urllib.request

ROOT = Path(__file__).resolve().parent.parent
PYTHON = json.loads((ROOT/"scripts/python-runtime.json").read_text())
VERSION = (ROOT/"VERSION").read_text().strip()
MACHO = {bytes.fromhex(v) for v in ["cffaedfe","feedfacf","cefaedfe","feedface","cafebabe","bebafeca","cafebabf","bfbafeca"]}


def run(*args, capture=False):
    result = subprocess.run([str(arg) for arg in args], capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(Path(str(args[0])).name+" failed:\n"+result.stdout[-4000:]+result.stderr[-12000:])
    if not capture:
        if result.stdout: print(result.stdout, end="", flush=True)
        if result.stderr and str(args[0]) not in ["/usr/bin/install_name_tool", "/usr/bin/codesign"]: print(result.stderr, end="", flush=True)
    return result.stdout if capture else ""


def is_macho(path):
    if path.is_symlink() or not path.is_file() or path.suffix == ".a":
        return False
    with path.open("rb") as stream:
        return stream.read(4) in MACHO


def acquire_runtime(cache):
    cache.mkdir(parents=True, exist_ok=True)
    package = cache/("python-"+PYTHON["version"]+".pkg")
    if not package.exists() or hashlib.sha256(package.read_bytes()).hexdigest() != PYTHON["sha256"]:
        temporary = package.with_suffix(".part")
        with urllib.request.urlopen(PYTHON["url"], timeout=60) as source, temporary.open("wb") as output:
            shutil.copyfileobj(source, output)
        if hashlib.sha256(temporary.read_bytes()).hexdigest() != PYTHON["sha256"]:
            raise RuntimeError("Python runtime checksum does not match python.org")
        temporary.replace(package)
    expanded = cache/("python-"+PYTHON["version"]+"-expanded")
    if not expanded.exists():
        run("/usr/sbin/pkgutil", "--expand-full", package, expanded)
    return expanded


def embed_runtime(expanded, framework):
    payload = expanded/"Python_Framework.pkg/Payload"
    shutil.copytree(payload, framework, symlinks=True)
    version = framework/"Versions"/PYTHON["framework_version"]
    stdlib = version/"lib"/("python"+PYTHON["framework_version"])
    # These tools, tests and installer support are not used by the app.
    for path in [version/"share", version/"include", version/"Frameworks", stdlib/"test", stdlib/"idlelib", stdlib/"turtledemo", stdlib/"ensurepip", stdlib/"site-packages", stdlib/"tkinter"]:
        if path.is_symlink(): path.unlink()
        elif path.is_dir(): shutil.rmtree(path)
    for path in list(framework.rglob("__pycache__")):
        shutil.rmtree(path)
    for path in stdlib.glob("lib-dynload/_tkinter*.so"):
        path.unlink()
    for path in list(framework.rglob("*")):
        if path.is_symlink() and (not path.exists() or not path.resolve().is_relative_to(framework.resolve())):
            path.unlink()
    prefix = "/Library/Frameworks/Python.framework/"
    binaries = [path for path in framework.rglob("*") if is_macho(path)]
    for binary in binaries:
        dependencies = set()
        for line in run("/usr/bin/otool", "-L", binary, capture=True).splitlines():
            if line.startswith("\t"):
                dependencies.add(line.strip().split(" (", 1)[0])
        for dependency in dependencies:
            if dependency.startswith(prefix):
                target = framework/dependency.removeprefix(prefix)
                relative = os.path.relpath(target, binary.parent)
                run("/usr/bin/install_name_tool", "-change", dependency, "@loader_path/"+relative, binary)
            elif dependency.startswith("/") and not dependency.startswith(("/System/Library/", "/usr/lib/")):
                raise RuntimeError("Unexpected external dependency: "+dependency)
        loads = run("/usr/bin/otool", "-l", binary, capture=True)
        if "LC_ID_DYLIB" in loads:
            run("/usr/bin/install_name_tool", "-id", "@rpath/Python.framework/"+str(binary.relative_to(framework)), binary)
    # Preserve CPython and bundled-library notices in the distributed application.
    notices = framework.parent.parent/"Resources/ThirdPartyLicenses"
    notices.mkdir(parents=True, exist_ok=True)
    shutil.copy2(stdlib/"LICENSE.txt", notices/"Python-LICENSE.txt")
    shutil.copy2(expanded/"Resources/License.rtf", notices/"Python-distribution-License.rtf")
    return binaries


def compile_universal(build, target, sources, frameworks):
    slices = []
    for arch in ["arm64", "x86_64"]:
        output = build/(target.name+"-"+arch)
        run("/usr/bin/xcrun", "swiftc", "-O", "-debug-prefix-map", str(ROOT)+"=/CodexVoice", "-file-prefix-map", str(ROOT)+"=/CodexVoice", "-module-cache-path", build/"swift-cache", "-target", arch+"-apple-macos13.0", *sources, "-o", output, *sum((["-framework", name] for name in frameworks), []))
        slices.append(output)
    run("/usr/bin/lipo", "-create", *slices, "-output", target)


def package_app(build, app):
    dist = ROOT/"dist";dist.mkdir(exist_ok=True)
    staging = build/"dmg"
    if staging.exists(): shutil.rmtree(staging)
    staging.mkdir();shutil.copytree(app, staging/app.name, symlinks=True)
    (staging/"Applications").symlink_to("/Applications")
    shutil.copy2(ROOT/"docs/INSTALL.txt", staging/"安装与使用说明.txt")
    archive = dist/("CodexVoice-"+VERSION+"-universal.zip")
    if archive.exists(): archive.unlink()
    run("/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", app, archive)
    image = dist/("CodexVoice-"+VERSION+"-universal.dmg")
    run("/usr/bin/hdiutil", "create", "-volname", "Codex 语音提醒", "-srcfolder", staging, "-ov", "-format", "UDZO", image)
    assets = [archive, image]
    (dist/"SHA256SUMS.txt").write_text("".join(hashlib.sha256(path.read_bytes()).hexdigest()+"  "+path.name+"\n" for path in assets))
    print("Packaged "+str(dist), flush=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--cache", type=Path, default=ROOT/".build-cache")
    parser.add_argument("--identity", default="-")
    parser.add_argument("--package", action="store_true")
    parser.add_argument("--package-only", action="store_true", help="Package an existing verified build with current documentation")
    parser.add_argument("--passport-test", action="store_true", help="Build a separately identified temporary Passport app")
    args = parser.parse_args()
    build = ROOT/".build";build.mkdir(exist_ok=True)
    app = build/("Codex 工牌联调.app" if args.passport_test else "Codex 语音提醒.app")
    if args.package_only:
        info = plistlib.loads((app/"Contents/Info.plist").read_bytes())
        if info.get("CodexVoiceVersion") != VERSION:
            raise RuntimeError("Existing build version does not match VERSION; rebuild first")
        run("/usr/bin/codesign", "--verify", "--deep", "--strict", app)
        package_app(build, app)
        return
    if app.exists(): shutil.rmtree(app)
    resources = app/"Contents/Resources";resources.mkdir(parents=True)
    (app/"Contents/MacOS").mkdir()
    (app/"Contents/Frameworks").mkdir()
    info = {"CFBundleDisplayName":"Codex 语音提醒", "CFBundleName":"CodexVoice", "CFBundleExecutable":"CodexVoice", "CFBundleIdentifier":"local.rico.CodexVoice", "CFBundlePackageType":"APPL", "CFBundleShortVersionString":VERSION.split("-")[0], "CFBundleVersion":"38", "CodexVoiceVersion":VERSION, "LSMinimumSystemVersion":"13.0", "LSUIElement":True, "NSHighResolutionCapable":True, "CFBundleIconFile":"AppIcon.icns"}
    if args.passport_test:
        info.update(CFBundleDisplayName="Codex 工牌联调", CFBundleName="CodexPassport",
                    CFBundleIdentifier="local.rico.CodexVoice.Passport", CFBundleVersion="30")
    (app/"Contents/Info.plist").write_bytes(plistlib.dumps(info))
    info["NSBluetoothAlwaysUsageDescription"] = "连接你的 AI Passport 工牌，同步任务状态、播放提醒并接收按键操作。"
    (app/"Contents/Info.plist").write_bytes(plistlib.dumps(info))
    for name in ["voice_engine.py", "passport_output.py", "accessory_settings.py", "pet_source.py", "speech_settings.py", "codex_usage.py", "reminder_rules.py", "reminder_recovery.py", "voice_bridge.py", "hook_setup.py", "runtime_info.py"]:
        shutil.copy2(ROOT/"src"/name, resources/name)
    shutil.copy2(ROOT/"assets/passport/ai-passport-front.png",resources/"AIPassport.png")
    shutil.copy2(ROOT/"assets/passport/nomi-idle.png",resources/"PetNOMI.png")
    compile_universal(build, app/"Contents/MacOS/CodexVoice", [ROOT/"src"/name for name in ["VoiceApp.swift","AppPaths.swift","VoiceAppRuntime.swift","VoicePanel.swift","SpeechSettingsView.swift","PanelChrome.swift","UsageView.swift","UsageGauge.swift","SubscriptionLinkView.swift","ReminderSettingsView.swift","ServiceRecovery.swift","ComputerUseApproval.swift","PassportProtocol.swift","PassportLink.swift","PassportAudio.swift","PassportSpeech.swift","PassportDictation.swift","PassportInput.swift","PassportSettingsView.swift","PassportPetAsset.swift","PassportPetSync.swift"]], ["AppKit","SwiftUI","CoreBluetooth","CryptoKit","Speech","AVFoundation","ApplicationServices","ImageIO"])
    compile_universal(build, resources/"AudioDeviceInfo", [ROOT/"src/AudioDeviceInfo.swift"], ["CoreAudio"])
    expanded = acquire_runtime(args.cache.resolve())
    binaries = embed_runtime(expanded, app/"Contents/Frameworks/Python.framework")
    shutil.copy2(ROOT/"assets/passport/FoloToy-LICENSE.txt",resources/"ThirdPartyLicenses/FoloToy-LICENSE.txt")
    iconset = build/"AppIcon.iconset"
    run("/usr/bin/xcrun", "swiftc", "-module-cache-path", build/"swift-cache", "-target", platform.machine()+"-apple-macos13.0", ROOT/"scripts/IconGenerator.swift", "-o", build/"IconGenerator", "-framework", "AppKit")
    run(build/"IconGenerator", iconset)
    run("/usr/bin/iconutil", "-c", "icns", iconset, "-o", resources/"AppIcon.icns")
    for binary in binaries + [resources/"AudioDeviceInfo", app/"Contents/MacOS/CodexVoice"]:
        run("/usr/bin/codesign", "--force", "--sign", args.identity, binary)
    nested_bundles = list((app/"Contents/Frameworks").rglob("*.app")) + list((app/"Contents/Frameworks").rglob("*.framework"))
    for nested in sorted(nested_bundles, key=lambda p: len(p.parts), reverse=True):
        run("/usr/bin/codesign", "--force", "--sign", args.identity, nested)
    run("/usr/bin/codesign", "--force", "--sign", args.identity, app)
    run("/usr/bin/codesign", "--verify", "--deep", "--strict", app)
    print("Built "+str(app), flush=True)
    if args.package:
        package_app(build, app)



if __name__ == "__main__":main()
