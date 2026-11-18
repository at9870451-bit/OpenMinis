from pathlib import Path
r=Path(__file__).resolve().parents[1]
def read(p):return (r/p).read_text()
layout=read('src/ios/Views/ContentView/ContentView+Layout.swift')
settings=read('src/ios/Views/Settings/SettingsSheet.swift')
installer=read('src/ios/Views/ContentView/Plugins/PluginInstaller.swift')
checks={
'one Amore session path remains':'NavigationStack(path: $navigationPath)' in layout and 'homeSessionId = nil' in layout,
'no dynamic Poki UI factory remains':not any('OriginalPokiScreen' in p.read_text(errors='ignore') or 'NSClassFromString("AmorePokiEntry")' in p.read_text(errors='ignore') for p in (r/'src/ios').rglob('*.swift')),
'Amore message and composer remain native':'AIChatView(sessionId:' in layout and (r/'src/ios/Views/Chat/AIChatView/AIChatView+InputBar.swift').exists(),
'Amore plugin installer remains present':'installPrepared' in installer and 'installedPlugins' in installer,
'Amore offline Node bundle removed':not (r/'src/ios/NodeRuntime').exists() and (r/'src/ios/Views/ContentView/NodeOnlineRuntime.swift').is_file(),
'developer route uses Amore device page':'AmoreDeviceConnectionPage()' in settings,
'device tools are gated by enabled provider credential':'$0.isEnabled && $0.hasAnyCredential' in read('src/ios/Views/ContentView/AmoreDeviceTools.swift'),
}
for k,v in checks.items():print(('PASS' if v else 'FAIL'),k)
if not all(checks.values()):raise SystemExit(1)
print('STATIC FUSION CHECKS PASSED. This is not an Xcode build or a device test.')
