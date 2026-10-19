#!/usr/bin/env python3
"""Synthetic verification tests; no GitHub requests or credentials."""
import copy
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile

spec = importlib.util.spec_from_file_location('verification', Path(__file__).with_name('ci-verification.py'))
verification = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verification)
REPO = 'example/buddy'
SHA = 'a' * 40
TREE = 'b' * 40
BLOB = 'c' * 40
HEAD = 'd' * 40


def fixtures():
    receipt = dict(schemaVersion=1, repository=REPO, runID='12', event='pull_request',
                   commit=SHA, tree=TREE, workflowBlob=BLOB)
    run = dict(id=12, workflow_id=7, status='completed', conclusion='success', event='pull_request',
               head_sha=HEAD, head_repository=dict(full_name=REPO))
    commit = dict(sha=SHA, tree=dict(sha=TREE), parents=[dict(sha=HEAD)])
    return receipt, run, commit


def archive(receipt, name=verification.RECEIPT):
    output = io.BytesIO()
    with zipfile.ZipFile(output, 'w') as result:
        result.writestr(name, json.dumps(receipt))
    return output.getvalue()


class VerificationTests(unittest.TestCase):
    def test_api_failure_falls_back_to_full_tests(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / 'output'
            with patch.dict(os.environ, GITHUB_REPOSITORY=REPO, GITHUB_OUTPUT=str(output)), \
                 patch.object(sys, 'argv', ['ci-verification.py', 'find']), \
                 patch.object(verification, 'git', side_effect=lambda *args: '' if args[0] == 'status' else TREE), \
                 patch.object(verification, 'find', side_effect=subprocess.SubprocessError('Synthetic failure')):
                verification.main()
            self.assertEqual(output.read_text(), 'reused=false\n')

    def test_exact_tree_and_pr_merge_parent(self):
        receipt, run, commit = fixtures()
        self.assertTrue(verification.matches(receipt, run, commit, REPO, TREE, BLOB))
        run.update(event='push', head_sha=SHA)
        receipt['event'] = 'push'
        self.assertTrue(verification.matches(receipt, run, commit, REPO, TREE, BLOB))

    def test_rejects_changed_inputs_and_untrusted_runs(self):
        for section, key, value in [
            (0, 'schemaVersion', 2), (0, 'repository', 'other/buddy'), (0, 'runID', '13'),
            (0, 'event', 'push'), (0, 'commit', HEAD), (0, 'tree', HEAD), (0, 'workflowBlob', HEAD),
            (1, 'status', 'in_progress'), (1, 'conclusion', 'failure'), (1, 'event', 'workflow_dispatch'),
            (1, 'head_repository', dict(full_name='fork/buddy')), (1, 'head_sha', TREE),
            (2, 'tree', dict(sha=HEAD)), (2, 'parents', []),
        ]:
            with self.subTest(section=section, key=key):
                data = list(fixtures());data[section][key] = value
                self.assertFalse(verification.matches(*data, REPO, TREE, BLOB))

    def test_bounded_single_receipt(self):
        receipt, _, _ = fixtures()
        self.assertEqual(verification.unpack(archive(receipt)), receipt)
        for data in [archive([]), archive(receipt, '../verified-source.json'),
                     archive({'padding': 'x' * 9000}), b'x' * 65_537]:
            with self.assertRaises((ValueError, zipfile.BadZipFile)):
                verification.unpack(data)

    def test_discovery_checks_run_artifact_and_commit(self):
        receipt, run, commit = fixtures()
        artifact = dict(id=24, name=verification.ARTIFACT, expired=False, size_in_bytes=600)
        for failure in [None, 'tree', 'fork', 'failed', 'expired', 'duplicate', 'workflow']:
            with self.subTest(failure=failure):
                tested = copy.deepcopy(receipt);candidate = copy.deepcopy(run);item = copy.deepcopy(artifact)
                if failure == 'tree':tested['tree'] = HEAD
                if failure == 'fork':candidate['head_repository']['full_name'] = 'fork/buddy'
                if failure == 'failed':candidate['conclusion'] = 'failure'
                if failure == 'expired':item['expired'] = True
                calls = []
                def read(path, binary=False):
                    calls.append(path)
                    if path.endswith('/workflows/ci.yml'):
                        return dict(id=7, path='other.yml' if failure == 'workflow' else verification.WORKFLOW)
                    if '/workflows/7/runs?' in path:return dict(workflow_runs=[candidate])
                    if '/runs/12/artifacts?' in path:return dict(artifacts=[item, item] if failure == 'duplicate' else [item])
                    if path.endswith('/artifacts/24/zip'):return archive(tested)
                    if '/git/commits/' in path:return commit
                    raise AssertionError(path)
                result = verification.find(REPO, TREE, BLOB, read=read)
                self.assertEqual(result, receipt if failure is None else None)
                if failure in {'fork', 'failed', 'expired', 'duplicate', 'workflow'}:
                    self.assertFalse(any(path.endswith('/zip') for path in calls))


if __name__ == '__main__':
    unittest.main()
