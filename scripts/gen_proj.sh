#!/bin/sh
# 生成 Edgely.xcodeproj（ADR-0016）。
# 项目根目录下存在 EdgelyDevices/ 就把设备实现包加入编译，不存在则忽略。
set -e
cd "$(dirname "$0")/.."

# XcodeGen 的 include 会合并多份配置；临时配置放在项目根目录，保证相对路径与 project.yml 一致
SPEC=.project.generated.yml
trap 'rm -f "$SPEC"' EXIT

{
    echo "include:"
    echo "  - project.yml"
    if [ -d EdgelyDevices ]; then
        echo "检测到 EdgelyDevices/，带入设备实现包" >&2
        echo "  - project.devices.yml"
    else
        echo "未检测到 EdgelyDevices/，不带设备实现包" >&2
    fi
} > "$SPEC"

xcodegen generate --spec "$SPEC"
