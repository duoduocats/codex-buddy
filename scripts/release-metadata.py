#!/usr/bin/env python3
import os, re, plistlib, json
from pathlib import Path
root=Path(__file__).resolve().parents[1]
tag=os.environ['RELEASE_TAG']
assert re.fullmatch(r'v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)',tag), 'Invalid stable tag'
with (root/'Info.plist').open('rb') as f:info=plistlib.load(f)
assert info['CFBundleShortVersionString']==tag[1:], 'Tag and app version differ'
assert info['CFBundleIdentifier']=='com.duoduocat.codexbuddy', 'Unexpected bundle identifier'
assert info['GitHubRepository']==os.environ['EXPECTED_REPOSITORY'], 'Unexpected update repository'
assert (root/'LICENSE').read_text().startswith('                    GNU GENERAL PUBLIC LICENSE'), 'GPL license missing'
notes=(root/'releases'/f'{tag}.md').read_text()
assert '请填写本次变更' not in notes, 'Finish release notes before publishing'
policy_path=root/'releases'/f'{tag}.json'
policy=json.loads(policy_path.read_text()) if policy_path.exists() else {'schemaVersion':1,'version':tag[1:],'mode':'none'}
assert policy.get('schemaVersion')==1 and policy.get('version')==tag[1:], 'Invalid release metadata version'
assert policy.get('mode') in {'none','notify','silent'}, 'Invalid release metadata mode'
if os.environ.get('UPDATE_MODE'):
    assert os.environ['UPDATE_MODE'] in {'none','notify','silent'}, 'Invalid release mode override'
    policy['mode']=os.environ['UPDATE_MODE']
(root/'dist').mkdir(exist_ok=True)
(root/'dist/release-notes.md').write_text(notes)
(root/'dist/update-policy.json').write_text(json.dumps(policy,indent=2)+'\n')
if os.environ.get('GITHUB_OUTPUT'):
 with open(os.environ['GITHUB_OUTPUT'],'a') as f:f.write('tag='+tag+'\n')
print('Validated release',tag)
