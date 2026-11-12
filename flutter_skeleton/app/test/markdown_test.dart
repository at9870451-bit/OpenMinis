import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:amore/core/theme/amore_theme.dart';
import 'package:amore/features/chat/markdown_message.dart';

void main() {
  Widget host(Widget child) => MaterialApp(
        theme: AmoreTheme.theme(),
        home: Scaffold(body: SingleChildScrollView(child: child)),
      );

  testWidgets('renders headings, lists and bold markdown', (tester) async {
    await tester.pumpWidget(host(const MarkdownMessage(
      text: '# Title\n\n- one\n- two\n\n**bold** text',
    )));
    await tester.pumpAndSettle();

    expect(find.text('Title'), findsOneWidget);
    expect(find.text('one'), findsOneWidget);
    expect(find.text('bold'), findsOneWidget);
  });

  testWidgets('renders a fenced code block with its language label',
      (tester) async {
    await tester.pumpWidget(host(const MarkdownMessage(
      text: '```dart\nvoid main() {}\n```',
    )));
    await tester.pumpAndSettle();

    expect(find.text('dart'), findsOneWidget);
    expect(find.textContaining('void main'), findsOneWidget);
  });

  testWidgets('renders inline and display math without falling back to raw text',
      (tester) async {
    await tester.pumpWidget(host(const MarkdownMessage(
      text: r'Energy $E=mc^2$ and:' '\n\n' r'$$\int_0^1 x^2 dx$$',
    )));
    await tester.pumpAndSettle();

    // Math.tex renders a widget; the raw dollar syntax must be gone.
    expect(find.textContaining(r'$E=mc^2$'), findsNothing);
  });
}
