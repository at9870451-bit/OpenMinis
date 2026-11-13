Pod::Spec.new do |s|
  s.name             = 'ISHHost'
  s.version          = '0.1.0'
  s.summary          = 'iSH kernel host for the Flutter runner.'
  s.description      = 'Vendors libish/libish_emu/libfakefs and exposes the sandbox over the amore/native channel.'
  s.homepage         = 'https://github.com/OpenMinis/OpenMinis'
  s.license          = { :type => 'GPL-3.0' }
  s.author           = { 'Amore' => 'noreply@example.com' }
  s.source           = { :path => '.' }
  s.platform         = :ios, '15.0'
  s.source_files     = '*.h', '*.c', '*.m', 'stubs/*.h', 'stubs/*.m'
  s.public_header_files = 'AmoreNativePlugin.h', 'ISHHost.h'
  s.frameworks       = 'Foundation', 'UIKit'
  s.libraries        = 'c++', 'z', 'sqlite3', 'iconv'
  s.vendored_libraries = 'libish.a', 'libish_emu.a', 'libfakefs.a'
  s.dependency 'Flutter'
  s.pod_target_xcconfig = {
    'OTHER_LDFLAGS' => '-force_load "${PODS_TARGET_SRCROOT}/libish.a"',
    'HEADER_SEARCH_PATHS' => '"${PODS_TARGET_SRCROOT}/../../../../deps/include" "${PODS_TARGET_SRCROOT}/../../../../deps/ish" "${PODS_TARGET_SRCROOT}/stubs"',
    'CLANG_ENABLE_MODULES' => 'YES',
    # iSH's internal headers (fs/fake.h) refuse to be included without this.
    'GCC_PREPROCESSOR_DEFINITIONS' => 'ISH_INTERNAL=1'
  }
end
