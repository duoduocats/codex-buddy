#!/usr/bin/env python3
"""Exercise replace/rollback using disposable dummy app directories, never the installed app."""
from pathlib import Path
import tempfile, subprocess, shutil
root=Path(__file__).resolve().parents[1]
script=(root/'Resources/install-update.sh').read_text()
with tempfile.TemporaryDirectory(prefix='buddy-installer-test-') as tmp:
    base=Path(tmp)
    mock=base/'mock-open'
    mock.write_text("#!/bin/bash\nprintf '%s\\n' \"$@\" >> \"$(dirname \"$0\")/open-args\"\nexit 0\n")
    mock.chmod(0o700)
    for case in ['success','replace-failure','open-failure','background-success','background-open-failure']:
        folder=base/case;folder.mkdir()
        target=folder/'Codex Buddy.app';target.mkdir();(target/'version').write_text('old')
        work=folder/'.codex-buddy-update-test.noindex';work.mkdir()
        new=work/'Codex Buddy.app';new.mkdir();(new/'version').write_text('new')
        code=script.replace('/usr/bin/open',str(mock))
        if case=='replace-failure':code=code.replace('/bin/mv "$NEW" "$TARGET"','false')
        if case in ['open-failure','background-open-failure']:code=code.replace('if ! open_target; then','if ! false; then')
        runner=work/'install-update.sh';runner.write_text(code)
        result=subprocess.run(['/bin/bash',str(runner),str(work),str(target),'999999999','background' if case.startswith('background') else 'foreground'],capture_output=True)
        if case in ['success','background-success']:
            assert result.returncode==0
            assert (target/'version').read_text()=='new'
            assert (work/'previous.app/version').read_text()=='old'
        else:
            assert result.returncode!=0
            assert (target/'version').read_text()=='old'
        print('Installer scenario passed:',case)

    assert "-g" in (base/"open-args").read_text().splitlines()
