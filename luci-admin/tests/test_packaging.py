import hashlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch

SOURCE = Path(__file__).resolve().parents[1]


def module(name):
    spec = importlib.util.spec_from_file_location(name, SOURCE / (name + '.py'))
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


build, manage = module('build'), module('manage')


def ipk(member):
    data, package = io.BytesIO(), io.BytesIO()
    with tarfile.open(fileobj=data, mode='w:gz') as tar:
        tar.addfile(member)
    with tarfile.open(fileobj=package, mode='w:gz') as tar:
        entry = tarfile.TarInfo('./data.tar.gz')
        entry.size = len(data.getvalue())
        tar.addfile(entry, io.BytesIO(data.getvalue()))
    return package.getvalue()


class BuildTests(unittest.TestCase):
    def test_corrupt_cached_package_is_rejected(self):
        with tempfile.TemporaryDirectory() as name:
            cache = Path(name)
            (cache / 'test.ipk').write_bytes(b'corrupt')
            record = {'Package':'test','Filename':'test.ipk','SHA256sum':hashlib.sha256(b'expected').hexdigest()}
            with self.assertRaisesRegex(RuntimeError, 'checksum mismatch'):
                build.fetch_package(record, cache, offline=True)
            self.assertEqual((cache / 'test.ipk').read_bytes(), b'corrupt')

    def test_missing_offline_package_does_not_download(self):
        with tempfile.TemporaryDirectory() as name, patch.object(build.urllib.request, 'urlopen') as fetch:
            with self.assertRaisesRegex(RuntimeError, 'Missing cached'):
                build.fetch_package({'Package':'test','Filename':'test.ipk'}, Path(name), True)
            fetch.assert_not_called()

    def test_tar_traversal_and_external_symlink_are_rejected(self):
        for member in [tarfile.TarInfo('../../outside'), tarfile.TarInfo('unsafe-link')]:
            if member.name == 'unsafe-link':
                member.type = tarfile.SYMTYPE
                member.linkname = '/etc/shadow'
            with self.subTest(member=member.name), tempfile.TemporaryDirectory() as name:
                with self.assertRaises(tarfile.FilterError):
                    build.unpack(ipk(member), Path(name))

    def test_archive_metadata_is_reproducible(self):
        with tempfile.TemporaryDirectory() as name:
            root = Path(name); bundle = root / 'bundle'; bundle.mkdir()
            (bundle / 'file').write_text('original integration')
            build.tar_bundle(bundle, root / 'one.tar.gz')
            (bundle / 'file').touch()
            build.tar_bundle(bundle, root / 'two.tar.gz')
            self.assertEqual((root / 'one.tar.gz').read_bytes(), (root / 'two.tar.gz').read_bytes())
            with tarfile.open(root / 'one.tar.gz') as archive:
                self.assertEqual(archive.getmember('file').uid, 0)

    def test_changed_upstream_context_is_rejected(self):
        for source in ['no matching context', 'old old']:
            with self.assertRaises(RuntimeError):
                build.checked_replace(source, 'old', 'new')

    def test_lock_is_official_and_pinned(self):
        records = json.loads((SOURCE / 'packages.lock.json').read_text())
        self.assertEqual(len({r['Package'] for r in records}), 9)
        for record in records:
            self.assertTrue(record['url'].startswith('https://downloads.openwrt.org/releases/23.05.4/'))
            self.assertRegex(record['SHA256sum'], r'^[a-f0-9]{64}$')


class ManagementTests(unittest.TestCase):
    def test_vendor_exit_wrapper_handles_output_without_newline(self):
        def fake_adb(action, command):
            self.assertEqual(action, 'shell')
            return subprocess.run(['sh','-c',command], capture_output=True)
        with patch.object(manage, 'adb', fake_adb):
            self.assertEqual(manage.shell('printf 200'), '200')
            with self.assertRaises(RuntimeError):
                manage.shell('printf misleading-output; false')

    def test_session_revocation_preserves_other_accounts(self):
        sessions = ''.join(json.dumps(s) for s in [
            {'ubus_rpc_session':'one','data':{'username':'luci'}},
            {'ubus_rpc_session':'two','data':{'username':'root'}},
            {'ubus_rpc_session':'three','data':{'username':'luci'}}])
        with patch.object(manage, 'rpc', side_effect=[sessions,'','']) as rpc:
            manage.destroy_sessions('luci')
        destroyed = [c.args[2]['ubus_rpc_session'] for c in rpc.call_args_list[1:]]
        self.assertEqual(destroyed, ['one','three'])

    def test_firmware_mismatch_stops_preflight(self):
        with patch.object(manage, 'shell', side_effect=['0','OTHER']) as shell:
            with self.assertRaisesRegex(RuntimeError, 'B22'):
                manage.preflight()
        self.assertEqual(shell.call_count, 2)

    def test_boot_hook_is_idempotent_and_preserves_other_commands(self):
        original = b'#!/bin/sh\necho other-component\nexit 0\n'
        with tempfile.TemporaryDirectory() as name, patch.object(manage, 'PRIVATE', Path(name)), \
             patch.object(manage, 'adb', return_value=subprocess.CompletedProcess([],0,original)), \
             patch.object(manage, 'push'), patch.object(manage, 'shell'):
            manage.boot_hook(True)
            written = (Path(name) / 'rc.local.generated').read_bytes()
            self.assertIn(b'echo other-component\n', written)
            self.assertEqual(written.count(b'# BEGIN LUCI_READONLY'), 1)
            with patch.object(manage, 'adb', return_value=subprocess.CompletedProcess([],0,written)), patch.object(manage, 'push') as push:
                manage.boot_hook(True)
                push.assert_not_called()

    def test_malformed_boot_markers_do_not_write(self):
        original = b'#!/bin/sh\n# BEGIN LUCI_READONLY\nexit 0\n'
        with patch.object(manage, 'adb', return_value=subprocess.CompletedProcess([],0,original)), patch.object(manage, 'push') as push:
            with self.assertRaisesRegex(RuntimeError, 'markers'):
                manage.boot_hook(True)
            push.assert_not_called()


if __name__ == '__main__':
    unittest.main()
