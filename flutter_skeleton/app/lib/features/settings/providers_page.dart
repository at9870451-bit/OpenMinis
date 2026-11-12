import 'package:flutter/material.dart';

import '../../core/theme/amore_theme.dart';
import '../../src/rust/api/providers.dart';

/// Provider list. The catalog itself comes from the Rust core — Flutter only
/// renders it, so adding a provider never means touching Dart.
class ProvidersPage extends StatefulWidget {
  const ProvidersPage({super.key});

  @override
  State<ProvidersPage> createState() => _ProvidersPageState();
}

class _ProvidersPageState extends State<ProvidersPage> {
  late Future<List<ProviderInfo>> _providers;

  @override
  void initState() {
    super.initState();
    _providers = listProviders();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AmoreTheme.background,
      appBar: AppBar(
        backgroundColor: AmoreTheme.background,
        surfaceTintColor: Colors.transparent,
        title: const Text('Providers',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
        centerTitle: true,
      ),
      body: FutureBuilder<List<ProviderInfo>>(
        future: _providers,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(
              child: Text(
                '${snapshot.error}',
                style: const TextStyle(color: AmoreTheme.danger),
              ),
            );
          }
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final items = snapshot.data!;
          return ListView.separated(
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: items.length,
            separatorBuilder: (_, __) => const Divider(
              height: 0.5,
              indent: 20,
              color: AmoreTheme.separator,
            ),
            itemBuilder: (context, i) {
              final p = items[i];
              return ListTile(
                title: Text(
                  p.name,
                  style: const TextStyle(
                    fontSize: 16,
                    color: AmoreTheme.textPrimary,
                  ),
                ),
                subtitle: Text(
                  '${p.protocol.name} · ${p.baseUrl}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    color: AmoreTheme.textSecondary,
                  ),
                ),
                trailing: const Icon(
                  Icons.chevron_right,
                  size: 18,
                  color: AmoreTheme.textSecondary,
                ),
                onTap: () {},
              );
            },
          );
        },
      ),
    );
  }
}
