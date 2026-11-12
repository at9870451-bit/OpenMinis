import 'package:flutter/material.dart';
import 'package:flutter_highlight/flutter_highlight.dart';
import 'package:flutter_highlight/themes/atom-one-light.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_math_fork/flutter_math.dart';

import '../../core/theme/amore_theme.dart';

/// Assistant message renderer: Markdown + fenced code highlighting + LaTeX.
///
/// Inline/display math is split out first and rendered by flutter_math_fork,
/// because flutter_markdown has no math support; everything else goes through
/// MarkdownBody so headings, lists, tables and code all behave natively.
class MarkdownMessage extends StatelessWidget {
  const MarkdownMessage({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final blocks = _splitMath(text);
    if (blocks.length == 1 && blocks.first.math == null) {
      return _markdown(blocks.first.text);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final b in blocks)
          if (b.math != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Math.tex(
                b.math!,
                mathStyle: b.display ? MathStyle.display : MathStyle.text,
                textStyle: const TextStyle(
                  fontSize: 16,
                  color: AmoreTheme.textPrimary,
                ),
                onErrorFallback: (err) => Text(
                  b.math!,
                  style: const TextStyle(
                    fontFamily: 'Menlo',
                    fontSize: 14,
                    color: AmoreTheme.danger,
                  ),
                ),
              ),
            )
          else if (b.text.trim().isNotEmpty)
            _markdown(b.text),
      ],
    );
  }

  Widget _markdown(String source) {
    return MarkdownBody(
      data: source,
      selectable: true,
      styleSheet: MarkdownStyleSheet(
        p: const TextStyle(
          fontSize: 16,
          height: 1.45,
          color: AmoreTheme.textPrimary,
        ),
        h1: const TextStyle(
            fontSize: 22, fontWeight: FontWeight.w700, color: AmoreTheme.textPrimary),
        h2: const TextStyle(
            fontSize: 19, fontWeight: FontWeight.w600, color: AmoreTheme.textPrimary),
        h3: const TextStyle(
            fontSize: 17, fontWeight: FontWeight.w600, color: AmoreTheme.textPrimary),
        code: const TextStyle(
          fontFamily: 'Menlo',
          fontSize: 13.5,
          color: AmoreTheme.textPrimary,
        ),
        codeblockDecoration: BoxDecoration(
          color: AmoreTheme.secondaryBackground,
          borderRadius: BorderRadius.circular(12),
        ),
        blockquoteDecoration: BoxDecoration(
          color: AmoreTheme.secondaryBackground,
          borderRadius: BorderRadius.circular(8),
        ),
        tableBorder: TableBorder.all(color: AmoreTheme.separator, width: 0.5),
        listBullet: const TextStyle(fontSize: 16, color: AmoreTheme.textPrimary),
        horizontalRuleDecoration: const BoxDecoration(
          border: Border(top: BorderSide(color: AmoreTheme.separator)),
        ),
      ),
      builders: {'code': _HighlightedCodeBuilder()},
    );
  }

  /// Splits `$$…$$` (display) and `$…$` (inline) out of the markdown source.
  static List<_MathBlock> _splitMath(String source) {
    final pattern = RegExp(r'\$\$([\s\S]+?)\$\$|\$([^$\n]+?)\$');
    final out = <_MathBlock>[];
    var last = 0;

    for (final m in pattern.allMatches(source)) {
      if (m.start > last) {
        out.add(_MathBlock.text(source.substring(last, m.start)));
      }
      final display = m.group(1);
      out.add(_MathBlock.math(display ?? m.group(2)!, display: display != null));
      last = m.end;
    }
    if (last < source.length) {
      out.add(_MathBlock.text(source.substring(last)));
    }
    return out.isEmpty ? [_MathBlock.text(source)] : out;
  }
}

class _MathBlock {
  _MathBlock.text(this.text)
      : math = null,
        display = false;
  _MathBlock.math(this.math, {required this.display}) : text = '';

  final String text;
  final String? math;
  final bool display;
}

class _HighlightedCodeBuilder extends MarkdownElementBuilder {
  @override
  Widget? visitElementAfter(dynamic element, TextStyle? preferredStyle) {
    final rawClass = element.attributes['class'] as String?;
    final language = rawClass?.replaceFirst('language-', '') ?? 'plaintext';
    final code = (element.textContent as String).trimRight();

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        color: AmoreTheme.secondaryBackground,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AmoreTheme.separator, width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (language != 'plaintext')
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: Text(
                language,
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: AmoreTheme.textSecondary,
                ),
              ),
            ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.all(12),
            child: HighlightView(
              code,
              language: language,
              theme: atomOneLightTheme,
              padding: EdgeInsets.zero,
              textStyle: const TextStyle(
                fontFamily: 'Menlo',
                fontSize: 13,
                height: 1.45,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
