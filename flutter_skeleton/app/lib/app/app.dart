import 'package:flutter/material.dart';

import '../core/theme/amore_theme.dart';
import 'home_shell.dart';

class AmoreApp extends StatelessWidget {
  const AmoreApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Amore',
      debugShowCheckedModeBanner: false,
      theme: AmoreTheme.theme(),
      home: const HomeShell(),
    );
  }
}
