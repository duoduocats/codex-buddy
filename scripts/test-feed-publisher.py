#!/usr/bin/env python3
"""Synthetic tests for the public publisher's path and provenance boundary."""
import importlib.util
import sys
sys.dont_write_bytecode = True
from pathlib import Path
import tempfile
spec = importlib.util.spec_from_file_location('publisher', Path(__file__).with_name('publish-tibo-feeds.py'))
publisher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publisher)
publisher.assert_paths(['announcements/messages.json'])
publisher.assert_paths(sorted(publisher.ALLOWED))
publisher.assert_message_scope(b'{"events":[{"id":"synthetic","type":"message","sourceURL":"https://x.com/thsottiaux/status/123456"}]}', None)
try:
    publisher.assert_message_scope(b'{"events":[{"id":"synthetic","type":"message","sourceURL":"https://x.com/other/status/123456"}]}', None)
    raise AssertionError('Unrelated author accepted')
except ValueError:
    pass
for paths in [[], ['Sources/main.swift'], ['announcements/messages.json','README.md'], ['../private.json']]:
    try:
        publisher.assert_paths(paths)
        raise AssertionError('Non-feed mutation accepted')
    except ValueError:
        pass
for origin in ['https://example.com/duoduocats/codex-buddy.git', 'https://github.com/other/repo.git']:
    try:
        publisher.assert_public_origin(origin)
        raise AssertionError('Untrusted origin accepted')
    except ValueError:
        pass
with tempfile.TemporaryDirectory() as tmp:
    directory = Path(tmp)
    (directory/'messages.json').write_text('{"synthetic":true}')
    assert set(publisher.candidates(directory)) == {'announcements/messages.json'}
    (directory/'messages.json').unlink()
    (directory/'messages.json').symlink_to(directory/'absent')
    try:
        publisher.candidates(directory)
        raise AssertionError('Symlink accepted')
    except ValueError:
        pass
print('Public publisher boundary checks passed')
