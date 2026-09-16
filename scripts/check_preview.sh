#!/bin/sh
# 在隔离模式启动实际应用，检查开关联动并截图；不会触发系统锁定。
set -eu
if [ "$#" -ne 2 ]; then
  echo "用法：scripts/check_preview.sh /绝对路径/AutoLock.app /绝对路径/预览目录" >&2
  exit 2
fi
"$1/Contents/MacOS/AutoLock" --preview --capture "$2"
python3 - "$2" <<'PY'
from pathlib import Path
import json
import sys
folder = Path(sys.argv[1])
report = json.loads((folder / '预览检查.json').read_text())
assert report['隔离预览'] and report['设置检查通过'] == 19, '设置检查没有通过'
for page in ['浅色', '深色', '设备', '离开锁定', '靠近与解锁', '菜单栏外观', '其他设置', '效果测试', '运行记录', '失联']:
    assert (folder / f'设置窗口-{page}.png').stat().st_size > 1000, f'缺少有效截图：{page}'
print('实际应用预览检查通过：19 项设置联动检查，10 张窗口截图。')
PY
