from pathlib import Path
import sys,json,subprocess,plistlib,shutil,hashlib
app,kit=map(Path,sys.argv[1:]);info=plistlib.loads((app/'Info.plist').read_bytes());assert info['CFBundleIdentifier']=='com.openAmroe.app';assert info['CFBundleShortVersionString']=='1.33' and info['CFBundleVersion']=='33'
assert not (app/'Frameworks/Poki.framework').exists()
assert not (app/'Frameworks/AmoreDeviceKit.framework').exists(),'static library must not be embedded'
for p in (kit/'Resources').iterdir():
 dest=app/p.name
 if p.name.endswith('.lproj'):
  dest.mkdir(parents=True,exist_ok=True)
  for resource in p.iterdir():
   target=dest/resource.name
   if resource.suffix=='.strings' and target.exists():
    merged=plistlib.loads(resource.read_bytes());merged.update(plistlib.loads(target.read_bytes()))
    target.write_bytes(plistlib.dumps(merged,fmt=plistlib.FMT_BINARY))
   elif not target.exists():shutil.copyfile(resource,target)
 elif p.is_dir():shutil.copytree(p,dest,dirs_exist_ok=True)
 elif not dest.exists():shutil.copyfile(p,dest)
exe=app/info['CFBundleExecutable'];links=subprocess.check_output(['xcrun','otool','-L',str(exe)],text=True);assert 'Poki.framework' not in links and 'AmoreDeviceKit.framework' not in links
symbols=subprocess.check_output(['xcrun','nm',str(exe)],text=True)
symbols=subprocess.run(['xcrun','swift-demangle','--compact'],input=symbols,text=True,capture_output=True,check=True).stdout
assert 'AmorePokiEntry' not in symbols,'separate app factory must not be linked'
assert 'AmoreDeviceServices' in symbols,'device services must be part of Amore binary'
assert 'AIChatViewModel' in symbols,'original Amore agent must remain linked'
for framework in (app/'Frameworks').glob('*.framework'):
 subprocess.run(['codesign','--force','--sign','-','--timestamp=none',str(framework)],check=True)
 subprocess.run(['codesign','--verify','--strict',str(framework)],check=True)
manifest=json.loads((app/'NodeRuntime/manifest.json').read_text())
for entry in manifest['packages']:
 data=(app/'NodeRuntime'/entry['filename']).read_bytes();assert len(data)==entry['bytes'] and hashlib.sha256(data).hexdigest()==entry['sha256']
report={'bundle':info['CFBundleIdentifier'],'version':'1.33','build':'33','minimum_iOS':info['MinimumOSVersion'],'device_services':'statically linked into Amore','standalone_poki_framework':False,'separate_ui_factory':False,'Amore_original_agent':'linked','node_apks_verified':len(manifest['packages']),'signing':'frameworks ad-hoc; app requires user distribution signing'}
Path('fusion-verification.json').write_text(json.dumps(report,indent=2));print(json.dumps(report,indent=2))
