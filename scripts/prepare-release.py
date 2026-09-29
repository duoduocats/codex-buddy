#!/usr/bin/env python3
"""Prepare a reviewable release change. Never tags, pushes or publishes."""
import argparse, plistlib, re, json
from pathlib import Path
parser = argparse.ArgumentParser()
parser.add_argument('version', help='e.g. 1.2.1')
parser.add_argument('--mode', choices=['none','notify','silent'], default='none', help='Maintainer-selected release policy; defaults to none')
args = parser.parse_args()
if not re.fullmatch(r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)',args.version):parser.error('Use a stable x.y.z version')
root = Path(__file__).resolve().parents[1]
path = root/'Info.plist'
with path.open('rb') as f:info=plistlib.load(f)
if tuple(map(int,args.version.split('.'))) <= tuple(map(int,info['CFBundleShortVersionString'].split('.'))):parser.error('Version must increase')
notes=root/'releases'/f'v{args.version}.md'
if notes.exists():parser.error('Release notes already exist')
info['CFBundleShortVersionString']=args.version
info['CFBundleVersion']=str(int(info['CFBundleVersion'])+1)
with path.open('wb') as f:plistlib.dump(info,f,sort_keys=False)
notes.parent.mkdir(exist_ok=True)
marker=''
(root/'releases'/f'v{args.version}.json').write_text(json.dumps({'schemaVersion':1,'version':args.version,'mode':args.mode},indent=2)+'\n')
notes.write_text(marker+f'# Codex Buddy {args.version}\n\n## 更新内容\n\n- 请填写本次变更。\n\n## 安装\n\n下载 arm64 DMG，退出旧版后拖入 Applications 替换。当前构建为 ad hoc 签名，尚未公证。\n')
print('Prepared',notes.relative_to(root))
