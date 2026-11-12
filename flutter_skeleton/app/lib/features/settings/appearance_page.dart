import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/amore_theme.dart';

/// Theme mode is app-level state so the whole MaterialApp reacts to it.
final themeModeProvider = StateProvider<ThemeMode>((ref) => ThemeMode.system);

class AppearancePage extends ConsumerWidget {
  const AppearancePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(themeModeProvider);

    return Scaffold(
      backgroundColor: AmoreTheme.groupedBackground,
      appBar: AppBar(
        backgroundColor: AmoreTheme.groupedBackground,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: const Text('Appearance',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
        centerTitle: true,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          Container(
            decoration: BoxDecoration(
              color: AmoreTheme.background,
              borderRadius: BorderRadius.circular(AmoreTheme.rCard),
              border: Border.all(color: AmoreTheme.separator, width: 0.5),
            ),
            child: Column(
              children: [
                for (final entry in const [
                  (ThemeMode.system, 'Follow System', Icons.brightness_auto),
                  (ThemeMode.light, 'Light', Icons.light_mode_outlined),
                  (ThemeMode.dark, 'Dark', Icons.dark_mode_outlined),
                ])
                  RadioListTile<ThemeMode>(
                    value: entry.$1,
                    groupValue: mode,
                    onChanged: (v) {
                      if (v != null) {
                        ref.read(themeModeProvider.notifier).state = v;
                      }
                    },
                    activeColor: AmoreTheme.accent,
                    title: Text(entry.$2,
                        style: const TextStyle(
                            fontSize: 15.5, color: AmoreTheme.textPrimary)),
                    secondary: Icon(entry.$3,
                        size: 18, color: AmoreTheme.textSecondary),
                  ),
              ],
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(4, 12, 4, 0),
            child: Text(
              'Apple White is the default. Dark mode uses the same geometry '
              'with inverted surfaces — never gradients.',
              style: TextStyle(fontSize: 12, color: AmoreTheme.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}
