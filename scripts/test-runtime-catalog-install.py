#!/usr/bin/env python3
"""Ubuntu disposable CI only: installs production AOJIT catalog packages in
fresh Alpine/aarch64. Never run against the user's Minis/iSH rootfs. Package
installation and file-family matches DO NOT prove iPhone AOJIT acceleration.
"""
import argparse,fnmatch,hashlib,json,os,platform,posixpath,re,shutil,struct,subprocess,tempfile,time
from pathlib import Path
REPO=Path(__file__).resolve().parents[1]
def run(cmd,timeout=120):
 return subprocess.run(cmd,text=True,capture_output=True,timeout=timeout)
def catalog():
 text=(REPO/'src/ios/Views/Rootfs/AOJITSettingsView.swift').read_text()
 body=text.split('static let catalog: [AOJITImage] = [',1)[1].split('\n    ]',1)[0]
 rows=[]
 for block in body.split('AOJITImage(')[1:]:
  def field(key):
   m=re.search(r'\b'+key+r':\s*"([^"]*)"',block);return m.group(1) if m else None
  rows.append(dict(name=field('name'),module=field('module'),recorded_build_id=field('buildId'),recorded_package=field('package'),family=field('family'),apk_spec=field('apkSpec')))
 assert len(rows)>=20 and all(e['name'] and e['module'] and e['recorded_build_id'] and e['family'] for e in rows)
 return rows
def module_bytes(root,path):
 seen=set()
 for _ in range(16):
  path=posixpath.normpath('/'+path.lstrip('/'));p=root/path.lstrip('/')
  if path in seen:return None,None
  seen.add(path)
  if p.is_symlink():
   target=os.readlink(p);path=target if target.startswith('/') else posixpath.join(posixpath.dirname(path),target);continue
  if p.is_file():return p.read_bytes(),path
  return None,None
 return None,None
def build_id(data):
 if not data or data[:6]!=b'\x7fELF\x02\x01':return None
 try:
  off=struct.unpack_from('<Q',data,32)[0];size,count=struct.unpack_from('<HH',data,54)
  for i in range(count):
   ph=off+i*size
   if struct.unpack_from('<I',data,ph)[0]!=4:continue
   start=struct.unpack_from('<Q',data,ph+8)[0];length=struct.unpack_from('<Q',data,ph+32)[0];end=min(start+length,len(data))
   while start+12<=end:
    ns,ds,typ=struct.unpack_from('<III',data,start);start+=12;name=data[start:start+ns];start+=(ns+3)&~3;desc=data[start:start+ds];start+=(ds+3)&~3
    if typ==3 and name.rstrip(b'\0')==b'GNU':return desc.hex()
 except (struct.error,OverflowError):return None
 return None
def inspect(root,row):
 data,path=module_bytes(root,row['module']);actual=build_id(data)
 return dict(module_present=bool(data),resolved_path=path,elf_aarch64=bool(data and data[:4]==b'\x7fELF' and len(data)>20 and struct.unpack_from('<H',data,18)[0]==183),actual_build_id=actual,exact_ELF_build_id_matches=bool(actual and actual==row['recorded_build_id']),family_filename_matches=bool(path and fnmatch.fnmatchcase(posixpath.basename(path),row['family'])))
def main():
 parser=argparse.ArgumentParser();parser.add_argument('--output',required=True);args=parser.parse_args()
 if platform.system()!='Linux' or 'RUNNER_TEMP' not in os.environ or 'ubuntu' not in Path('/etc/os-release').read_text().lower():raise SystemExit('Refusing: disposable Ubuntu CI with RUNNER_TEMP required; never Minis/iSH')
 qemu=shutil.which('qemu-aarch64-static');binfmt=Path('/proc/sys/fs/binfmt_misc/qemu-aarch64')
 assert qemu and binfmt.exists() and 'enabled' in binfmt.read_text(),'aarch64 binfmt missing'
 assert run(['sudo','-n','true']).returncode==0
 out=Path(args.output).resolve();out.mkdir(parents=True,exist_ok=True)
 work=Path(tempfile.mkdtemp(prefix='amore-runtime-ci-',dir=os.environ['RUNNER_TEMP']));root=work/'root';root.mkdir();rows=catalog();report={'scope':'Fresh Alpine3.21 aarch64 QEMU, NOT iSH/iPhone performance','production_catalog_entries':len(rows),'device_app_test':False,'AOJIT_runtime_performance_test':False}
 def shell(name,body,timeout=600):
  r=run(['sudo','-n','chroot',str(root),'/usr/bin/qemu-aarch64-static','/bin/sh','-ec',body],timeout)
  (out/(name+'.log')).write_text(r.stdout+'\n'+r.stderr)
  return r
 try:
  url='https://dl-cdn.alpinelinux.org/alpine/v3.21/releases/aarch64/alpine-minirootfs-3.21.0-aarch64.tar.gz';archive=work/'rootfs.tar.gz'
  for suffix,dest in [('',archive),('.sha256',work/'sha256')]:
   r=run(['curl','-fsSL','--retry','2','--connect-timeout','15','--max-time','180',url+suffix,'-o',str(dest)],600);assert r.returncode==0,r.stderr
  expected=(work/'sha256').read_text().split()[0];assert hashlib.sha256(archive.read_bytes()).hexdigest()==expected;report['rootfs_sha256']=expected
  r=run(['sudo','-n','tar','-xzf',str(archive),'-C',str(root)]);assert r.returncode==0,r.stderr
  for src,dst in [(qemu,root/'usr/bin/qemu-aarch64-static'),('/etc/resolv.conf',root/'etc/resolv.conf')]:assert run(['sudo','-n','cp','--remove-destination',src,str(dst)]).returncode==0
  for name,major,minor in [('null','1','3'),('random','1','8'),('urandom','1','9')]:
   r=run(['sudo','-n','mknod','-m','666',str(root/'dev'/name),'c',major,minor]);assert r.returncode==0 or 'File exists' in r.stderr
  report['bundled_modules_before_install']=[dict(row,**inspect(root,row)) for row in rows if not row['apk_spec']]
  r=shell('apk-update','set -eu\napk update',300);assert r.returncode==0,'Official APK metadata failed'
  pins=sorted({r['apk_spec'] for r in rows if r['apk_spec']});pin_results={}
  for index,spec in enumerate(pins):
   r=shell('pin-'+str(index),'apk add --simulate '+spec,180);pin_results[spec]={'available':r.returncode==0,'exit_code':r.returncode}
  report['pinned_package_availability']=pin_results
  packages=sorted({spec.split('=')[0] for spec in pins}|{'npm','py3-pip','pcre2-tools'})
  r=shell('install-current','set -eu\napk add --no-cache '+' '.join(packages)+'\napk info -v',900);report['current_packages']=packages;report['current_install_success']=r.returncode==0
  if r.returncode:raise RuntimeError('Current packages failed: '+r.stderr[-1200:])
  py_smoke = '''import io,json,hashlib,struct,datetime,binascii,math,zlib,socket,select,ssl,sqlite3,ctypes,bz2,lzma,readline,curses
import numpy as np
from PIL import Image,features
assert json.loads(json.dumps({'a':1}))['a']==1
assert hashlib.sha256(b'amore').hexdigest()==hashlib.sha256(b'amore').hexdigest()
assert len(hashlib.blake2b(b'x').digest())==64
assert struct.unpack('<I',struct.pack('<I',42))[0]==42
assert datetime.datetime(2026,1,1).year==2026
assert binascii.unhexlify(b'6162')==b'ab'
assert math.isclose(math.sqrt(9),3)
assert zlib.decompress(zlib.compress(b'amore'))==b'amore'
assert bz2.decompress(bz2.compress(b'amore'))==b'amore'
assert lzma.decompress(lzma.compress(b'amore'))==b'amore'
left,right=socket.socketpair();left.send(b'x');assert select.select([right],[],[],1)[0];assert right.recv(1)==b'x';left.close();right.close()
assert ssl.create_default_context().check_hostname
connection=sqlite3.connect(':memory:');assert connection.execute('select 42').fetchone()[0]==42
assert int(np.arange(5).sum())==10
assert features.check('webp') and features.check('jpg')
image=Image.new('RGB',(8,8),'blue')
for format in ['PNG','JPEG','WEBP']:
 buffer=io.BytesIO();image.save(buffer,format=format);buffer.seek(0);assert Image.open(buffer).size==(8,8)
assert ctypes.CDLL('libpcre2-8.so.0') is not None
print('AMORE_PYTHON_NATIVE_MODULES_OK')
'''
  shell_body="python3 - <<'PY'\n"+py_smoke+"PY\n"
  shell_body+='node --version\nnpm --version\nnpx --version\n'
  shell_body+='node -e '+repr("const a=require('assert/strict'); a.equal(require('crypto').createHash('sha256').update('amore').digest('hex').length,64); a.equal(require('zlib').inflateSync(require('zlib').deflateSync('amore')).toString(),'amore'); console.log('AMORE_NODE_OK');")+'\n'
  shell_body+='ssh -V\nset +e\nscp -h > /tmp/scp-usage.log 2>&1\nscp_code=$?\nset -e\ntest "$scp_code" -eq 1\ngrep -qi usage /tmp/scp-usage.log\nprintf "amore\\n" | pcre2grep "^amore$"\n/bin/busybox true\necho AMORE_RUNTIME_CATALOG_OK\n'
  result=shell('runtime-smoke','set -eu\n'+shell_body,600)
  report['runtime_smoke_pass']=result.returncode==0 and 'AMORE_RUNTIME_CATALOG_OK' in result.stdout
  report['runtime_smoke_exit_code']=result.returncode
  modules=[]
  for row in rows:
   item=dict(row,**inspect(root,row));item['pinned_available']=pin_results.get(row['apk_spec'],{}).get('available') if row['apk_spec'] else None
   item['runtime_smoke_pass']=report['runtime_smoke_pass'];item['exact_match_is_not_runtime_performance_test']=True;modules.append(item)
  report['modules_after_install']=modules
  report['all_modules_present']=all(e['module_present'] and e['elf_aarch64'] for e in modules)
  report['exact_build_id_matches']=sum(e['exact_ELF_build_id_matches'] for e in modules)
  report['family_matches']=sum(e['family_filename_matches'] for e in modules)
  report['success']=report['current_install_success'] and report['runtime_smoke_pass'] and report['all_modules_present']
 except Exception as error:
  report['success']=False;report['error']=str(error)
 finally:
  (out/'runtime-installation-results.json').write_text(json.dumps(report,indent=2))
  run(['sudo','-n','rm','-rf','--',str(root)],120)
  shutil.rmtree(work,ignore_errors=True)
 print(json.dumps({k:v for k,v in report.items() if k not in ['modules_after_install','bundled_modules_before_install']},indent=2),flush=True)
 raise SystemExit(0 if report.get('success') else 1)
if __name__=='__main__':main()
