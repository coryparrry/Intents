#!/usr/bin/env python3
"""Offline builder check of reviewed npm artifacts and installed public declarations."""
import argparse
import base64
import hashlib
import io
import json
import os
import re
import stat
import tarfile
from pathlib import Path


def read_file(root, relative, maximum=1_048_576):
    if not isinstance(relative, str) or Path(relative).is_absolute() or '..' in Path(relative).parts:
        raise ValueError('Unsafe provenance path')
    path = root / relative
    if path.resolve(strict=True) != path:
        raise ValueError('Aliased, missing or oversized provenance file')
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, 'rb') as source:
        before = os.fstat(source.fileno())
        if not stat.S_ISREG(before.st_mode) or before.st_size > maximum:
            raise ValueError('Nonregular or oversized provenance file')
        raw = source.read(maximum + 1)
        after = os.fstat(source.fileno())
        if len(raw) > maximum or len(raw) != before.st_size or any(getattr(before, field) != getattr(after, field) for field in ('st_dev', 'st_ino', 'st_mode', 'st_size', 'st_mtime_ns', 'st_ctime_ns')):
            raise ValueError('Provenance file changed while reading')
        return raw


def verify(root, archives=None):
    root = root.resolve(strict=True)
    lock = json.loads(read_file(root, 'dependencies.lock.json'))
    npm = json.loads(read_file(root, 'package-lock.json'))
    manifest = json.loads(read_file(root, 'package.json'))
    if lock.get('schemaVersion') != 1 or set(lock['packages']) != {'e2e', 'agent-device'}:
        raise ValueError('Unexpected dependency provenance schema')
    result = {}
    for name, pin in lock['packages'].items():
        installed_lock = npm['packages']['node_modules/' + name]
        if manifest['dependencies'].get(name) != pin['version'] or not re.fullmatch(r'\d+\.\d+\.\d+', pin['version']):
            raise ValueError('Direct dependency version is not the exact reviewed pin')
        for key in ('version', 'resolved', 'integrity'):
            if pin[key] != installed_lock.get(key):
                raise ValueError('Dependency locks disagree: ' + name + '/' + key)
        if pin['artifactKind'] != 'published-npm' or pin['runtimeArtifactKind'] != 'published-plus-intents-patches':
            raise ValueError('Patched runtime must distinguish published base provenance')
        evidence = pin['publicationEvidence']
        raw = read_file(root, evidence['metadataPath'], 262_144)
        if hashlib.sha256(raw).hexdigest() != evidence['metadataSHA256']:
            raise ValueError('Reviewed publication metadata changed')
        metadata = json.loads(raw)
        if metadata['name'] != name or metadata['version'] != pin['version'] or metadata['repository'] != pin['repository']:
            raise ValueError('Publication identity mismatch')
        if metadata['dist']['tarball'] != pin['resolved'] or metadata['dist']['integrity'] != pin['integrity']:
            raise ValueError('Publication archive does not match the exact locks')
        published = metadata.get('gitHead')
        if published != pin['publishedSourceRevision'] or not re.fullmatch(r'[a-f0-9]{40}', pin['referenceSourceRevision']):
            raise ValueError('Published and reference revisions must remain distinct and accurate')
        disposition = ('publishedGitHeadAbsent' if published is None else
                       'publishedRevisionMatchesDesign' if published == pin['referenceSourceRevision'] else
                       'publishedRevisionDiffersFromDesign')
        if published is not None and not re.fullmatch(r'[a-f0-9]{40}', published):
            raise ValueError('Invalid publication revision')
        if evidence['sourceCorrespondenceDisposition'] != disposition:
            raise ValueError('Source correspondence overstated')
        package_root = root / 'node_modules' / name
        installed = json.loads(read_file(package_root, 'package.json'))
        if any(installed.get(key) != metadata.get(key) for key in ('name', 'version', 'repository', 'exports', 'types', 'typesVersions', 'imports', 'main', 'type', 'bin', 'engines')):
            raise ValueError('Installed declaration package identity changed')
        declarations = evidence['declarationSHA256']
        if not isinstance(declarations, dict) or not 1 <= len(declarations) <= 512:
            raise ValueError('Declaration inventory is not bounded')
        total = 0
        for relative, digest in declarations.items():
            if not relative.startswith('dist/') or not relative.endswith('.d.ts') or not re.fullmatch(r'[a-f0-9]{64}', digest):
                raise ValueError('Invalid declaration inventory entry')
            content = read_file(package_root, relative)
            total += len(content)
            if total > 16_777_216 or hashlib.sha256(content).hexdigest() != digest:
                raise ValueError('Installed declarations differ from the pinned archive')
        exports = installed['exports']
        required = ('.', './engine', './agent') if name == 'e2e' else ('.', './contracts')
        for key in required:
            if exports[key]['types'].removeprefix('./') not in declarations:
                raise ValueError('Required public entry point is not archive-bound')
        if archives is not None:
            archive = archives / (name + '-' + pin['version'] + '.tgz')
            raw_archive = read_file(archives, archive.name, 67_108_864)
            sri = 'sha512-' + base64.b64encode(hashlib.sha512(raw_archive).digest()).decode()
            if sri != pin['integrity'] or hashlib.sha256(raw_archive).hexdigest() != evidence['tarballSHA256']:
                raise ValueError('Archive integrity mismatch')
            actual = {}
            entries = 0
            expanded_bytes = 0
            with tarfile.open(fileobj=io.BytesIO(raw_archive), mode='r:gz') as tar:
                for item in tar:
                    entries += 1
                    expanded_bytes += item.size
                    if entries > 10_000 or item.size < 0 or expanded_bytes > 134_217_728:
                        raise ValueError('Archive expansion exceeds inventory budget')
                    if item.name.startswith('package/dist/') and item.name.endswith('.d.ts'):
                        if not item.isfile() or item.size > 1_048_576 or len(actual) >= 512:
                            raise ValueError('Invalid archived declaration')
                        relative = item.name.removeprefix('package/')
                        if relative in actual or '..' in Path(relative).parts:
                            raise ValueError('Duplicate or unsafe archived declaration')
                        actual[relative] = hashlib.sha256(tar.extractfile(item).read()).hexdigest()
            if actual != declarations:
                raise ValueError('Archive declaration inventory mismatch')
        result[name] = {'version': pin['version'], 'declarationsVerified': len(declarations),
                        'sourceCorrespondence': disposition, 'archiveBytesVerified': archives is not None}
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument('--archives', type=Path)
    args = parser.parse_args()
    try:
        print(json.dumps(verify(args.root, args.archives.resolve(strict=True) if args.archives else None), sort_keys=True))
    except (ValueError, KeyError, TypeError, OSError, json.JSONDecodeError, tarfile.TarError) as error:
        parser.exit(1, 'Dependency provenance verification failed: ' + str(error) + '\n')


if __name__ == '__main__':
    main()
