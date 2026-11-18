from pathlib import Path
import sys,subprocess,json,hashlib
products,out,launcher=map(Path,sys.argv[1:]);primary=products/'AmoreDeviceKit.framework/AmoreDeviceKit'
assert primary.is_file()
def symbols(path):
 p=subprocess.run(['xcrun','nm','-gjU',str(path)],text=True,capture_output=True,check=True)
 return {s.strip() for s in p.stdout.splitlines() if s.strip() and not s.endswith(':')}
covered=symbols(primary);inputs=[primary];proof=[]
for file in sorted(list(products.glob('*.o'))+list(products.glob('*.a')))+[launcher]:
 if not file.is_file():continue
 defined=symbols(file);novel=defined-covered
 added=bool(novel)
 proof.append({'file':file.name,'sha256':hashlib.sha256(file.read_bytes()).hexdigest(),'new_symbols':len(novel),'included':added})
 if added:inputs.append(file);covered.update(defined)
combined=out/'AmoreDeviceKit-all.a'
subprocess.run(['xcrun','libtool','-static','-o',str(combined)]+[str(x) for x in inputs],check=True)
combined.replace(out/'AmoreDeviceKit.framework/AmoreDeviceKit')
(out/'static-link-inputs.json').write_text(json.dumps(proof,indent=2))
assert any('AmoreDeviceServices' in s for s in covered)
assert not any('OBJC_CLASS_$_AmorePokiEntry' in s for s in covered)
print('Merged',len(inputs),'static products; no separate application factory')
