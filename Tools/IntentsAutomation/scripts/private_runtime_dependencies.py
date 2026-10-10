"""Authenticate every installed dependency byte against locked npm archives."""
import base64
import hashlib
import io
import json
from pathlib import PurePosixPath
import tarfile

from apply_private_sdk_lifecycle_patch import regular, sha


def archive_files(cache, integrity, identity=None):
    algorithm, encoded = integrity.split('-', 1)
    digest = base64.b64decode(encoded, validate=True)
    if algorithm != 'sha512' or len(digest) != 64:
        raise ValueError('Unsupported dependency integrity')
    key = digest.hex()
    raw = regular(cache / 'content-v2/sha512' / key[:2] / key[2:4] / key[4:], 64 * 1024 * 1024)
    if hashlib.sha512(raw).digest() != digest:
        raise ValueError('Dependency archive integrity differs')
    result = {}; total = 0; seen = set(); archive_root = None; manifest = None
    with tarfile.open(fileobj=io.BytesIO(raw), mode='r:gz') as archive:
        for index, member in enumerate(archive, 1):
            name = member.name.rstrip('/')
            path = PurePosixPath(name)
            if (index > 40000 or name in seen or path.is_absolute() or path.as_posix() != name
                    or '..' in path.parts or '\0' in name or len(path.parts) > 32
                    or not path.parts):
                raise ValueError('Unsafe dependency archive path')
            if archive_root is None:
                archive_root = path.parts[0]
            if path.parts[0] != archive_root:
                raise ValueError('Multiple dependency archive roots')
            seen.add(name)
            if member.isdir():
                continue
            if not member.isfile() or len(path.parts) < 2 or member.size > 128 * 1024 * 1024:
                raise ValueError('Unsafe dependency archive member')
            total += member.size
            if total > 256 * 1024 * 1024:
                raise ValueError('Dependency archive exceeds bound')
            data = archive.extractfile(member).read(member.size + 1)
            if len(data) != member.size:
                raise ValueError('Incomplete dependency archive member')
            result['/'.join(path.parts[1:])] = sha(data)
            if path.parts[1:] == ('package.json',):
                manifest = json.loads(data)
    if identity is not None and (manifest is None or
            (manifest.get('name'), manifest.get('version')) != identity):
        raise ValueError('Dependency archive identity differs from lock')
    return result


def platform_matches(values, selected):
    return not values or (('any' in values or selected in values or all(v.startswith('!') for v in values))
                          and '!' + selected not in values)


def reviewed_patches(lock):
    sdk = lock['packages']['agent-device']['lifecyclePatch']
    e2e = lock['packages']['e2e']['actionBudgetPatch']
    sdk_receipt = {
        'schemaVersion': 1, 'package': 'agent-device', 'version': '0.21.20',
        'patchVersion': sdk['id'], 'originalSHA256': sdk['originalSourceSHA256'],
        'patchedSHA256': sdk['patchedSourceSHA256'], 'helperSHA256': sdk['helperSHA256'],
        'closeOriginalSHA256': sdk['closeOriginalSourceSHA256'], 'closePatchedSHA256': sdk['closePatchedSourceSHA256'],
        'clientOriginalSHA256': sdk['clientOriginalSourceSHA256'], 'clientPatchedSHA256': sdk['clientPatchedSourceSHA256'],
        'license': 'MIT', 'source': 'Published agent-device 0.21.20 dist/src/runner-disposal.js; existing owner-lock disposal seam'}
    e2e_receipt = {
        'schemaVersion': 1, 'package': 'e2e', 'version': '0.17.0', 'patchVersion': e2e['id'],
        'originalSHA256': e2e['originalSourceSHA256'], 'patchedSHA256': e2e['patchedSourceSHA256'],
        'maximumTargetedActionMilliseconds': 120000, 'license': 'Apache-2.0',
        'source': 'Published e2e 0.17.0 dist/agent/step-accounting.js; actionOperation retains config and step deadline bounds'}
    return {
        'node_modules/agent-device': {
            'dist/src/runner-disposal.js': sdk['patchedSourceSHA256'],
            'dist/src/session2.js': sdk['closePatchedSourceSHA256'],
            'dist/src/runner-client.js': sdk['clientPatchedSourceSHA256'],
            'dist/src/intents-owned-runner-disposal.mjs': sdk['helperSHA256'],
            'intents-lifecycle-patch.json': sha((json.dumps(sdk_receipt, indent=2) + '\n').encode())},
        'node_modules/e2e': {
            'dist/agent/step-accounting.js': e2e['patchedSourceSHA256'],
            'intents-action-budget-patch.json': sha((json.dumps(e2e_receipt, indent=2) + '\n').encode())}}


def verify(root, cache, actual):
    packages = json.loads(regular(root / 'package-lock.json'))['packages']
    patches = reviewed_patches(json.loads(regular(root / 'dependencies.lock.json')))
    expected = {}
    for name, metadata in packages.items():
        if not name.startswith('node_modules/') or metadata.get('dev'):
            continue
        path = PurePosixPath(name)
        if path.as_posix() != name or '..' in path.parts or len(path.parts) > 32:
            raise ValueError('Unsafe locked package path')
        # This frozen runtime contains the pinned Darwin arm64 Node payload. Require
        # all production packages and optional native assets eligible for that target.
        eligible = platform_matches(metadata.get('os'), 'darwin') and platform_matches(metadata.get('cpu'), 'arm64')
        if not eligible and metadata.get('optional'):
            continue
        if not (root / name / 'package.json').is_file():
            raise ValueError('Missing locked production dependency: ' + name)
        package_name = name.rsplit('node_modules/', 1)[1]
        files = archive_files(cache, metadata['integrity'], (package_name, metadata['version']))
        files.update(patches.get(name, {}))
        for relative, digest in files.items():
            full = name + '/' + relative
            if full in expected:
                raise ValueError('Overlapping dependency archive files')
            expected[full] = digest
    installed = {name: digest for name, digest in actual.items() if name.startswith('node_modules/')}
    if installed != expected:
        missing = sorted(set(expected) - set(installed))[:3]
        extra = sorted(set(installed) - set(expected))[:3]
        changed = [name for name in expected.keys() & installed.keys() if expected[name] != installed[name]][:3]
        raise ValueError(f'Dependency archive bytes differ: missing={missing}, extra={extra}, changed={changed}')
