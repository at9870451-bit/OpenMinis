import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/i18n/app_strings.dart';
import '../core/theme/amore_theme.dart';
import '../features/settings/appearance_page.dart';
import 'home_shell.dart';

class AmoreApp extends ConsumerWidget {
  const AmoreApp({super.key, this.rustError});

  /// Non-null when the Rust core failed to load. The UI still runs; the screen
  /// explains which engine is missing instead of showing a blank window.
  final Object? rustError;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(themeModeProvider);
    return MaterialApp(
      // No `locale` is set: the whole app follows the system language. Adding
      // the delegates lets Material/Cupertino widgets localise too.
      onGenerateTitle: (ctx) => AppStrings.of(ctx).appName,
      supportedLocales: AppStrings.supportedLocales,
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
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

class _RustFailureScreen extends StatelessWidget {
  const _RustFailureScreen({required this.error});

  final Object error;

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
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
              Text(
                s.nativeCoreUnavailable,
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w600,
                  color: AmoreTheme.textPrimary,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                s.nativeCoreDetail,
                style: const TextStyle(
                    fontSize: 14, color: AmoreTheme.textSecondary),
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
            ],
          ),
        ),
      ),
    );
  }
}
