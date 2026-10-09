#!/usr/bin/env python3
"""Run real helper processes against disposable synthetic app directories."""
from pathlib import Path
import os,signal,tempfile,subprocess,json,time
root=Path(__file__).resolve().parents[1]
script=(root/'Resources/install-update.sh').read_text()
token='12345678-1234-1234-1234-123456789ABC'
with tempfile.TemporaryDirectory(prefix='buddy-installer-test-') as tmp:
    base=Path(tmp);mock=base/'mock-open'
    mock.write_text('#!/bin/bash\nprintf "%s\\n" "$@" >> "$(dirname "$0")/open-args"\nexit 0\n');mock.chmod(0o700)
    for case in ['success','background-success','replace-failure','launch-failure','no-readiness','background-no-readiness','wrong-token','crash-after-ready']:
        folder=base/case;folder.mkdir()
        target=folder/'Codex Buddy.app';target.mkdir();(target/'version').write_text('old')
        work=folder/'.codex-buddy-update-test.noindex';work.mkdir()
        new=work/'Codex Buddy.app';(new/'Contents/MacOS').mkdir(parents=True);(new/'version').write_text('new')
        (work/'health-request.json').write_text(json.dumps({'token':token,'version':'2.0.0','target':str(target)}))
        executable=new/'Contents/MacOS/CodexBuddy'
        executable.write_text('#!/bin/bash\nWORK="$2"\nTOKEN="$4"\nprintf "%s\\n" "$$" > "$WORK/test-pid"\n'+
            ('exit 1\n' if case=='launch-failure' else '')+
            ('' if case in ['no-readiness','background-no-readiness'] else 'printf "%s %s\\n" "'+('wrong' if case=='wrong-token' else '$TOKEN')+'" "$$" > "$WORK/ready"\n')+
            ('sleep 0.5\nexit 1\n' if case=='crash-after-ready' else 'exec sleep 60\n'))
        executable.chmod(0o700)
        code=script.replace('/usr/bin/open',str(mock))
        if case=='replace-failure':code=code.replace('/bin/mv "$NEW" "$TARGET"','false')
        # Shorten only the synthetic timeout; production waits up to 30 seconds.
        code=code.replace('n<150','n<5')
        runner=work/'install-update.sh';runner.write_text(code)
        result=subprocess.run(['/bin/bash',str(runner),str(work),str(target),'999999999','background' if case.startswith('background') else 'foreground',token],capture_output=True,timeout=15)
        pidfile=work/'test-pid';pid=int(pidfile.read_text()) if pidfile.exists() else None
        try:
            if case in ['success','background-success']:
                assert result.returncode==0,(case,result.stderr)
                assert (target/'version').read_text()=='new'
                assert (work/'previous.app/version').read_text()=='old'
                assert (work/'result.txt').read_text()=='Update installed and startup confirmed\n'
            else:
                assert result.returncode!=0,case
                assert (target/'version').read_text()=='old'
                assert (work/'result.txt').read_text()=='Update failed; previous version restored\n'
                if pid:
                    try:os.kill(pid,0)
                    except ProcessLookupError:pass
                    else:raise AssertionError('Failed replacement is still running')
            print('Installer scenario passed:',case)
        finally:
            if pid:
                try:os.kill(pid,signal.SIGTERM)
                except ProcessLookupError:pass
    assert '-g' in (base/'open-args').read_text().splitlines()
    assert '--update-restored' in (base/'open-args').read_text().splitlines()
