# ISHHost pod

Links the iSH kernel into the Flutter runner and exposes it over
`amore/native`.

## What CI does (see .github/workflows/flutter-ios.yml)

1. `deps/build_ish.sh` → `deps/libs/libish.a`, `libish_emu.a`, `libfakefs.a`
   and public headers in `deps/include`.
2. Copies those archives here, plus the kernel wrappers from
   `src/ios/iSH/` (`ISHKernel.{h,m}`, `ISHShellExecutor.{h,m}`,
   `CurrentRoot.{h,m}`).
3. Rewrites the two host-only imports in `ISHKernel.m` to the stubs in
   `stubs/` (`CrashSignalHandler.h`, `CrashSignalPolicy.h`, `Minis-Swift.h`).
4. Appends `pod 'ISHHost', :path => './ish_host'` to the Podfile and injects
   `AmoreNativePlugin.register(with:)` into `AppDelegate`.

## Why stubs

`ISHKernel.m` is the only file coupled to the host app: it chains into the
app's crash-signal handler and asks `MinisContainerDns` for a resolv.conf.
Neither concept exists in the Flutter runner, so both are satisfied by the
no-op shims in `stubs/`.
