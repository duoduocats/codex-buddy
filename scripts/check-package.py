#!/usr/bin/env python3
"""Check the actual shipping app, not the developer's home directory."""
from pathlib import Path
import argparse, plistlib, re, subprocess, tempfile
parser = argparse.ArgumentParser()
parser.add_argument('app', type=Path)
parser.add_argument('--dmg', type=Path)
args = parser.parse_args()
app = args.app
expected = {
    'Contents/Info.plist', 'Contents/MacOS/CodexBuddy',
    'Contents/Resources/AppIcon.icns', 'Contents/Resources/install-update.sh',
    'Contents/Resources/BuddyHead.png',
    'Contents/Resources/LICENSE.txt', 'Contents/_CodeSignature/CodeResources',
}
files = {str(p.relative_to(app)) for p in app.rglob('*') if p.is_file()}
assert files == expected, 'Unexpected or missing shipping files'
assert not any(p.is_symlink() for p in app.rglob('*')), 'Symlink in app'
size = sum((app / name).stat().st_size for name in files)
assert size < 4_000_000, 'App exceeds 4 MB budget'
info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
assert info['CFBundleIdentifier'] == 'com.duoduocat.codexbuddy', 'Unexpected app identity'
patterns = [
    rb'/(?:Users|home)/[A-Za-z0-9_.-]+/',
    rb'-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----',
    rb'(?:sk-(?:proj-|svcacct-)?[A-Za-z0-9_-]{35,}|gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,})',
    rb'eyJ[A-Za-z0-9_-]{12,}\.[A-Za-z0-9_-]{12,}\.[A-Za-z0-9_-]{12,}',
]
def audit_bytes(data, name):
    assert not any(re.search(pattern, data) for pattern in patterns), 'Sensitive pattern in ' + name

for name in files:
    audit_bytes((app / name).read_bytes(), name)
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
architectures = subprocess.check_output(['lipo', '-archs', str(app / 'Contents/MacOS/CodexBuddy')]).decode().strip()
assert architectures == 'arm64', 'Unexpected architecture'
print(f'Package passed: {len(files)} files, {size:,} bytes, arm64, valid signature')
if args.dmg:
    dmg_size = args.dmg.stat().st_size
    assert dmg_size < 5_000_000, 'DMG exceeds 5 MB budget'
    with tempfile.TemporaryDirectory(prefix='codex-buddy-package-audit-') as mount:
        subprocess.run(['hdiutil','attach',str(args.dmg),'-readonly','-nobrowse',
                        '-noautoopen','-mountpoint',mount,'-quiet'],check=True)
        try:
            volume=Path(mount)
            required={'Codex Buddy.app','Applications','安装指南 Installation Guide.pdf',
                      '.background','.DS_Store'}
            system={'.fseventsd','.Trashes','.Spotlight-V100'}
            actual={p.name for p in volume.iterdir()}
            assert required <= actual and actual <= required | system, 'Unexpected DMG contents'
            # Examine extended metadata as well as file bytes. macOS may add its
            # protected provenance marker even when copies exclude xattrs. The
            # public asset is rebuilt on GitHub; no local source URLs are kept.
            metadata_count=0
            for entry in [volume,*volume.rglob('*')]:
                if any(part in system for part in entry.relative_to(volume).parts):
                    continue
                names=subprocess.check_output(['xattr','-s',str(entry)]).decode().splitlines()
                assert set(names) <= {'com.apple.provenance'}, 'Unexpected extended metadata in DMG'
                for name in names:
                    value=bytes.fromhex(subprocess.check_output(['xattr','-spx',name,str(entry)]).decode())
                    audit_bytes(value,'DMG extended metadata')
                    metadata_count+=1
            print(f'DMG extended metadata passed: {metadata_count} system provenance markers, no source URLs')
            assert (volume/'Applications').is_symlink(), 'Missing Applications shortcut'
            assert (volume/'Applications').readlink() == Path('/Applications'), 'Wrong install destination'
            assert {p.name for p in (volume/'.background').iterdir()} == {'install.png'}, 'Unexpected background files'
            mounted_app=volume/'Codex Buddy.app'
            mounted_files={str(p.relative_to(mounted_app)) for p in mounted_app.rglob('*') if p.is_file()}
            assert mounted_files == expected, 'Unexpected app files inside DMG'
            for name in files:
                assert (mounted_app/name).read_bytes() == (app/name).read_bytes(), 'App differs inside DMG: '+name
            guide=volume/'安装指南 Installation Guide.pdf'
            assert guide.stat().st_size < 500_000, 'Guide exceeds 500 KB budget'
            data=guide.read_bytes()
            from pdf_privacy import audit_pdf
            pdf_streams=audit_pdf(data,audit_bytes)
            print(f'Installation PDF passed: {pdf_streams} decoded streams, two searchable language guides')
            background=volume/'.background/install.png'
            assert background.stat().st_size < 500_000, 'Background exceeds 500 KB budget'
            audit_bytes(background.read_bytes(),'Finder background')
            audit_bytes((volume/'.DS_Store').read_bytes(),'Finder layout')
            from ds_store import DSStore
            from mac_alias import Alias
            with DSStore.open(str(volume/'.DS_Store'),'r') as store:
                layout=store['.']['icvp']
                assert layout['backgroundType'] == 2 and layout['iconSize'] == 96.0, 'Wrong Finder layout'
                alias=Alias.from_bytes(layout['backgroundImageAlias'])
                assert alias.volume.name == 'Codex Buddy', 'Background alias uses wrong volume'
                assert alias.target.posix_path == '/.background/install.png', 'Background alias uses wrong path'
                for name,position in [('Codex Buddy.app',(204,220)),('Applications',(516,220)),
                                      ('安装指南 Installation Guide.pdf',(360,440))]:
                    assert store[name]['Iloc'] == position, 'Wrong icon position: '+name
            subprocess.run(['codesign','--verify','--deep','--strict',str(mounted_app)],check=True)
        finally:
            subprocess.run(['hdiutil','detach',mount,'-quiet'],check=True)
    print(f'DMG passed: {dmg_size:,} bytes, app integrity, bilingual PDF, Finder layout, privacy scan')
