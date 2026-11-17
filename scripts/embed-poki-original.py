from pathlib import Path
import sys,shutil,plistlib,json,subprocess
app=Path(sys.argv[1]);products=Path(sys.argv[2]);framework=products/'Poki.framework'
if not (framework/'Poki').is_file():raise SystemExit('Original Poki.framework missing; IPA packaging refused')
frameworks=app/'Frameworks';frameworks.mkdir(exist_ok=True)
for name in ['Poki.framework','WebRTC.framework']:
 source=products/name
 if not source.exists():
  if name=='WebRTC.framework':continue
  raise SystemExit('Missing '+name)
 shutil.copytree(source,frameworks/name,dirs_exist_ok=True,symlinks=True)
# Do not replace Amore's own Localizable values on shared keys.
for language in framework.glob('*.lproj'):
 dest=app/language.name;dest.mkdir(exist_ok=True)
 for source in language.iterdir():
  if source.suffix=='.strings':
   target=dest/source.name
   values=plistlib.loads(source.read_bytes())
   if target.exists():values.update(plistlib.loads(target.read_bytes()))
   target.write_bytes(plistlib.dumps(values,fmt=plistlib.FMT_BINARY))
  elif source.is_file() and not (dest/source.name).exists():shutil.copyfile(source,dest/source.name)
# AppIconStore's upstream catalogue uses plain resource names, not assets.
for source in (products/'Poki.framework').glob('*.png'):
 if not (app/source.name).exists():shutil.copyfile(source,app/source.name)
info=plistlib.loads((framework/'Info.plist').read_bytes())
assert info['CFBundleExecutable']=='Poki'
print('Original module embedded:',frameworks/'Poki.framework','minimum iOS',info.get('MinimumOSVersion'))
print('No strong Poki link is required by the iOS16 host; signatures must cover all embedded frameworks.')
