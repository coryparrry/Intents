from pathlib import Path
import hashlib
import json
root=Path(__file__).resolve().parent.parent/'AppEngine'
manifest=json.loads((root/'provenance.json').read_text())
files={entry['bundled']:entry for entry in manifest['files']}
assert set(files)=={source.name for source in root.glob('*.swift')}
for name,entry in files.items():
    assert hashlib.sha256((root/name).read_bytes()).hexdigest()==entry['bundledSHA256'], name
    if entry.get('source'): assert len(entry['sha256'])==64
print(f'Bundled app engine provenance: {len(files)} source hashes passed')
