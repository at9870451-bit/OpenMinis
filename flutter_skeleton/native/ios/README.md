# Native bridge contract (stage 5)

`NativeBridge.swift` is the Swift side of the `amore/native` MethodChannel.

It is **not** compiled into the Flutter runner: the capabilities it exposes
(iSH sandbox, FileProvider, Share extension, Widget, Live Activity, CloudKit)
must live in the retained native project, because they are iOS targets that
Flutter cannot host.

## Merge checklist

1. Copy `NativeBridge.swift` into the OpenMinis Xcode project.
2. In `AppDelegate.swift` / `MinisApp.swift`, after the Flutter engine starts:
   ```swift
   if let registrar = self.registrar(forPlugin: "NativeBridge") {
       NativeBridge.register(with: registrar)
   }
   ```
3. Replace the stub bodies with calls into the existing implementations:
   | Method | Target in the Swift project |
   |---|---|
   | `sandbox.status` | `RootfsManager.shared`, `ISHKernel` |
   | `sandbox.exec` | `ISHExecutionCoordinator` |
   | `fileProvider.register` | `MinisApp.registerFileProviderDomain()` |
   | `liveActivity.set` | the ActivityKit controller |
4. Keep the Dart side untouched — it already handles "unavailable" gracefully.

## Why these stay native

| Feature | Reason |
|---|---|
| iSH sandbox | 5,280 lines of ObjC/C kernel + fakefs; no Flutter equivalent |
| FileProvider | must be an `.appex` target |
| Share extension | must be an `.appex` target |
| Widget | WidgetKit extension |
| Live Activity | ActivityKit, native only |
| iCloud sync | CloudKit has no Flutter equivalent |
