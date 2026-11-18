import hashlib,json,plistlib,subprocess,sys
from pathlib import Path
app=Path(sys.argv[1]); fw=app/'Frameworks/Poki.framework'
assert app.is_dir() and (fw/'Poki').is_file()
info=plistlib.loads((app/'Info.plist').read_bytes())
assert info['CFBundleIdentifier']=='com.openAmroe.app'
assert info['CFBundleShortVersionString']=='1.32' and info['CFBundleVersion']=='32'
assert (app/'agent-system.md').stat().st_size>100
assert (app/'PiSwift_PiSwiftAI.bundle/oauth-page.html').is_file()
assert (app/'PiSwift_PiSwiftAI.bundle/codex-instructions.md').is_file()
links=subprocess.check_output(['xcrun','otool','-L',str(fw/'Poki')],text=True)
for line in links.splitlines()[1:]:
 lib=line.strip().split(' (')[0]
 if lib.startswith('@rpath/') and '.framework/' in lib:
  part=lib.removeprefix('@rpath/').split('.framework/')[0]+'.framework'
  assert (app/'Frameworks'/part).is_dir(),f'missing linked dependency {part}'
exports=subprocess.check_output(['xcrun','nm','-gU',str(fw/'Poki')],text=True)
assert 'AmorePokiEntry' in exports
for item in (app/'Frameworks').glob('*.framework'):
 exe=plistlib.loads((item/'Info.plist').read_bytes()).get('CFBundleExecutable',item.stem)
 if (item/exe).is_file():
  subprocess.run(['codesign','--force','--sign','-','--timestamp=none',str(item)],check=True)
  subprocess.run(['codesign','--verify','--strict',str(item)],check=True)
print(json.dumps({'bundle':info['CFBundleIdentifier'],'version':'1.32','framework':str(fw),'resources':'verified','embedded_framework_signatures':'ad-hoc verified'},indent=2))
