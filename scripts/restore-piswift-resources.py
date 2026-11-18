import hashlib,plistlib,urllib.request
from pathlib import Path
import sys
app=Path(sys.argv[1]);out=app/'PiSwift_PiSwiftAI.bundle';out.mkdir(exist_ok=True)
base='https://raw.githubusercontent.com/xibbon/PiSwift/f8696524cf41ca0a7f42f5b230eafa443daececd/Sources/PiSwiftAI/Resources/'
files={'codex-instructions.md':'4d5c9dcb0370ea4ca938cb3f6e79bcde93478480','oauth-page.html':'cba78815374c8816c392ec7602e9ef42706624ae'}
for name,expected in files.items():
 target=out/name
 if target.exists():data=target.read_bytes()
 else:
  with urllib.request.urlopen(base+name,timeout=60) as response:data=response.read()
 actual=hashlib.sha1(b'blob '+str(len(data)).encode()+b'\0'+data).hexdigest()
 assert actual==expected,f'PiSwift pinned source blob mismatch {name}'
 target.write_bytes(data)
plist={'CFBundleIdentifier':'org.swiftpm.PiSwift.PiSwiftAI.resources','CFBundleName':'PiSwift_PiSwiftAI','CFBundleVersion':'1','CFBundlePackageType':'BNDL','CFBundleDevelopmentRegion':'en'}
(out/'Info.plist').write_bytes(plistlib.dumps(plist))
print('PiSwift resource bundle verified at pinned revision:',list(files))
