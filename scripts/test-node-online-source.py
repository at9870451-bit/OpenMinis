#!/usr/bin/env python3
"""Source/bundle assertions; explicitly not an iOS compile or guest run."""
from pathlib import Path
import sys, zipfile
r=Path(__file__).resolve().parents[1]
def read(p): return (r/'src/ios'/p).read_text()
pbx=read('Minis.xcodeproj/project.pbxproj'); online=read('Views/ContentView/NodeOnlineRuntime.swift'); root=read('Views/Rootfs/RootfsManagementView.swift'); aojit=read('Views/Rootfs/AOJITSettingsView.swift'); mirror=read('Views/Rootfs/MirrorSpeedTestView.swift')
checks={
 'offline APK directory removed':not (r/'src/ios/NodeRuntime').exists(),
 'offline source files removed':not list((r/'src/ios/Views/ContentView').glob('NodeOffline*.swift')),
 'both NodeRuntime IDs and Copy Resources removed':all(s not in pbx for s in ['A29E50000000000000000001','A29E50000000000000000002','NodeRuntime in Resources']),
 'no offline UI/service references':all('NodeOfflineRuntime' not in p.read_text() for p in (r/'src/ios/Views').rglob('*.swift')),
 'current trusted online apk transaction':'apk update\n        apk add nodejs npm' in online and '--allow-untrusted' not in online and '--force' not in online and 'Bundle.main' not in online,
 'reuses guest executor and verifies all three commands':all(x in online for x in ['ISHShellExecutor.executeCommandSync','node --version','npm --version','npx --version','result.exitCode','exitCode == 0','result.error == .none','AMORE_NODE_ONLINE_READY']),
 'selected Alpine mirror is applied': 'mirrors.isActive(for: .alpine)' in online and 'mirrors.applyMirror(for: .alpine)' in online,
 'no reset/uninstall in Node flow':all(x not in online for x in ['apk del','reset(', 'rm -rf']),
 'reset/install/restore guard shared operation gate':root.count('guard beginOperation() else { return }')==3 and root.count('defer { RootfsOperationGate.shared.end() }')==3 and 'RootfsOperationGate.shared.begin()' in root and 'RootfsOperationGate.shared.begin()' in online,
 'reset while booted is rejected': '!RootfsManager.shared.didResetWhileBooted' in online,
 'Node uses online confirmed service without spoofed matched state':'try await NodeOnlineRuntime.shared.install()' in aojit and 'Download and install online' in aojit and 'nodeRuntimeReady' in aojit and '.matched(image.build)' not in aojit.split('func fix(_ image:')[1].split('func restore')[0],
 'mirror probe uses actual rootfs arch and branch': 'alpineArchitecture()' in mirror and 'etc/apk/arch' in mirror and 'six/' in mirror and 'is-number/7.0.0' in mirror and 'v3.21/main/aarch64/APKINDEX' not in mirror,
 'no TLS/system-package trust bypass in mirror apply': 'trusted-host' not in mirror and 'break-system-packages' not in mirror,
 'failed mirrors retained':all(x in mirror for x in ['"ustc"','"jaist"','"kakao"']),
}
if len(sys.argv)>1:
 p=Path(sys.argv[1]); names=zipfile.ZipFile(p).namelist() if p.suffix=='.ipa' else [str(x.relative_to(p)) for x in p.rglob('*')]
 checks['built App/IPA contains no NodeRuntime directory']=not any('/NodeRuntime/' in '/'+n or n.rstrip('/').endswith('/NodeRuntime') for n in names)
for label,ok in checks.items(): print(('PASS ' if ok else 'FAIL ')+label)
if not all(checks.values()): raise SystemExit(1)
print('SOURCE CHECKS PASSED; NOT an Xcode build, full installation, or iPhone App test.')
