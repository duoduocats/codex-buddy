#!/usr/bin/env python3
"""Reuse a successful CI job only for the identical complete Git tree."""
import argparse
import io
import json
import os
from pathlib import Path
import re
import subprocess
import zipfile

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = '.github/workflows/ci.yml'
ARTIFACT = 'verified-source'
RECEIPT = 'verified-source.json'


def git(*args):
    return subprocess.check_output(['git', *args], cwd=ROOT, text=True).strip()


def api(path, binary=False):
    data = subprocess.check_output(['gh', 'api', path], stderr=subprocess.DEVNULL, timeout=30)
    return data if binary else json.loads(data)


def unpack(data):
    if len(data) > 65_536:
        raise ValueError('Oversized verification artifact')
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        entries = archive.infolist()
        if len(entries) != 1 or entries[0].filename != RECEIPT or entries[0].file_size > 8192:
            raise ValueError('Unexpected verification artifact contents')
        receipt = json.loads(archive.read(RECEIPT))
        if not isinstance(receipt, dict):
            raise ValueError('Invalid verification receipt')
        return receipt


def matches(receipt, run, commit, repository, tree, workflow_blob):
    return (
        run.get('status') == 'completed' and run.get('conclusion') == 'success'
        and run.get('event') in {'push', 'pull_request'}
        and run.get('head_repository', {}).get('full_name') == repository
        and receipt.get('schemaVersion') == 1
        and receipt.get('repository') == repository
        and receipt.get('runID') == str(run.get('id'))
        and receipt.get('event') == run.get('event')
        and receipt.get('commit') == commit.get('sha')
        and receipt.get('tree') == tree == commit.get('tree', {}).get('sha')
        and receipt.get('workflowBlob') == workflow_blob
        and (receipt['commit'] == run.get('head_sha') or (
            run['event'] == 'pull_request'
            and run.get('head_sha') in {p.get('sha') for p in commit.get('parents', [])}
        ))
    )


def find(repository, tree, workflow_blob, read=api):
    workflow = read(f'repos/{repository}/actions/workflows/ci.yml')
    if workflow.get('path') != WORKFLOW:
        return None
    workflow_id = workflow['id']
    runs = read(f'repos/{repository}/actions/workflows/{workflow_id}/runs?status=completed&per_page=20')['workflow_runs']
    for run in runs:
        if (run.get('workflow_id') != workflow_id or run.get('conclusion') != 'success'
                or run.get('event') not in {'push', 'pull_request'}
                or run.get('head_repository', {}).get('full_name') != repository):
            continue
        artifacts = read(f'repos/{repository}/actions/runs/{run["id"]}/artifacts?per_page=100')['artifacts']
        candidates = [a for a in artifacts if a.get('name') == ARTIFACT and not a.get('expired')]
        if len(candidates) != 1 or not 0 < candidates[0].get('size_in_bytes', 0) <= 65_536:
            continue
        receipt = unpack(read(f'repos/{repository}/actions/artifacts/{candidates[0]["id"]}/zip', binary=True))
        if not re.fullmatch(r'[a-f0-9]{40}', str(receipt.get('commit', ''))):
            continue
        commit = read(f'repos/{repository}/git/commits/{receipt["commit"]}')
        if matches(receipt, run, commit, repository, tree, workflow_blob):
            return receipt
    return None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('mode', choices=['record', 'find'])
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    repository = os.environ['GITHUB_REPOSITORY']
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repository):
        raise ValueError('Unexpected repository')
    tree = git('rev-parse', 'HEAD^{tree}')
    workflow_blob = git('rev-parse', 'HEAD:' + WORKFLOW)
    dirty = bool(git('status', '--porcelain', '--untracked-files=no'))
    if args.mode == 'record':
        if os.environ.get('GITHUB_ACTIONS') != 'true' or args.output is None or dirty:
            raise ValueError('Record only after the full CI steps')
        receipt = dict(schemaVersion=1, repository=repository, runID=os.environ['GITHUB_RUN_ID'],
                       event=os.environ['GITHUB_EVENT_NAME'], commit=git('rev-parse', 'HEAD'),
                       tree=tree, workflowBlob=workflow_blob)
        args.output.mkdir(parents=True, exist_ok=True)
        (args.output / RECEIPT).write_text(json.dumps(receipt, indent=2) + '\n')
        print('Recorded complete-tree CI verification')
        return
    try:
        receipt = None if dirty else find(repository, tree, workflow_blob)
    except (subprocess.SubprocessError, OSError, ValueError, KeyError, TypeError, AttributeError, zipfile.BadZipFile):
        receipt = None
    if os.environ.get('GITHUB_OUTPUT'):
        with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
            output.write('reused=' + str(receipt is not None).lower() + '\n')
    if receipt:
        print('Reusing full tests and bundle audit from CI run ' + receipt['runID'] + ' for identical tree ' + tree)
    else:
        print('No matching successful verification; running full tests')


if __name__ == '__main__':
    main()
