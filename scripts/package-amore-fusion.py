from pathlib import Path
import sys,json,subprocess,plistlib,shutil,hashlib
app,kit=map(Path,sys.argv[1:]);info=plistlib.loads((app/'Info.plist').read_bytes());assert info['CFBundleIdentifier']=='com.openAmroe.app';assert info['CFBundleShortVersionString']=='1.37' and info['CFBundleVersion']=='37'
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
extension=kit/'AmoreTunnel.appex'
assert extension.is_dir(),'Built-in local tunnel extension missing'
plugins=app/'PlugIns';plugins.mkdir(exist_ok=True)
shutil.copytree(extension,plugins/'AmoreTunnel.appex',dirs_exist_ok=True)
provider=plugins/'AmoreTunnel.appex'
pi=plistlib.loads((provider/'Info.plist').read_bytes())
assert pi['CFBundleIdentifier'].startswith(info['CFBundleIdentifier']+'.')
assert pi['NSExtension']['NSExtensionPointIdentifier']=='com.apple.networkextension.packet-tunnel'
assert pi['CFBundleShortVersionString']==info['CFBundleShortVersionString']
subprocess.run(['codesign','--force','--sign','-','--timestamp=none','--entitlements',str(kit/'AmoreTunnel.entitlements'),str(provider)],check=True)
subprocess.run(['codesign','--verify','--strict',str(provider)],check=True)
exe=app/info['CFBundleExecutable'];links=subprocess.check_output(['xcrun','otool','-L',str(exe)],text=True);assert 'Poki.framework' not in links and 'AmoreDeviceKit.framework' not in links
symbols=subprocess.check_output(['xcrun','nm',str(exe)],text=True)
symbols=subprocess.run(['xcrun','swift-demangle','--compact'],input=symbols,text=True,capture_output=True,check=True).stdout
assert 'AmorePokiEntry' not in symbols,'separate app factory must not be linked'
assert 'AmoreDeviceServices' in symbols,'device services must be part of Amore binary'
assert 'AIChatViewModel' in symbols,'original Amore agent must remain linked'
for framework in (app/'Frameworks').glob('*.framework'):
 subprocess.run(['codesign','--force','--sign','-','--timestamp=none',str(framework)],check=True)
 subprocess.run(['codesign','--verify','--strict',str(framework)],check=True)
assert not (app/'NodeRuntime').exists(), 'offline Node APKs must not be bundled'
assert not any(app.rglob('nodejs-*.apk'))
assert hashlib.sha256((app/'alpine-rootfs.zip').read_bytes()).hexdigest()=='84f8d8acff68a28a0773298f67b3bed29c726f67fdb8c0f1cab8f01991a952cf'
report={'bundle':info['CFBundleIdentifier'],'version':'1.37','build':'37','minimum_iOS':info['MinimumOSVersion'],'device_services':'statically linked into Amore','standalone_poki_framework':False,'separate_ui_factory':False,'Amore_original_agent':'linked','node_offline_bundled':False,'node_installation':'online_selected_alpine_mirror','built_in_tunnel':'AmoreTunnel.appex; real profile and iOS consent required','voice_call':'duplex STT + original Agent + TTS; live device acceptance required','signing':'frameworks ad-hoc; app requires user distribution signing'}
Path('fusion-verification.json').write_text(json.dumps(report,indent=2));print(json.dumps(report,indent=2))
