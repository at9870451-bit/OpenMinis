/// Which capability is delivered by which layer.
///
/// This manifest is the migration contract: it makes it impossible to "forget"
/// a system feature, and it documents why some of them stay native.
enum CapabilityLayer {
  /// Pure Flutter plugin — no native code of ours needed.
  plugin,

  /// Flutter calls a MethodChannel implemented in the retained Swift project.
  nativeBridge,

  /// Must remain a native iOS extension/target; Flutter only renders settings.
  nativeTarget,
}

class Capability {
  const Capability(this.name, this.layer, {this.note});

  final String name;
  final CapabilityLayer layer;
  final String? note;
}

const List<Capability> kCapabilities = [
  Capability('Camera', CapabilityLayer.plugin, note: 'image_picker'),
  Capability('Photo library', CapabilityLayer.plugin, note: 'image_picker'),
  Capability('File picker', CapabilityLayer.plugin, note: 'file_picker'),
  Capability('Microphone / recording', CapabilityLayer.nativeBridge,
      note: 'AVAudioRecorder in the retained native project; the record plugin '
          'family currently ships an incompatible record_linux 0.7.2'),
  Capability('Audio playback', CapabilityLayer.plugin, note: 'just_audio (stage 6)'),
  Capability('Clipboard', CapabilityLayer.plugin, note: 'Flutter services'),
  Capability('Share sheet', CapabilityLayer.plugin, note: 'share_plus'),
  Capability('Keychain', CapabilityLayer.plugin, note: 'flutter_secure_storage'),
  Capability('Permissions', CapabilityLayer.plugin, note: 'permission_handler'),
  Capability('Local notifications', CapabilityLayer.plugin, note: 'stage 6'),
  Capability('Linux sandbox (iSH)', CapabilityLayer.nativeBridge,
      note: 'kernel + fakefs are ObjC/C; Flutter only issues commands'),
  Capability('FileProvider', CapabilityLayer.nativeTarget,
      note: 'iOS extension; must stay native'),
  Capability('Share extension', CapabilityLayer.nativeTarget,
      note: 'iOS extension; must stay native'),
  Capability('Widget', CapabilityLayer.nativeTarget,
      note: 'WidgetKit extension'),
  Capability('Live Activity', CapabilityLayer.nativeTarget,
      note: 'ActivityKit; native only'),
  Capability('iCloud sync', CapabilityLayer.nativeTarget,
      note: 'CloudKit has no Flutter equivalent'),
];
