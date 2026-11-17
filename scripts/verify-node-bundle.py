from pathlib import Path
import hashlib,json,tarfile,struct,sys
root=Path(__file__).resolve().parents[1]
bundle=Path(sys.argv[1]) if len(sys.argv)>1 else root/'src/ios/NodeRuntime'
manifest=json.loads((bundle/'manifest.json').read_text())
assert manifest['architecture']=='aarch64' and manifest['alpineBranch']=='3.21'
packages=manifest['packages'];assert 2<=len(packages)<=64
assert len({p['filename'] for p in packages})==len(packages)
for p in packages:
 name=p['filename'];assert name==Path(name).name and name.endswith('.apk')
 data=(bundle/name).read_bytes();assert len(data)==p['bytes'],name
 assert hashlib.sha256(data).hexdigest()==p['sha256'],name
 assert p['architecture']=='aarch64'
 assert p['url'].startswith('https://dl-cdn.alpinelinux.org/alpine/v3.21/')
 assert p.get('license') and p.get('aportsCommit')
for line in (bundle/'SHA256SUMS').read_text().splitlines():
 digest,name=line.split('  ',1);assert name==Path(name).name and name!='SHA256SUMS'
 assert hashlib.sha256((bundle/name).read_bytes()).hexdigest()==digest,name
node=next(p for p in packages if p['name']=='nodejs')
with tarfile.open(bundle/node['filename'],'r:gz',ignore_zeros=True) as archive:
 entry=archive.getmember('usr/bin/node');assert entry.isfile()
 header=archive.extractfile(entry).read(64)
 assert header[:4]==b'\x7fELF' and header[4]==2 and header[5]==1
 assert struct.unpack_from('<H',header,18)[0]==183,'not AArch64 ELF'
 # Package signature verification is performed by apk in the ARM64 Linux job.
for repo in ['main','community']:
 with tarfile.open(bundle/(repo+'.APKINDEX.tar.gz'),'r:gz') as a:
  assert any(n.startswith('.SIGN.') for n in a.getnames()),'Unsigned repository index'
 expected={p['filename'] for p in packages if p['repository']==repo}
 assert set((bundle/(repo+'.packages')).read_text().splitlines())==expected
print('PASS:',len(packages),'APKs; SHA-256, signed index presence, full file list and AArch64 Node ELF verified')
print('Node:',manifest['nodeVersion'],'npm:',manifest['npmVersion'],'APK bytes:',sum(p['bytes'] for p in packages))
