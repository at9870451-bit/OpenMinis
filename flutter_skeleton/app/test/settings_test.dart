import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:amore/core/theme/amore_theme.dart';
import 'package:amore/features/settings/appearance_page.dart';
import 'package:amore/features/settings/settings_page.dart';

/// Stage 6b: the settings shell must expose every section the SwiftUI app had,
/// and the theme choice must actually drive app-level state.
void main() {
  testWidgets('settings lists the expected sections', (tester) async {
    await tester.pumpWidget(
      MaterialApp(theme: AmoreTheme.theme(), home: const SettingsPage()),
    );

    for (final label in [
      'Providers & API Keys',
      'Theme & Text Size',
      'Storage',
      'Agent Tools',
      'Skills',
      'Memory',
      'Amore',
    ]) {
      expect(find.text(label), findsOneWidget, reason: 'missing $label');
    }
  });

  testWidgets('appearance page switches the app theme mode', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AmoreTheme.theme(),
          home: const AppearancePage(),
        ),
      ),
    );

    expect(container.read(themeModeProvider), ThemeMode.system);
    await tester.tap(find.text('Dark'));
    await tester.pump();
    expect(container.read(themeModeProvider), ThemeMode.dark);
  });
}
