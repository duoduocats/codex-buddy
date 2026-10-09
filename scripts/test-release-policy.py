#!/usr/bin/env python3
"""Validate release configuration without contacting GitHub or altering real versions."""
from pathlib import Path
import json, os, plistlib, shutil, subprocess, tempfile
source=Path(__file__).resolve().parents[1]
for mode in ['none','notify','silent']:
    with tempfile.TemporaryDirectory(prefix='buddy-release-policy-') as temporary:
        root=Path(temporary);(root/'scripts').mkdir()
        for name in ['prepare-release.py','release-metadata.py']:
            shutil.copyfile(source/'scripts'/name,root/'scripts'/name)
        shutil.copyfile(source/'LICENSE',root/'LICENSE')
        info={'CFBundleShortVersionString':'1.0.0','CFBundleVersion':'1',
              'CFBundleIdentifier':'com.duoduocat.codexbuddy','GitHubRepository':'example/buddy'}
        (root/'Info.plist').write_bytes(plistlib.dumps(info))
        args=['python3',str(root/'scripts/prepare-release.py'),'1.0.1']
        if mode!='none':args += ['--mode',mode]
        subprocess.run(args,check=True,capture_output=True)
        notes='修复已知问题。\n'
        (root/'releases/v1.0.1.md').write_text(notes)
        env=os.environ.copy();env.update(RELEASE_TAG='v1.0.1',EXPECTED_REPOSITORY='example/buddy',UPDATE_MODE='')
        env.pop('GITHUB_OUTPUT',None)
        subprocess.run(['python3',str(root/'scripts/release-metadata.py')],env=env,check=True,capture_output=True)
        policy=json.loads((root/'dist/update-policy.json').read_text())
        assert policy=={'schemaVersion':2 if mode=='notify' else 1,'version':'1.0.1','mode':mode}
        assert (root/'dist/release-notes.md').read_text()==notes
        env['UPDATE_MODE']='notify'
        subprocess.run(['python3',str(root/'scripts/release-metadata.py')],env=env,check=True,capture_output=True)
        assert json.loads((root/'dist/update-policy.json').read_text())['mode']=='notify'
        assert json.loads((root/'dist/update-policy.json').read_text())['schemaVersion']==2
        assert (root/'dist/release-notes.md').read_text()==notes
        env['UPDATE_MODE']='unexpected'
        assert subprocess.run(['python3',str(root/'scripts/release-metadata.py')],env=env,capture_output=True).returncode != 0
        print('Release metadata scenario passed:',mode)

with tempfile.TemporaryDirectory(prefix='buddy-beta-release-') as temporary:
    root=Path(temporary);(root/'scripts').mkdir()
    for name in ['prepare-release.py','release-metadata.py']:
        shutil.copyfile(source/'scripts'/name,root/'scripts'/name)
    shutil.copyfile(source/'LICENSE',root/'LICENSE')
    info={'CFBundleShortVersionString':'2.0.0','CFBundleVersion':'1',
          'CFBundleIdentifier':'com.duoduocat.codexbuddy','GitHubRepository':'example/buddy'}
    (root/'Info.plist').write_bytes(plistlib.dumps(info))
    for version in ['2.1.0-beta','2.1.0-beta.1','2.1.0-beta.10','2.1.0']:
        subprocess.run(['python3',str(root/'scripts/prepare-release.py'),version],check=True,capture_output=True)
        (root/'releases'/f'v{version}.md').write_text('Synthetic release notes')
        output=root/'github-output';output.write_text('')
        env=os.environ.copy();env.update(RELEASE_TAG='v'+version,EXPECTED_REPOSITORY='example/buddy',UPDATE_MODE='',GITHUB_OUTPUT=str(output))
        subprocess.run(['python3',str(root/'scripts/release-metadata.py')],env=env,check=True,capture_output=True)
        assert json.loads((root/'dist/update-policy.json').read_text())=={'schemaVersion':1,'version':version,'mode':'none'}
        assert ('prerelease='+('true' if '-beta' in version else 'false')) in output.read_text()
    for invalid in ['2.1.0-beta.2','2.2.0-beta.x','2.2.0-beta.01','2.2.0-alpha.1']:
        assert subprocess.run(['python3',str(root/'scripts/prepare-release.py'),invalid],capture_output=True).returncode!=0
    print('Beta release preparation passed: beta ordering, stable promotion, prerelease flags and unchanged mode default')

for percentage in [0,10,100]:
    with tempfile.TemporaryDirectory(prefix='buddy-phased-release-') as temporary:
        root=Path(temporary);(root/'scripts').mkdir()
        for name in ['prepare-release.py','release-metadata.py']:shutil.copyfile(source/'scripts'/name,root/'scripts'/name)
        shutil.copyfile(source/'LICENSE',root/'LICENSE')
        info={'CFBundleShortVersionString':'1.0.0','CFBundleVersion':'1','CFBundleIdentifier':'com.duoduocat.codexbuddy','GitHubRepository':'example/buddy'}
        (root/'Info.plist').write_bytes(plistlib.dumps(info))
        subprocess.run(['python3',str(root/'scripts/prepare-release.py'),'1.0.1','--mode','silent','--rollout-percentage',str(percentage)],check=True,capture_output=True)
        (root/'releases/v1.0.1.md').write_text('Synthetic release notes')
        env=os.environ.copy();env.update(RELEASE_TAG='v1.0.1',EXPECTED_REPOSITORY='example/buddy',UPDATE_MODE='',ROLLOUT_PERCENTAGE='')
        env.pop('GITHUB_OUTPUT',None)
        subprocess.run(['python3',str(root/'scripts/release-metadata.py')],env=env,check=True,capture_output=True)
        assert json.loads((root/'dist/update-policy.json').read_text())=={'schemaVersion':3,'version':'1.0.1','mode':'silent','rolloutPercentage':percentage}
        env.update(UPDATE_MODE='notify',ROLLOUT_PERCENTAGE='50')
        subprocess.run(['python3',str(root/'scripts/release-metadata.py')],env=env,check=True,capture_output=True)
        assert json.loads((root/'dist/update-policy.json').read_text())=={'schemaVersion':3,'version':'1.0.1','mode':'notify','rolloutPercentage':50}
        for invalid in ['-1','101','1.5','true','01']:
            env['ROLLOUT_PERCENTAGE']=invalid
            assert subprocess.run(['python3',str(root/'scripts/release-metadata.py')],env=env,capture_output=True).returncode!=0
        env.update(UPDATE_MODE='',ROLLOUT_PERCENTAGE='')
        invalid={'schemaVersion':1,'version':'1.0.1','mode':'silent','rolloutPercentage':10}
        (root/'releases/v1.0.1.json').write_text(json.dumps(invalid))
        assert subprocess.run(['python3',str(root/'scripts/release-metadata.py')],env=env,capture_output=True).returncode!=0
print('Phased release metadata passed: explicit percentage, preserved mode, overrides and older-schema rejection')
