#!/usr/bin/env python3
import os, re, plistlib, json
from pathlib import Path
root=Path(__file__).resolve().parents[1]
tag=os.environ['RELEASE_TAG']
assert re.fullmatch(r'v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-beta(?:\.(0|[1-9][0-9]*))?)?',tag), 'Invalid release tag'
prerelease='-beta' in tag
with (root/'Info.plist').open('rb') as f:info=plistlib.load(f)
assert info['CFBundleShortVersionString']==tag[1:], 'Tag and app version differ'
assert info['CFBundleIdentifier']=='com.duoduocat.codexbuddy', 'Unexpected bundle identifier'
assert info['GitHubRepository']==os.environ['EXPECTED_REPOSITORY'], 'Unexpected update repository'
assert (root/'LICENSE').read_text().startswith('                    GNU GENERAL PUBLIC LICENSE'), 'GPL license missing'
notes=(root/'releases'/f'{tag}.md').read_text()
assert '请填写本次变更' not in notes, 'Finish release notes before publishing'
policy_path=root/'releases'/f'{tag}.json'
policy=json.loads(policy_path.read_text()) if policy_path.exists() else {'schemaVersion':1,'version':tag[1:],'mode':'none'}
percentage=policy.get('rolloutPercentage')
valid_schema=(policy.get('schemaVersion')==1 and percentage is None) or (policy.get('schemaVersion')==2 and policy.get('mode')=='notify' and percentage is None) or (policy.get('schemaVersion')==3 and type(percentage) is int and 0 <= percentage <= 100)
assert valid_schema and policy.get('version')==tag[1:], 'Invalid release metadata version'
assert policy.get('mode') in {'none','notify','silent'}, 'Invalid release metadata mode'
if os.environ.get('UPDATE_MODE'):
    assert os.environ['UPDATE_MODE'] in {'none','notify','silent'}, 'Invalid release mode override'
    policy['mode']=os.environ['UPDATE_MODE']
    policy['schemaVersion']=3 if percentage is not None else 2 if policy['mode']=='notify' else 1
if os.environ.get('ROLLOUT_PERCENTAGE'):
    raw=os.environ['ROLLOUT_PERCENTAGE']
    assert re.fullmatch(r'(0|[1-9][0-9]?|100)',raw), 'Invalid rollout percentage override'
    policy.update(schemaVersion=3,rolloutPercentage=int(raw))
(root/'dist').mkdir(exist_ok=True)
(root/'dist/release-notes.md').write_text(notes)
(root/'dist/update-policy.json').write_text(json.dumps(policy,indent=2)+'\n')
if os.environ.get('GITHUB_OUTPUT'):
 with open(os.environ['GITHUB_OUTPUT'],'a') as f:f.write('tag='+tag+'\nprerelease='+str(prerelease).lower()+'\n')
print('Validated release',tag)
