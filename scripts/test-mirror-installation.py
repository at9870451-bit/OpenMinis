#!/usr/bin/env python3
"""Opt-in Ubuntu CI only: every mirror gets a NEW Alpine chroot.
Prerequisites (workflow owner installs): python3 curl qemu-user-static
binfmt-support; enable qemu-aarch64 binfmt. Never run on Minis/iSH.
Run: RUNNER_TEMP=... python3 scripts/test-mirror-installation.py --output ...
No --allow-untrusted/--force, pip trusted-host, npm scripts, or host apk/npm.
"""
import argparse, concurrent.futures, hashlib, json, os, platform, re, shutil, subprocess, tempfile, time
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
def run(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)

def main():
    p = argparse.ArgumentParser(); p.add_argument('--output', required=True); p.add_argument('--workers', type=int, default=2); p.add_argument('--only', default='')
    a = p.parse_args()
    if platform.system() != 'Linux' or 'RUNNER_TEMP' not in os.environ or not Path('/etc/os-release').is_file() or 'ubuntu' not in Path('/etc/os-release').read_text().lower():
        raise SystemExit('Refusing: requires disposable Ubuntu CI and RUNNER_TEMP, never user rootfs')
    qemu = shutil.which('qemu-aarch64-static')
    binfmt = Path('/proc/sys/fs/binfmt_misc/qemu-aarch64')
    if not qemu or not binfmt.is_file() or 'enabled' not in binfmt.read_text():
        raise SystemExit('Install qemu-user-static + binfmt-support and enable qemu-aarch64 in CI first')
    if run(['sudo','-n','true']).returncode: raise SystemExit('CI needs noninteractive sudo')
    out = Path(a.output).resolve(); out.mkdir(parents=True, exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix='amore-mirror-ci-', dir=os.environ['RUNNER_TEMP']))
    name = 'alpine-minirootfs-3.21.0-aarch64.tar.gz'
    archive = work/name; official = 'https://dl-cdn.alpinelinux.org/alpine/v3.21/releases/aarch64/'+name
    for suffix, dest in [('',archive),('.sha256',work/'rootfs.sha256')]:
        r = run(['curl','-fsSL','--proto','=https','--proto-redir','=https','--retry','1','--connect-timeout','15','--max-time','180',official+suffix,'-o',str(dest)],timeout=380)
        if r.returncode: raise SystemExit('Rootfs bootstrap failed: '+r.stderr)
    expected = (work/'rootfs.sha256').read_text().split()[0]
    if hashlib.sha256(archive.read_bytes()).hexdigest() != expected: raise SystemExit('Rootfs SHA256 mismatch')
    src = (REPO/'src/ios/Views/Rootfs/MirrorSpeedTestView.swift').read_text(); mirrors=[]
    for cat in ['alpine','pip','npm']:
        block = src.split('private static let '+cat+'Mirrors:')[1].split('}()')[0]
        for mid, url in re.findall(r'm\("([^"]+)", "[^"]+", "([^"]+)"',block):
            if not a.only or cat+'.'+mid in a.only.split(','): mirrors.append((cat+'.'+mid,cat,url))
    def test(entry):
        mid,cat,url=entry; root=work/mid; root.mkdir(); commands=[]; started=time.time()
        result=dict(id=mid,category=cat,base_url=url,rootfs_sha256=expected,full_isolated_install=False,device_app_test=False)
        try:
            r=run(['sudo','-n','tar','-xzf',str(archive),'-C',str(root)],timeout=60)
            if r.returncode: raise RuntimeError(r.stderr)
            for host,target in [(qemu,root/'usr/bin/qemu-aarch64-static'),('/etc/resolv.conf',root/'etc/resolv.conf')]:
                r=run(['sudo','-n','cp','--remove-destination',host,str(target)],timeout=10)
                if r.returncode: raise RuntimeError(r.stderr)
            for dev,major,minor in [('null','1','3'),('urandom','1','9'),('random','1','8')]:
                r=run(['sudo','-n','mknod','-m','666',str(root/'dev'/dev),'c',major,minor],timeout=10)
                if r.returncode and 'File exists' not in r.stderr: raise RuntimeError(r.stderr)
            repositories = (url if cat=='alpine' else 'https://dl-cdn.alpinelinux.org/alpine/')
            shell = 'set -eu\nprintf "%s\\n" '+repr(repositories+'v3.21/main')+' '+repr(repositories+'v3.21/community')+' > /etc/apk/repositories\n'
            shell += 'for attempt in 1 2; do apk update && break; test "$attempt" = 1; done\n'
            if cat=='alpine':
                shell += 'for attempt in 1 2; do apk add --no-cache curl nodejs npm && break; test "$attempt" = 1; done\ncurl --version\nnode --version\nnpm --version\nnpx --version\nnode -e "require(\'assert/strict\').equal(2+2,4)"\n'
            elif cat=='pip':
                shell += 'apk add --no-cache python3 py3-pip\npython3 -m venv /tmp/check-venv\n/tmp/check-venv/bin/python -m pip install --retries 1 --timeout 25 --only-binary=:all: --no-deps --no-cache-dir --index-url '+repr(url)+' six==1.17.0\n/tmp/check-venv/bin/python -c "import six; assert six.__version__ == \'1.17.0\'"\n'
            else:
                shell += 'apk add --no-cache nodejs npm\nmkdir -p /tmp/npm-check\ncd /tmp/npm-check\nnpm --registry='+repr(url)+' --fetch-retries=1 --fetch-timeout=30000 install --ignore-scripts --no-audit --no-fund is-number@7.0.0\nnode -e "require(\'assert/strict\').equal(require(\'is-number\')(42),true)"\nnpm --version\nnpx --version\n'
            shell += 'echo AMORE_MIRROR_ISOLATED_INSTALL_OK\n'
            (out/(mid+'.sh')).write_text(shell)
            r=run(['sudo','-n','chroot',str(root),'/usr/bin/qemu-aarch64-static','/bin/sh','-ec',shell],timeout=900)
            (out/(mid+'.log')).write_text(r.stdout+'\n'+r.stderr)
            result.update(exit_code=r.returncode,full_isolated_install=r.returncode==0 and 'AMORE_MIRROR_ISOLATED_INSTALL_OK' in r.stdout)
            if not result['full_isolated_install']: result['error']=(r.stdout+'\n'+r.stderr)[-3000:]
        except Exception as e: result['error']=str(e)
        finally:
            result['seconds']=round(time.time()-started,2)
            # No mounts: removing the single generated root cannot touch host configs.
            run(['sudo','-n','rm','-rf','--',str(root)],timeout=60)
        (out/(mid+'.json')).write_text(json.dumps(result,indent=2)); print(mid,result['full_isolated_install'],flush=True); return result
    with concurrent.futures.ThreadPoolExecutor(max_workers=min(a.workers,3)) as pool: results=list(pool.map(test,mirrors))
    (out/'installation-results.json').write_text(json.dumps(dict(schema_version=1,scope='Fresh Alpine 3.21 aarch64 QEMU chroots, NOT iPhone App',results=results),indent=2))
    shutil.rmtree(work,ignore_errors=True)
    raise SystemExit(0 if all(r['full_isolated_install'] for r in results) else 1)
if __name__=='__main__': main()
