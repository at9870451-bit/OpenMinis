Pod::Spec.new do |s|
  s.name             = 'ISHHost'
  s.version          = '0.1.0'
  s.summary          = 'Links the iSH static libraries into the Flutter runner.'
  s.description      = <<-DESC
Vendors libish / libish_emu / libfakefs (built by deps/build_ish.sh) so the
Flutter app can host the Linux sandbox without editing the Xcode project file.
                       DESC
  s.homepage         = 'https://github.com/OpenMinis/OpenMinis'
  s.license          = { :type => 'GPL-3.0' }
  s.author           = { 'Amore' => 'noreply@example.com' }
  s.source           = { :path => '.' }

  s.ios.deployment_target = '15.0'
  s.source_files          = '*.{h,c}'
  s.public_header_files   = '*.h'
  s.vendored_libraries    = 'libish.a', 'libish_emu.a', 'libfakefs.a'
  s.libraries              = 'c++', 'z', 'sqlite3', 'iconv'

  # -force_load only libish.a: the emulator archive (libish_emu.a) defines the
  # guest gadgets in two objects, so force-loading it makes ld report duplicate
  # _gadget_* symbols. Its objects are referenced anyway, so plain linking works.
  s.pod_target_xcconfig = {
    'OTHER_LDFLAGS' => '-force_load "${PODS_TARGET_SRCROOT}/libish.a"',
    'CLANG_CXX_LANGUAGE_STANDARD' => 'gnu++17',
    'GCC_ENABLE_CPP_EXCEPTIONS' => 'NO',
    'GCC_ENABLE_CPP_RTTI' => 'NO',
  }
end
