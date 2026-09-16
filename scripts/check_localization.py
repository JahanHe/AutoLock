#!/usr/bin/env python3
"""检查中文文案、界面资源以及可选的编译产物；不启动蓝牙或锁屏。"""
from pathlib import Path
import json
import re
import subprocess
import sys
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]


def plist(path):
    return json.loads(subprocess.check_output(
        ['plutil', '-convert', 'json', '-o', '-', str(path)], text=True))


def has_chinese(text):
    return re.search(r'[\u4e00-\u9fff]', text) is not None


base = plist(ROOT / 'BLEUnlock/Base.lproj/Localizable.strings')
chinese = plist(ROOT / 'BLEUnlock/zh-Hans.lproj/Localizable.strings')
assert base == chinese, '默认文案和简体中文文案不一致'
assert all(has_chinese(value) for value in chinese.values()), '有尚未汉化的文案'
sources = '\n'.join(p.read_text() for p in (ROOT / 'BLEUnlock').glob('*.swift'))
keys = set(re.findall(r'\bt\("([^"]+)"\)', sources))
assert keys <= chinese.keys(), f'缺少中文文案：{keys - chinese.keys()}'
assert chinese['keychain_error'].count('%d') == 1, '钥匙串错误代码占位符有误'
assert chinese['wake_without_unlocking'] == '仅唤醒，不自动解锁', '唤醒选项含义发生变化'
assert '(Active)' not in sources and 'errorModal("' not in sources, '还有硬编码的英文界面提示'

project = plist(ROOT / 'BLEUnlock.xcodeproj/project.pbxproj')
objects = project['objects']
settings = objects[project['rootObject']]
assert settings['developmentRegion'] == 'zh-Hans'
assert set(settings['knownRegions']) == {'Base', 'zh-Hans'}
for obj in objects.values():
    if obj['isa'] == 'PBXVariantGroup' and obj.get('name') in ('AboutBox.xib', 'Localizable.strings'):
        assert {objects[child]['name'] for child in obj['children']} == {'Base', 'zh-Hans'}

about = ET.parse(ROOT / 'BLEUnlock/Base.lproj/AboutBox.xib')
for element in about.iter():
    title = element.get('title')
    if title:
        assert has_chinese(title), f'关于窗口有英文标题：{title}'
translations = plist(ROOT / 'BLEUnlock/zh-Hans.lproj/AboutBox.strings')
for key, value in translations.items():
    object_id, attribute = key.rsplit('.', 1)
    element = about.find(f'.//*[@id="{object_id}"]')
    assert element is not None and element.get(attribute) == value, f'界面翻译与控件不匹配：{key}'
assert '#{version}' in translations['VLW-23-BX0.title']
assert 'OTHER DEALINGS IN THE SOFTWARE.' in (ROOT / 'LICENSE').read_text()
assert 'Google LLC' in (ROOT / 'LICENSE').read_text()
info = plist(ROOT / 'BLEUnlock/Info.plist')
assert has_chinese(info['NSBluetoothAlwaysUsageDescription'])

if len(sys.argv) > 1:
    app = Path(sys.argv[1])
    resources = app / 'Contents/Resources'
    assert set(p.name for p in resources.glob('*.lproj')) == {'Base.lproj', 'zh-Hans.lproj'}
    assert plist(resources / 'zh-Hans.lproj/Localizable.strings') == chinese
    assert plist(app / 'Contents/Info.plist')['CFBundleDevelopmentRegion'] == 'zh-Hans'
    assert (resources / 'LICENSE').read_bytes() == (ROOT / 'LICENSE').read_bytes()
    assert (resources / 'Base.lproj/AboutBox.nib').exists()
    assert (app / 'Contents/Library/LoginItems/Launcher.app').is_dir()
    print('编译产物检查通过：中文资源、许可文件、关于窗口和登录启动器均已打包。')
print(f'汉化检查通过：{len(chinese)} 条中文文案，{len(keys)} 个文案引用，关于窗口及权限说明。')
