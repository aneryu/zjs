"""Inflate upstream .z assets outside any measurement window; preserve originals."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import zlib

root = Path(sys.argv[1]).resolve()
# Validate source identity and tracked cleanliness before generating resources.
subprocess.run(['node',str(Path(__file__).with_name('inventory.mjs')),str(root)],stdout=subprocess.DEVNULL,check=True)
records=[]
for compressed in sorted(root.rglob('*.z')):
    target=compressed.with_suffix('')
    source=compressed.read_bytes()
    data=zlib.decompress(source)
    if target.exists() and target.read_bytes()!=data:
        raise RuntimeError(f'Refusing to overwrite different content: {target}')
    target.write_bytes(data)
    records.append(dict(source=str(compressed.relative_to(root)),target=str(target.relative_to(root)),compressedSha256=hashlib.sha256(source).hexdigest(),sha256=hashlib.sha256(data).hexdigest(),bytes=len(data)))
print(json.dumps(records,indent=2))
