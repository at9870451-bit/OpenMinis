from pathlib import Path
import sys,subprocess,json,hashlib
products,out,launcher=map(Path,sys.argv[1:]);primary=products/'AmoreDeviceKit.framework/AmoreDeviceKit'
assert primary.is_file()
def symbols(path):
 p=subprocess.run(['xcrun','nm','-gjU',str(path)],text=True,capture_output=True,check=True)
 return {s.strip() for s in p.stdout.splitlines() if s.strip() and not s.endswith(':')}
covered=symbols(primary);inputs=[primary];proof=[]
for file in sorted(list(products.glob('*.o'))+list(products.glob('*.a'))):
 if not file.is_file():continue
 defined=symbols(file);novel=defined-covered
 added=bool(novel)
 proof.append({'file':file.name,'sha256':hashlib.sha256(file.read_bytes()).hexdigest(),'new_symbols':len(novel),'included':added})
 if added:inputs.append(file);covered.update(defined)
assert launcher.is_file()
inputs.append(launcher)
proof.append({'file':launcher.name,'sha256':hashlib.sha256(launcher.read_bytes()).hexdigest(),'included':True,'reason':'Rust C ABI archive linked once; no nm scan of Rust LLVM members'})
combined=out/'AmoreDeviceKit-all.a'
subprocess.run(['xcrun','libtool','-static','-o',str(combined)]+[str(x) for x in inputs],check=True)
combined.replace(out/'AmoreDeviceKit.framework/AmoreDeviceKit')
(out/'static-link-inputs.json').write_text(json.dumps(proof,indent=2))
demangled=subprocess.run(['xcrun','swift-demangle','--compact'],input='\n'.join(sorted(covered)),text=True,capture_output=True,check=True).stdout
(out/'static-swift-symbols.txt').write_text(demangled)
assert 'AmoreDeviceServices' in demangled, 'Device service missing from demangled Swift symbols'
assert not any('OBJC_CLASS_$_AmorePokiEntry' in s for s in covered)
print('Merged',len(inputs),'static products; no separate application factory')
