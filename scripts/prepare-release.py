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
(root/'releases'/f'v{args.version}.json').write_text(json.dumps({'schemaVersion':2 if args.mode=='notify' else 1,'version':args.version,'mode':args.mode},indent=2)+'\n')
notes.write_text(marker+f'# Codex Buddy v{args.version}\n\n## 更新内容\n\n- 请填写本次变更。\n\n## What’s new\n\n- Add the changes in this release.\n\n## 安装 / Install\n\nApple Silicon · macOS 13+。下载 arm64 DMG，退出旧版，将 Codex Buddy.app 拖入 Applications 替换。首次打开如被系统拦截，请按 README 的安装指引操作。当前发布包采用 ad hoc 签名，尚未经过 Apple 公证。\n\nApple Silicon · macOS 13+. Download the arm64 DMG, quit the previous app, and drag Codex Buddy.app into Applications to replace it. If macOS blocks the first launch, follow the installation steps in the README. This release is ad hoc signed and has not been notarized by Apple.\n')
print('Prepared',notes.relative_to(root))
