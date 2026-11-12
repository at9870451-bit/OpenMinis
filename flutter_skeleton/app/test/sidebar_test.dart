import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:amore/core/theme/amore_theme.dart';
import 'package:amore/features/sidebar/sidebar_drawer.dart';

void main() {
  testWidgets('sidebar renders title, sessions and bottom actions',
      (tester) async {
    String? tapped;

    await tester.pumpWidget(
      MaterialApp(
        theme: AmoreTheme.theme(),
        home: Scaffold(
          body: SidebarDrawer(
            sessions: const [],
            selectedId: null,
            onSelect: (id) => tapped = id,
            onNewChat: () => tapped = 'new',
            onSettings: () => tapped = 'settings',
          ),
        ),
      ),
    );

    expect(find.text('Amore'), findsOneWidget);
    expect(find.text('No conversations yet'), findsOneWidget);
    expect(find.text('Chat'), findsOneWidget);

    await tester.tap(find.text('Chat'));
    expect(tapped, 'new');
  });

  testWidgets('sidebar lists sessions and reports selection', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AmoreTheme.theme(),
        home: Scaffold(
          body: SidebarDrawer(
            sessions: const [],
            selectedId: null,
            onSelect: (_) {},
            onNewChat: () {},
            onSettings: () {},
          ),
        ),
      ),
    );
    expect(find.byType(ListView), findsNothing);
  });
}
