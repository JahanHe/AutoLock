#!/bin/sh
# 用 Command Line Tools 编译 Apple 芯片版；仅复用同版源码已编译的界面和图标资源。
set -eu
if [ "$#" -lt 2 ]; then
  echo "用法：scripts/build_local.sh /绝对路径/资源模板.app /绝对路径/AutoLock.app [签名证书或 -]" >&2
  exit 2
fi
cd "$(dirname "$0")/.."
seed_app=$1
output_app=$2
signing_identity=${3:--}
test -d "$seed_app/Contents/Resources"
test ! -e "$output_app" || { echo "输出已存在，请选择新的路径。" >&2; exit 1; }
build_temp=$(mktemp -d)
trap 'rm -rf "$build_temp"' EXIT
mkdir -p "$output_app/Contents/MacOS" "$output_app/Contents/Library/LoginItems/AutoLockLauncher.app/Contents/MacOS"
ditto "$seed_app/Contents/Resources" "$output_app/Contents/Resources"
launcher_app="$output_app/Contents/Library/LoginItems/AutoLockLauncher.app"
ditto "$seed_app/Contents/Library/LoginItems/AutoLockLauncher.app/Contents/Resources" "$launcher_app/Contents/Resources"
xcrun clang -O2 -target arm64-apple-macos13.0 -c AutoLock/lowlevel.c -o "$build_temp/lowlevel.o"
xcrun swiftc -O -swift-version 5 -module-name AutoLock -target arm64-apple-macos13.0 \
  -import-objc-header AutoLock/AutoLock-Bridging-Header.h \
  -F /System/Library/PrivateFrameworks -framework login -framework MediaRemote -framework IOKit \
  AutoLock/*.swift "$build_temp/lowlevel.o" -o "$output_app/Contents/MacOS/AutoLock"
xcrun clang -O2 -fobjc-arc -target arm64-apple-macos13.0 -framework Cocoa \
  Launcher/main.m Launcher/AppDelegate.m -o "$launcher_app/Contents/MacOS/AutoLockLauncher"
python3 - "$output_app" "$seed_app" <<'PY'
from pathlib import Path
import hashlib, json, plistlib, subprocess, sys
app, seed = map(Path, sys.argv[1:])
seed_info = plistlib.loads((seed / 'Contents/Info.plist').read_bytes())
try:
    revision = subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()
except subprocess.CalledProcessError:
    revision = seed_info.get('AutoLockSourceRevision', '未记录')
hashes = {str(p): hashlib.sha256(p.read_bytes()).hexdigest()
          for folder in ['AutoLock', 'Launcher'] for p in sorted(Path(folder).rglob('*')) if p.is_file()}
digest = hashlib.sha256(json.dumps(hashes, sort_keys=True).encode()).hexdigest()
manifest = {'源码基线': revision, '本地源码校验值': digest, '构建输入': hashes,
            '复用界面资源基线': seed_info.get('AutoLockSourceRevision', '未记录')}
(app / 'Contents/Resources/源码构建信息.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2)+'\n')
for folder, destination, name, identifier in [
    ('AutoLock', app, 'AutoLock', 'jp.sone.BLEUnlock'),
    ('Launcher', app / 'Contents/Library/LoginItems/AutoLockLauncher.app', 'AutoLockLauncher', 'jp.sone.BLEUnlock.Launcher')]:
    info = plistlib.loads((Path(folder) / 'Info.plist').read_bytes())
    info.update(CFBundleDevelopmentRegion='zh-Hans', CFBundleExecutable=name, CFBundleName=name,
                CFBundleIdentifier=identifier, LSMinimumSystemVersion='13.0')
    if folder == 'AutoLock':
        info.update(CFBundleIconFile='AppIcon', AutoLockSourceRevision=revision, AutoLockSourceFingerprint=digest)
    (destination / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
    (destination / 'Contents/PkgInfo').write_bytes(b'APPL????')
PY
codesign --force --sign "$signing_identity" --timestamp=none "$launcher_app"
codesign --force --sign "$signing_identity" --timestamp=none --entitlements AutoLock/AutoLock.entitlements "$output_app"
codesign --verify --deep --strict "$output_app"
python3 scripts/check_localization.py "$output_app"
