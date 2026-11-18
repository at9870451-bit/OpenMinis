#!/usr/bin/env python3
"""Read-only mirror evidence: no package installation or host config changes."""
import argparse, base64, concurrent.futures, hashlib, html.parser, io, json, re, subprocess, tarfile, time, urllib.parse, zlib
from pathlib import Path

class Links(html.parser.HTMLParser):
    def __init__(self): super().__init__(); self.links=[]
    def handle_starttag(self, tag, attrs):
        if tag=='a': self.links += [dict(attrs).get('href','')]

def main():
    p=argparse.ArgumentParser(); p.add_argument('--output',required=True); p.add_argument('--branch',default='3.21'); p.add_argument('--arch',default='aarch64'); p.add_argument('--workers',type=int,default=5)
    args=p.parse_args(); out=Path(args.output).resolve(); out.mkdir(parents=True,exist_ok=True)
    source=Path(__file__).resolve().parents[1]/'src/ios/Views/Rootfs/MirrorSpeedTestView.swift'
    text=source.read_text(); mirrors=[]
    for category in ['alpine','pip','npm']:
        section=text.split('private static let '+category+'Mirrors:')[1].split('}()')[0]
        for mid,name,url,region in re.findall(r'm\("([^"]+)", "([^"]+)", "([^"]+)", "([^"]+)"',section):
            mirrors.append(dict(id=category+'.'+mid,category=category,name=name,base_url=url,region=region))
    (out/'sources.json').write_text(json.dumps(mirrors,indent=2))
    def test(m):
        d=out/m['id']; d.mkdir(exist_ok=True); record=dict(m,branch=args.branch if m['category']=='alpine' else None,arch=args.arch if m['category']=='alpine' else None,full_isolated_install='not_run',url_reachable=False,metadata_valid=False,package_bytes_verified=False,downloads=[])
        def download(url,label):
            body=d/(label+'.body'); headers=d/(label+'.headers'); attempts=[]
            for attempt in range(2):
                started=time.monotonic()
                cmd=['curl','--silent','--show-error','--location','--fail','--proto','=https','--proto-redir','=https','--connect-timeout','10','--max-time','30','--max-filesize','16777216','-D',str(headers),'-o',str(body),'-w','%{http_code}\n%{url_effective}',url]
                r=subprocess.run(cmd,capture_output=True,text=True,timeout=35)
                parts=r.stdout.splitlines(); attempts.append(dict(attempt=attempt+1,exit_code=r.returncode,status=parts[0] if parts else None,effective_url=parts[1] if len(parts)>1 else None,seconds=round(time.monotonic()-started,3),error=r.stderr[-800:]))
                if r.returncode==0: break
            item=dict(url=url,label=label,attempts=attempts,body=str(body.relative_to(out)),headers=str(headers.relative_to(out)))
            record['downloads'].append(item)
            if r.returncode: raise RuntimeError(label+': '+str(attempts[-1]))
            data=body.read_bytes(); item.update(bytes=len(data),sha256=hashlib.sha256(data).hexdigest()); record['url_reachable']=True
            return data,parts[1] if len(parts)>1 else url
        def verify_index(raw):
            dec=zlib.decompressobj(31); first=dec.decompress(raw); signed=dec.unused_data
            with tarfile.open(fileobj=io.BytesIO(first),mode='r:') as t:
                signs=[n for n in t.getnames() if n.startswith('.SIGN.RSA.')]
                if not signs: raise ValueError('No RSA index signature')
                name=signs[0]; sig=t.extractfile(name).read()
            key=Path('/etc/apk/keys')/name.removeprefix('.SIGN.RSA.')
            if not key.is_file(): raise ValueError('Trusted key unavailable: '+key.name)
            (d/'index.signature').write_bytes(sig); (d/'index.signed.gz').write_bytes(signed)
            v=subprocess.run(['openssl','dgst','-sha1','-verify',str(key),'-signature',str(d/'index.signature'),str(d/'index.signed.gz')],capture_output=True,text=True)
            record['index_signature']=dict(key=key.name,verified=v.returncode==0,output=(v.stdout+v.stderr).strip())
            if v.returncode: raise ValueError('APKINDEX signature verification failed')
        try:
            if m['category']=='alpine':
                base=m['base_url']+'v'+args.branch+'/main/'+args.arch+'/'
                raw,_=download(base+'APKINDEX.tar.gz','metadata'); verify_index(raw)
                with tarfile.open(fileobj=io.BytesIO(raw),mode='r:gz',ignore_zeros=True) as t: index=t.extractfile('APKINDEX').read().decode()
                pkgs=[dict(line.split(':',1) for line in block.splitlines() if ':' in line) for block in index.split('\n\n')]
                pkg=next(p for p in pkgs if p.get('P')=='curl' and p.get('A')==args.arch)
                record['package']=dict(name='curl',version=pkg['V'],arch=pkg['A'],index_checksum=pkg.get('C')); record['metadata_valid']=True
                raw,_=download(base+'curl-'+pkg['V']+'.apk','package')
                v=subprocess.run(['apk','verify',str(d/'package.body')],capture_output=True,text=True)
                record['package_signature']=dict(verified=v.returncode==0,output=(v.stdout+v.stderr).strip())
                if v.returncode: raise ValueError('apk verify failed: '+v.stderr)
                with tarfile.open(fileobj=io.BytesIO(raw),mode='r:gz',ignore_zeros=True) as t:
                    info=t.extractfile('.PKGINFO').read().decode(); assert 'pkgname = curl\n' in info and 'pkgver = '+pkg['V']+'\n' in info
                record['package_bytes_verified']=True
            elif m['category']=='pip':
                raw,effective=download(m['base_url']+'six/','metadata'); h=Links(); h.feed(raw.decode())
                choices=[link for link in h.links if 'six-1.17.0-py2.py3-none-any.whl' in link and '#sha256=' in link]
                if not choices: raise ValueError('Expected pure Python wheel + SHA256 link missing')
                record['metadata_valid']=True; url=urllib.parse.urljoin(effective,choices[0]); expected=urllib.parse.parse_qs(urllib.parse.urlsplit(url).fragment)['sha256'][0]
                raw,_=download(url.split('#')[0],'package'); actual=hashlib.sha256(raw).hexdigest(); record['package']=dict(name='six',version='1.17.0',expected_sha256=expected,actual_sha256=actual)
                if actual!=expected: raise ValueError('Wheel SHA256 mismatch')
                import zipfile
                with zipfile.ZipFile(io.BytesIO(raw)) as z: assert any(n.endswith('.dist-info/WHEEL') for n in z.namelist())
                record['package_bytes_verified']=True
            else:
                raw,_=download(m['base_url']+'is-number/7.0.0','metadata'); meta=json.loads(raw); assert meta['name']=='is-number' and meta['version']=='7.0.0'
                record['metadata_valid']=True; dist=meta['dist']; tarball=urllib.parse.urljoin(m['base_url'],dist['tarball']); raw,_=download(tarball,'package')
                sri=dist.get('integrity',''); valid=[]
                for token in sri.split():
                    algorithm,_,value=token.partition('-')
                    if algorithm in ('sha512','sha384','sha256'): valid.append(base64.b64encode(hashlib.new(algorithm,raw).digest()).decode()==value)
                if not valid or not all(valid): raise ValueError('npm SRI missing or mismatch')
                if dist.get('shasum') and hashlib.sha1(raw).hexdigest()!=dist['shasum']: raise ValueError('npm shasum mismatch')
                with tarfile.open(fileobj=io.BytesIO(raw),mode='r:gz') as t: assert json.load(t.extractfile('package/package.json'))['name']=='is-number'
                record['package']=dict(name='is-number',version='7.0.0',integrity=sri,shasum=dist.get('shasum'),tarball_host=urllib.parse.urlsplit(tarball).hostname,relative_tarball=not bool(urllib.parse.urlsplit(dist['tarball']).netloc)); record['package_bytes_verified']=True
            record['result']='package_bytes_verified'
        except Exception as e: record.update(result='failed',error=str(e))
        (d/'result.json').write_text(json.dumps(record,indent=2,ensure_ascii=False)); print(m['id'],record['result'],record.get('error',''),flush=True); return record
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.workers) as pool: results=list(pool.map(test,mirrors))
    output=dict(schema_version=1,tested_at=time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime()),environment='Minis/iSH Alpine; read-only HTTPS downloads; trusted system APK keys',scope='Metadata + actual package download verification; NOT full installation or iPhone App execution',results=results)
    files=[dict(path=str(f.relative_to(out)),bytes=f.stat().st_size,sha256=hashlib.sha256(f.read_bytes()).hexdigest()) for f in sorted(out.rglob('*')) if f.is_file()]
    output['raw_data_manifest']=files; (out/'results.json').write_text(json.dumps(output,ensure_ascii=False,indent=2)); (out/'manifest.json').write_text(json.dumps(files,indent=2))
    print('TOTAL',len(results),'VERIFIED',sum(r['package_bytes_verified'] for r in results),flush=True)
if __name__=='__main__': main()
