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


base = plist(ROOT / 'AutoLock/Base.lproj/Localizable.strings')
chinese = plist(ROOT / 'AutoLock/zh-Hans.lproj/Localizable.strings')
assert base == chinese, '默认文案和简体中文文案不一致'
assert all(has_chinese(value) for value in chinese.values()), '有尚未汉化的文案'
sources = '\n'.join(p.read_text() for p in (ROOT / 'AutoLock').glob('*.swift'))
keys = set(re.findall(r'\bt\("([^"]+)"\)', sources))
assert keys <= chinese.keys(), f'缺少中文文案：{keys - chinese.keys()}'
assert chinese['keychain_error'].count('%d') == 1, '钥匙串错误代码占位符有误'
assert chinese['wake_without_unlocking'] == '仅唤醒，不自动解锁', '唤醒选项含义发生变化'
assert '(Active)' not in sources and 'errorModal("' not in sources, '还有硬编码的英文界面提示'

project = plist(ROOT / 'AutoLock.xcodeproj/project.pbxproj')
objects = project['objects']
settings = objects[project['rootObject']]
assert settings['developmentRegion'] == 'zh-Hans'
assert set(settings['knownRegions']) == {'Base', 'zh-Hans'}
for obj in objects.values():
    if obj['isa'] == 'PBXVariantGroup' and obj.get('name') in ('AboutBox.xib', 'Localizable.strings'):
        assert {objects[child]['name'] for child in obj['children']} == {'Base', 'zh-Hans'}

about = ET.parse(ROOT / 'AutoLock/Base.lproj/AboutBox.xib')
for element in about.iter():
    title = element.get('title')
    if title:
        assert has_chinese(title), f'关于窗口有英文标题：{title}'
translations = plist(ROOT / 'AutoLock/zh-Hans.lproj/AboutBox.strings')
for key, value in translations.items():
    object_id, attribute = key.rsplit('.', 1)
    element = about.find(f'.//*[@id="{object_id}"]')
    assert element is not None and element.get(attribute) == value, f'界面翻译与控件不匹配：{key}'
assert '#{version}' in translations['VLW-23-BX0.title']
assert 'OTHER DEALINGS IN THE SOFTWARE.' in (ROOT / 'LICENSE').read_text()
assert 'Google LLC' in (ROOT / 'LICENSE').read_text()
info = plist(ROOT / 'AutoLock/Info.plist')
assert has_chinese(info['NSBluetoothAlwaysUsageDescription'])
assert info['CFBundleDisplayName'] == 'AutoLock', '应用显示名称必须是 AutoLock'
assert not any('BLEUnlock' in value or 'MacAutolock' in value for value in chinese.values()), '界面残留旧产品名'

# 检查自然语言入口，避免界面已汉化而文档、日志仍退回外语。
for document in ROOT.glob('*.md'):
    body = re.sub(r'```.*?```', '', document.read_text(), flags=re.S)
    for heading in re.findall(r'^#+ (.+)$', body, flags=re.M):
        assert has_chinese(heading), f'文档标题未汉化：{document.name}：{heading}'
for source in (ROOT / 'AutoLock').glob('*.swift'):
    for message in re.findall(r'\bprint\("([^"\n]*)"\)', source.read_text()):
        assert has_chinese(message), f'运行日志未汉化：{source.name}：{message}'
assert set(p.name for p in (ROOT / 'AutoLock').glob('*.lproj')) == {'Base.lproj', 'zh-Hans.lproj'}
assert (ROOT / 'LICENSE').read_text().startswith('MIT 许可证（中文参考译文）')
models = (ROOT / 'AutoLock/appleDeviceNames.swift').read_text()
assert not re.search(r'generation|inch|Cellular|Rev A|\d+mm', models), '设备规格说明未汉化'

if len(sys.argv) > 1:
    app = Path(sys.argv[1])
    resources = app / 'Contents/Resources'
    assert app.name == 'AutoLock.app', '安装后的应用文件名必须是 AutoLock.app'
    app_info = plist(app / 'Contents/Info.plist')
    assert app_info['CFBundleName'] == app_info['CFBundleDisplayName'] == app_info['CFBundleExecutable'] == 'AutoLock'
    assert app_info['CFBundleIdentifier'] == 'jp.sone.BLEUnlock', '升级必须保留原有数据标识'
    for executable in [app / 'Contents/MacOS/AutoLock', app / 'Contents/Library/LoginItems/AutoLockLauncher.app/Contents/MacOS/AutoLockLauncher']:
        assert subprocess.check_output(['lipo', '-archs', str(executable)], text=True).strip() == 'arm64', '只构建 Apple 芯片版本'
    assert set(p.name for p in resources.glob('*.lproj')) == {'Base.lproj', 'zh-Hans.lproj'}
    assert plist(resources / 'zh-Hans.lproj/Localizable.strings') == chinese
    assert plist(app / 'Contents/Info.plist')['CFBundleDevelopmentRegion'] == 'zh-Hans'
    assert (resources / 'LICENSE').read_bytes() == (ROOT / 'LICENSE').read_bytes()
    assert (resources / 'Base.lproj/AboutBox.nib').exists()
    assert (app / 'Contents/Library/LoginItems/AutoLockLauncher.app').is_dir()
    print('编译产物检查通过：中文资源、许可文件、关于窗口和登录启动器均已打包。')
print(f'汉化检查通过：{len(chinese)} 条中文文案，{len(keys)} 个文案引用，关于窗口及权限说明。')
