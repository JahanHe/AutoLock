#!/bin/sh
# 编译并运行真实状态判断器；无需 Xcode 窗口、蓝牙权限或屏幕操作。
set -eu
cd "$(dirname "$0")/.."
check_dir=$(mktemp -d)
trap 'rm -rf "$check_dir"' EXIT
xcrun swiftc -swift-version 5 BLEUnlock/ConnectionStatus.swift BLEUnlock/BLE.swift BLEUnlock/LEDeviceInfo.swift BLEUnlock/appleDeviceNames.swift Tests/main.swift -o "$check_dir/check"
"$check_dir/check"
