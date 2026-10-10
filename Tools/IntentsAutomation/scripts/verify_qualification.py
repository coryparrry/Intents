#!/usr/bin/env python3
"""Check saved report identities and hashes; this does not execute or qualify a route."""
import argparse, hashlib, json
from pathlib import Path

def verify(path: Path):
    profile = json.loads(path.read_text())
    expected = {'schemaVersion', 'profileID', 'targetID', 'appBundleID', 'productDigest', 'dependencyDigest', 'evidence'}
    if set(profile) != expected or profile['schemaVersion'] != 1: raise ValueError('Malformed qualification profile')
    dependencies = Path(__file__).resolve().parents[1] / 'dependencies.lock.json'
    if hashlib.sha256(dependencies.read_bytes()).hexdigest() != profile['dependencyDigest']: raise ValueError('Dependency identity changed')
    if not profile['evidence']: raise ValueError('Zero hardware checks executed')
    count = 0
    for record in profile['evidence']:
        if set(record) != {'path','sha256','gate'}: raise ValueError('Malformed evidence reference')
        relative = Path(record['path'])
        if relative.is_absolute() or '..' in relative.parts: raise ValueError('Invalid evidence path')
        candidate = path.parent / relative
        for component in [candidate, *candidate.parents]:
            if component == path.parent: break
            if component.is_symlink(): raise ValueError('Symlink evidence is forbidden')
        evidence = candidate.resolve()
        if not evidence.is_relative_to(path.parent.resolve()) or evidence.is_symlink(): raise ValueError('Evidence path escapes owned profile')
        raw = evidence.read_bytes()
        if hashlib.sha256(raw).hexdigest() != record['sha256']: raise ValueError('Evidence integrity mismatch')
        result = json.loads(raw)
        for key in ['targetID','appBundleID','productDigest','dependencyDigest']:
            if result.get(key) != profile[key]: raise ValueError('Evidence identity mismatch: ' + key)
        if result.get('gate') != record['gate'] or result.get('qualified') is not True or result.get('executedChecks',0) < 1:
            raise ValueError('Gate is not qualified by executed evidence: ' + record['gate'])
        if result.get('evidenceKind') != 'appleExecution': raise ValueError('Fakes do not qualify hardware')
        count += result['executedChecks']
    print(json.dumps({'profileID':profile['profileID'],'dependencyDigest':profile['dependencyDigest'],'executedChecks':count,'integrityChecked':True,'routeQualification':False}))

if __name__ == '__main__':
    p=argparse.ArgumentParser();p.add_argument('--profile',type=Path,required=True)
    try: verify(p.parse_args().profile)
    except (ValueError,OSError,KeyError) as e: p.exit(1,str(e)+'\n')
