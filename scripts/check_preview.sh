#!/bin/sh
# 在隔离模式启动实际应用，检查开关联动并截图；不会触发系统锁定。
set -eu
if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
  echo "用法：scripts/check_preview.sh /绝对路径/AutoLock.app /绝对路径/预览目录 [--capture-composited]" >&2
  exit 2
fi
"$1/Contents/MacOS/AutoLock" --preview --capture "$2" ${3:+"$3"}
python3 - "$2" <<'PY'
from pathlib import Path
import json
import sys
folder = Path(sys.argv[1])
report = json.loads((folder / '预览检查.json').read_text())
assert report['隔离预览'] and report['设置检查通过'] == 65, '设置检查没有通过'
navigation = json.loads((folder / '导航检查.json').read_text())
assert navigation['目标分组'] == navigation['当前分组'] == '靠近与解锁', '展开后的分组跳转没有生效'
for page in ['浅色', '深色', '设备', '离开锁定', '靠近与解锁', '分段亮屏', '菜单栏外观', '其他设置', '效果测试', '运行记录', '失联', '已锁定', '已关屏', '屏保', '透明对照']:
    assert (folder / f'设置窗口-{page}.png').stat().st_size > 1000, f'缺少有效截图：{page}'
print('实际应用预览检查通过：65 项设置联动检查、1 项分组跳转检查，15 张窗口截图。')
PY
