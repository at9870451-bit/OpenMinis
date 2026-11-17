from pathlib import Path
import json,re,shutil
root=Path(__file__).resolve().parents[1];p=root/'vendor/poki/native/ios-app'
changed=[]
def edit(path,old,new):
 f=p/path;s=f.read_text()
 if old in s:
  s=s.replace(old,new);f.write_text(s);changed.append(str(path));return
 if new not in s:raise SystemExit('Neither original nor adapted anchor exists: '+str(path))
# Feature is a library, never the upstream @main executable.
f=p/'Poki/App/PokiApp.swift';s=f.read_text()
if '@main' in s: s=s[s.index('/// The chat is the app'):];s='import PokiCore\nimport SwiftUI\n'+s;f.write_text(s);changed.append('Poki/App/PokiApp.swift')
edit(Path('Poki/App/PokiApp.swift'),'model.startSigner(); model.signer.maintain(); ','')
edit(Path('Poki/App/PokiApp.swift'),'@AppStorage(Appearance.key) private var appearance = Appearance.automatic.rawValue','@AppStorage("amore.appearance") private var appearance = Appearance.automatic.rawValue')
edit(Path('Poki/App/AppModel.swift'),'if !self.diskImage.hasFiles { await self.diskImage.download() }','// Amore: DDI download begins only from the original explicit setup button.')
edit(Path('Poki/App/SetupState.swift'),'appendingPathComponent("Poki", isDirectory: true)','appendingPathComponent("AmorePoki", isDirectory: true)')
for f in (p/'Poki').rglob('*.swift'):
 s=f.read_text()
 if re.search(r'\b(PKInProcess|PKOutcome|PKDisplayGeometry|PKTouchPoint|PKDelivery|PKPeerPane|poki_launcher_|poki_pair_|poki_signer_|poki_history_)',s) and 'import PokiNative' not in s:
  f.write_text('import PokiNative\n'+s);changed.append(str(f.relative_to(p)))
# Replace only the mascot drawing; retain PokiPicture and top-bar layouts.
f=p/'Poki/Chat/HomeView.swift';s=f.read_text();start=s.index('    private func portrait(_ mood: PokiMood) -> some View {');end=s.index('\n}\n',start)
if 'Image(systemName: "sparkles")' not in s[start:end]:
 s=s[:start]+'''    private func portrait(_ mood: PokiMood) -> some View {
        ZStack {
            Circle().fill(Tint.portrait)
            Image(systemName: "sparkles").font(.system(size: side * 0.42, weight: .medium)).foregroundStyle(Tint.blueText)
        }.frame(width: side, height: side).clipShape(.circle)
    }
'''+s[end:];s=s.replace('Text(verbatim: "Poki")','Text(verbatim: "Amore")');f.write_text(s);changed.append(str(f.relative_to(p)))
# Do not move upstream Assets.xcassets into the signed framework; the main app
# supplies its own carefully scoped PokiPortAssets catalog.
for f in (p/'Poki').rglob('*.swift'):
 s=f.read_text();v=s
 v=re.sub(r'Image\("([^"\n]+)"\)',r'Image("\1", bundle: PokiPortResources.bundle)',v)
 if f.name=='AppIconStore.swift':v=v.replace('Bundle.main.path(forResource:', 'PokiPortResources.bundle.path(forResource:')
 if v!=s:f.write_text(v);changed.append(str(f.relative_to(p)))
native=p/'Poki/Native';header=root/'vendor/poki/native/launcher/include/poki_launcher.h'
if header.exists():shutil.copyfile(header,native/'poki_launcher.h')
native.joinpath('module.modulemap').write_text('module PokiNative {\n header "InProcess.h"\n header "poki_launcher.h"\n export *\n}\n')
# Preserve deterministic source provenance; no mascot or Poki icon is copied.
manifest=root/'vendor/poki/AMORE_PATCHES.json';old=json.loads(manifest.read_text()) if manifest.exists() else {'revision':'69585293051fee03c7ad110f037d8f4dd2a4e96f','modifiedFiles':[]}
old['modifiedFiles']=sorted(set(old['modifiedFiles'])|set(changed));manifest.write_text(json.dumps(old,indent=2)+'\n')
print('Idempotent prepare: changed',len(changed),'files; no runtime connection started')
