import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'src/rust/api/simple.dart';

/// Stage-1 shell: proves the Dart -> Rust -> Dart path inside a real widget,
/// with the Apple-White tokens that later stages will extend.
void main() => runApp(const ProviderScope(child: AmoreApp()));

class AmoreApp extends StatelessWidget {
  const AmoreApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Amore',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFFFFFFFF),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF007AFF),
          surface: const Color(0xFFFFFFFF),
        ),
        fontFamily: '.SF Pro Text',
      ),
      home: const BridgeProbePage(),
    );
  }
}

class BridgeProbePage extends StatefulWidget {
  const BridgeProbePage({super.key});

  @override
  State<BridgeProbePage> createState() => _BridgeProbePageState();
}

class _BridgeProbePageState extends State<BridgeProbePage> {
  String _result = 'Tap to call Rust';

  void _callRust() {
    // Synchronous FFI call into the Rust core.
    final greeting = greet(name: 'Amore');
    final digest = digestSession(
      json: '{"title":"迁移测试","messages":[{"content":"你好"},{"content":"hello"}]}',
    );
    setState(() {
      _result = '$greeting\n'
          'digest: ${digest.title} / ${digest.messageCount} msgs / '
          '${digest.charCount} chars';
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Text(
                  'Amore · Flutter + Rust',
                  style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Stage 1 bridge probe',
                  style: TextStyle(fontSize: 15, color: Color(0xFF8E8E93)),
                ),
                const SizedBox(height: 32),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: const Color(0xFFE5E5EA)),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x14000000),
                        blurRadius: 18,
                        offset: Offset(0, 6),
                      ),
                    ],
                  ),
                  child: Text(_result, style: const TextStyle(fontSize: 15)),
                ),
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: _callRust,
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF007AFF),
                    minimumSize: const Size(double.infinity, 52),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(26),
                    ),
                  ),
                  child: const Text('调用 Rust'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
