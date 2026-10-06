#!/usr/bin/env python3
"""Publish only verified public feeds; software changes never enter this path."""
from pathlib import Path
import argparse
import hashlib
import json
import re
import subprocess
import tempfile

REPOSITORY = 'duoduocats/codex-buddy'
ALLOWED = {'announcements/messages.json', 'announcements/tibo-28.json'}
ROOT = Path(__file__).resolve().parents[1]

def run(args, cwd=ROOT):
    return subprocess.check_output(args, cwd=cwd, text=True).strip()

def candidates(directory):
    result = {}
    for relative in sorted(ALLOWED):
        path = directory / Path(relative).name
        if path.exists():
            if path.is_symlink() or not path.is_file():
                raise ValueError('Candidate must be a regular JSON file')
            data = path.read_bytes()
            maximum = 65_536 if path.name == 'messages.json' else 131_072
            if not data or len(data) > maximum:
                raise ValueError('Candidate exceeds feed size limit')
            json.loads(data)
            result[relative] = data
    if not result:
        raise ValueError('No supported public feed candidate')
    return result

def assert_public_origin(origin):
    if origin not in {'https://github.com/duoduocats/codex-buddy.git',
                      'https://github.com/duoduocats/codex-buddy',
                      'git@github.com:duoduocats/codex-buddy.git'}:
        raise ValueError('Unexpected repository origin')

def assert_paths(paths):
    if not paths or not set(paths) <= ALLOWED:
        raise ValueError('Only the two announcement JSON files may be published')

def assert_message_scope(data, previous):
    old = {event['id']:event for event in json.loads(previous).get('events', [])} if previous else {}
    for event in json.loads(data).get('events', []):
        if old.get(event['id']) == event:
            continue
        if event.get('type') != 'message' or not re.fullmatch(
                r'https://(?:x\.com|twitter\.com)/thsottiaux/status/[0-9]{1,25}', event.get('sourceURL', '')):
            raise ValueError('Changed messages must cite the verified Tibo original post')

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--candidate-dir', required=True, type=Path)
    parser.add_argument('--publish', action='store_true', help='Create a data-only PR after the consumer has been released')
    args = parser.parse_args()
    updates = candidates(args.candidate_dir)
    assert_public_origin(run(['git', 'remote', 'get-url', 'origin']))
    if args.publish:
        release = json.loads(run(['gh', 'release', 'view', '--repo', REPOSITORY,
                                  '--json', 'tagName,isDraft,isPrerelease']))
        tag = release['tagName']
        if release['isDraft'] or release['isPrerelease'] or not re.fullmatch(r'v\d+\.\d+\.\d+', tag):
            raise ValueError('A published stable consumer release is required')
        run(['git', 'fetch', 'origin', 'main', f'refs/tags/{tag}:refs/tags/{tag}'])
        # Collection timestamps must not reach old clients which label them as publication times.
        try:
            consumer = run(['git', 'show', f'{tag}:Sources/ResetAnnouncements.swift'])
            run(['git', 'cat-file', '-e', f'{tag}:Sources/TiboChallenge.swift'])
        except subprocess.CalledProcessError:
            raise ValueError('Consumer not released; retain candidates locally and retry later') from None
        if 'ResetTimestampBasis' not in consumer:
            raise ValueError('Collection-time consumer not released')
    with tempfile.TemporaryDirectory(prefix='buddy-public-feed-') as temporary:
        work = Path(temporary) / 'source'
        previous = Path(temporary) / 'previous'
        previous.mkdir()
        run(['git', 'worktree', 'add', '--detach', str(work), 'origin/main'])
        try:
            for relative in ALLOWED:
                path = work / relative
                if path.exists():
                    (previous / path.name).write_bytes(path.read_bytes())
            for relative, data in updates.items():
                if relative == 'announcements/messages.json':
                    old_path = previous / 'messages.json'
                    assert_message_scope(data, old_path.read_bytes() if old_path.exists() else None)
                (work / relative).write_bytes(data)
            validator = work / 'scripts/validate-feeds.sh'
            if not validator.exists():
                # Before rollout only local preview validation is available; never publish.
                validator = ROOT / 'scripts/validate-feeds.sh'
                if args.publish:
                    raise ValueError('Feed validation has not reached main')
                for relative in ALLOWED - updates.keys():
                    path = work / relative
                    if not path.exists():
                        path.write_bytes((ROOT / relative).read_bytes())
            run(['bash', str(validator), str(work/'announcements/messages.json'),
                 str(work/'announcements/tibo-28.json'), str(previous)])
            paths = run(['git', 'diff', '--name-only'], cwd=work).splitlines()
            # New feeds are initially untracked; explicitly stage only the approved paths.
            for relative in sorted(updates):
                run(['git', 'add', '--', relative], cwd=work)
            paths = run(['git', 'diff', '--cached', '--name-only'], cwd=work).splitlines()
            if not paths:
                print(json.dumps({'status':'unchanged'}));return
            assert_paths(paths)
            run(['git', 'diff', '--cached', '--check'], cwd=work)
            if not args.publish:
                print(json.dumps({'status':'validated', 'paths':paths}));return
            digest = hashlib.sha256(b''.join(name.encode()+updates[name] for name in sorted(updates))).hexdigest()[:12]
            branch = f'codex/tibo-feed-{digest}'
            existing = json.loads(run(['gh', 'pr', 'list', '--repo', REPOSITORY, '--head', branch,
                                      '--state', 'open', '--json', 'url']))
            if existing:
                print(json.dumps({'status':'pending', 'url':existing[0]['url']}));return
            run(['git', 'switch', '-c', branch], cwd=work)
            run(['git', '-c', 'user.name=duoduocats',
                 '-c', 'user.email=39798099+duoduocats@users.noreply.github.com',
                 'commit', '-m', 'Update verified Tibo announcements and challenge records'], cwd=work)
            assert_paths(run(['git', 'diff', '--name-only', 'origin/main...HEAD'], cwd=work).splitlines())
            run(['git', 'push', 'origin', f'HEAD:refs/heads/{branch}'], cwd=work)
            body = Path(temporary) / 'body.md'
            body.write_text('Updates the public reset messages and 28-day challenge records from verified Tibo X posts.\n\n'
                            'Validation: native feed decoding, source URL checks, UTC timestamps and revision checks passed.\n'
                            'Only announcement JSON files are changed.\n')
            url = run(['gh', 'pr', 'create', '--repo', REPOSITORY, '--base', 'main', '--head', branch,
                       '--title', 'Update Tibo announcements and challenge records', '--body-file', str(body)], cwd=work)
            print(json.dumps({'status':'created', 'url':url}))
        finally:
            run(['git', 'worktree', 'remove', '--force', str(work)])

if __name__ == '__main__':
    main()
