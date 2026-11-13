import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme/amore_theme.dart';
import '../features/settings/appearance_page.dart';
import 'home_shell.dart';

class AmoreApp extends ConsumerWidget {
  const AmoreApp({super.key, this.rustError});

  /// Non-null when the Rust core failed to load. The UI still runs; the banner
  /// tells the user which engine is missing instead of showing a blank screen.
  final Object? rustError;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(themeModeProvider);
    return MaterialApp(
      title: 'Amore',
      debugShowCheckedModeBanner: false,
      theme: AmoreTheme.theme(),
      darkTheme: AmoreTheme.theme(),
      themeMode: mode,
      home: rustError == null
          ? const HomeShell()
          : _RustFailureScreen(error: rustError!),
    );
  }
}

/// Shown only when the native core did not load. Keeps the app usable and makes
/// the problem diagnosable instead of hiding everything behind a white screen.
class _RustFailureScreen extends StatelessWidget {
  const _RustFailureScreen({required this.error});

  final Object error;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AmoreTheme.background,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.memory, size: 40, color: AmoreTheme.warning),
              const SizedBox(height: 16),
              const Text(
                'Native core unavailable',
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w600,
                  color: AmoreTheme.textPrimary,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'The Rust engine did not load, so chat and the sandbox are '
                'disabled. The UI below still works.',
                style: TextStyle(fontSize: 14, color: AmoreTheme.textSecondary),
              ),
              const SizedBox(height: 16),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AmoreTheme.secondaryBackground,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  '$error',
                  style: const TextStyle(
                    fontFamily: 'Menlo',
                    fontSize: 11,
                    color: AmoreTheme.textSecondary,
                  ),
                ),
              ),
              const Spacer(),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: AmoreTheme.accent,
                    minimumSize: const Size.fromHeight(48),
                  ),
                  onPressed: () {},
                  child: const Text('Retry later'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
