#!/bin/bash
# Offline fixtures only. Compiles the exact production reducer AND returned
# Chat-Completions stream body; substitutes only app types/logger/transport input.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
command -v python3 >/dev/null || { echo 'ERROR: python3 is required.' >&2; exit 1; }
HOST="${AMORE138_TOOL_STREAM_HOST:-$(mktemp -d "${TMPDIR:-/tmp}/amore138-tool-stream.XXXXXX")}"
python3 - "$ROOT" "$HOST" <<'PY'
from pathlib import Path
import hashlib, json, sys
root, host = [Path(p).expanduser().resolve() for p in sys.argv[1:]]
for protected in (root / 'src', root / 'scripts', root / 'vendor', root / 'deps'):
    if host == protected or host in protected.parents or protected in host.parents:
        raise SystemExit(f'ERROR: unsafe host path: {host}')
if host.exists() and any(host.iterdir()):
    raise SystemExit(f'ERROR: use a fresh empty AMORE138_TOOL_STREAM_HOST: {host}')
src = root / 'src/ios/Providers'
provider = (src / 'OpenAI/OpenAIAgentProvider.swift').read_text()
agent = (src / 'AgentProvider.swift').read_text()
llmtypes = (src / 'LLMTypes.swift').read_text()
openai = (src / 'OpenAI/OpenAIProvider.swift').read_text()

def between(text, begin, end):
    assert text.count(begin) == 1 and text.count(end) == 1, (begin, end)
    return text.split(begin, 1)[1].split(end, 1)[0]

# No handwritten parser/reducer substitute: preserve production bytes, with
# failing extraction anchors if the production method/section layout changes.
chat = provider.split('    // MARK: - Responses API (OAuth/Codex mode)', 1)[0]
anchor = '        return AsyncThrowingStream { continuation in\n'
assert chat.count(anchor) == 1
stream = anchor + chat.split(anchor, 1)[1]
assert stream.rstrip().endswith('    }')
assert 'try completeTurn(.done)' in stream
assert 'try completeTurn(.finishReason(fr))' in stream
assert 'try toolCompletion.endOfStream()' in stream
reasoning = between(provider, '    // BEGIN ChatCompletionsReasoningActivity\n',
                    '    // END ChatCompletionsReasoningActivity')
think = '    struct ThinkPrefixStreamParser {' + between(
    provider, '    struct ThinkPrefixStreamParser {', '    // MARK: - Helpers')
sse = '    private static func ssePayload(from line: String) -> String? {' + between(
    provider, '    private static func ssePayload(from line: String) -> String? {',
    '    private static func parseJsonToDict(')
reducer = between(provider, '// BEGIN AmoreToolCallCompletion\n',
                  '// END AmoreToolCallCompletion')
events = between(agent, '// MARK: - Stream Events\n', '// MARK: - Protocol')
echo = 'struct ReasoningEcho: @unchecked Sendable {' + between(
    agent, 'struct ReasoningEcho: @unchecked Sendable {', '// MARK: - ReasoningEcho persistence')
usage = 'struct LLMUsage: Sendable {' + between(
    llmtypes, 'struct LLMUsage: Sendable {', '// MARK: - Model ID')
map_error = '    func mapError(_ error: Error) -> LLMError {' + between(
    openai, '    func mapError(_ error: Error) -> LLMError {',
    '    func mapHTTPError(')
parts = dict(stream=stream, reasoningActivity=reasoning, thinkParser=think,
             ssePayload=sse, reducer=reducer, events=events, reasoningEcho=echo,
             usage=usage, mapError=map_error)
sources = host / 'Sources/AmoreToolStream'
tests = host / 'Tests/Amore138ToolStreamTests'
sources.mkdir(parents=True)
tests.mkdir(parents=True)
# Host starts AFTER real streamRaw: SSE input is entirely injected. The actual
# returned AsyncThrowingStream implementation and pure helper are unchanged.
wrapper = '''import Foundation
struct HostLogger {
    func info(_ message: String) {}
    func warning(_ message: String) {}
    func error(_ message: String) {}
}
private let logger = HostLogger()
enum ThinkingLevel {
    case off, on
    var isEnabled: Bool { self == .on }
}
struct HostModel {
    var id = "fixture-only"
    var interleavedReasoningField: String? = nil
}
struct InertProvider {
'''
wrapper += map_error + '}\n'
wrapper += '''final class ChatCompletionsStreamHost {
    let provider = InertProvider()
    let model: HostModel
    init(model: HostModel = HostModel()) { self.model = model }
    func stream(_ lineStream: AsyncThrowingStream<String, Error>,
                thinkingLevel: ThinkingLevel = .on) -> AsyncThrowingStream<AgentStreamEvent, Error> {
'''
wrapper += stream + reasoning + think + sse + '}\n' + reducer
(sources / 'ProductionStream.swift').write_text(wrapper)
(sources / 'ProductionContracts.swift').write_text('import Foundation\n' + echo + events + usage)
(sources / 'LLMError.swift').write_bytes((src / 'LLMError.swift').read_bytes())
test_source = root / 'scripts/Amore138ToolStreamTests.swift'
(tests / test_source.name).write_bytes(test_source.read_bytes())
(host / 'Package.swift').write_text('''// swift-tools-version: 5.10
import PackageDescription
let package = Package(name: "Amore138ToolStreamTests", platforms: [.macOS(.v14)], targets: [
    .target(name: "AmoreToolStream"),
    .testTarget(name: "Amore138ToolStreamTests", dependencies: ["AmoreToolStream"])
])
''')
manifest = {
    'mode': 'offline injected SSE; exact production stream body and reducer; no live provider/device',
    'source': 'src/ios/Providers/OpenAI/OpenAIAgentProvider.swift',
    'sourceSHA256': hashlib.sha256(provider.encode()).hexdigest(),
    'exactExtractedFragments': {
        k: {'bytes': len(v.encode()), 'sha256': hashlib.sha256(v.encode()).hexdigest()}
        for k, v in parts.items()},
    'testCount': test_source.read_text().count('    func test'),
    'hostOnly': ['injected lineStream', 'HostLogger', 'ThinkingLevel off/on flag', 'HostModel',
                 'InertProvider shell (mapError is production source)'],
    'notCovered': ['request construction', 'streamRaw network', 'full app compilation',
                   'Agent/Views', 'device execution', 'Responses/Anthropic']}
(host / 'source-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
print(f"SOURCE EXTRACTION OK: {len(parts)} exact production fragments; {manifest['testCount']} XCTest methods")
print(f'Host: {host}')
PY
if [[ "${AMORE138_TOOL_STREAM_PREPARE_ONLY:-0}" == "1" ]]; then
    echo 'PREPARED ONLY: source extraction passed; Swift build/XCTest NOT executed.'
    exit 0
fi
command -v swift >/dev/null || { echo 'ERROR: Swift 5.10+ is required; prepare-only is not a runtime test.' >&2; exit 1; }
swift --version
# No package dependencies, API credentials, real models, devices or downloads.
swift test --package-path "$HOST" --disable-sandbox 2>&1 | tee "$HOST/swift-test.log"
