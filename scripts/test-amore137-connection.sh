#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOST="${AMORE137_HOST:-${RUNNER_TEMP:-/tmp}/amore137-connection-tests}"
mkdir -p "$HOST/Sources/AmoreDeviceKit" "$HOST/Sources/PokiNative" "$HOST/Tests/Amore137Tests"
for f in Debug/Probe Loopback/LoopbackMonitor Loopback/RemotePairingPort Loopback/RemotePairingProbe Loopback/PairingVerificationGate; do
 cp "$ROOT/vendor/poki/native/ios-app/Poki/$f.swift" "$HOST/Sources/AmoreDeviceKit/"
done
cp "$ROOT/scripts/Amore137ConnectionTests.swift" "$HOST/Tests/Amore137Tests/"
cat > "$HOST/Package.swift" <<'EOF'
// swift-tools-version: 5.10
import PackageDescription
let package = Package(name: "Amore137ConnectionTests", platforms: [.macOS(.v14)], products: [], targets: [
 .target(name: "PokiNative"),
 .target(name: "AmoreDeviceKit", dependencies: ["PokiNative"]),
 .testTarget(name: "Amore137Tests", dependencies: ["AmoreDeviceKit"])
])
EOF
cat > "$HOST/Sources/PokiNative/NoNativeTransport.swift" <<'EOF'
// Native C side effects are inert in this test process, not protocol replacements.
// Production monitor is tested with injected protocol/Bonjour outcomes.
public func poki_set_remote_pairing_port(_ port: UInt16) {}
public func poki_set_pairing_port_search(_ value: Bool) {}
EOF
cat > "$HOST/Sources/AmoreDeviceKit/TestDependencies.swift" <<'EOF'
import Foundation
struct AppLocalization {
 static let locale = Locale(identifier: "en_US")
 static var bundle: Bundle { .main }
 static func text(_ text: LocalizedStringResource) -> String { String(localized: text) }
}
@MainActor final class AppLog {
 static let shared = AppLog()
 func add(_ category: String, _ message: String) {}
}
struct NativeBridgeDisabled: Error {}
enum SignerBridge {
 static func decode<T: Decodable>(_ type: T.Type, _ request: [String: Any]) async throws -> T {
  // All monitor tests inject handshakeProbe. An accidental live call fails closed.
  throw NativeBridgeDisabled()
 }
}
EOF
if [[ "${AMORE137_PREPARE_ONLY:-0}" == "1" ]]; then
 echo "Prepared only: $HOST (production monitor, mock native side effects; no tests executed)"
 exit 0
fi
command -v swift >/dev/null
set -o pipefail
swift test --package-path "$HOST" --disable-sandbox 2>&1 | tee "${AMORE137_TEST_LOG:-$ROOT/amore137-connection-tests.log}"
