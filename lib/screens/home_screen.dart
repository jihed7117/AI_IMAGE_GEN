import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import 'gallery_screen.dart';
import 'generate_screen.dart';
import 'settings_screen.dart';

/// Main shell with the three-tab navigation.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _index = 0;

  static const _titles = ['Generate', 'Gallery', 'Engine'];

  @override
  Widget build(BuildContext context) {
    final body = switch (_index) {
      0 => const GenerateScreen(),
      1 => const GalleryScreen(),
      _ => const SettingsScreen(),
    };
    return Scaffold(
      appBar: AppBar(
        title: Text(_titles[_index]),
        centerTitle: false,
        actions: const [_StatsChip()],
      ),
      body: body,
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.auto_awesome_outlined),
            selectedIcon: Icon(Icons.auto_awesome),
            label: 'Generate',
          ),
          NavigationDestination(
            icon: Icon(Icons.photo_library_outlined),
            selectedIcon: Icon(Icons.photo_library),
            label: 'Gallery',
          ),
          NavigationDestination(
            icon: Icon(Icons.tune),
            label: 'Engine',
          ),
        ],
      ),
    );
  }
}

/// Compact live CPU / RAM / GPU monitor shown in the app bar. Rebuilds only
/// itself (via [ValueListenableBuilder]) so the 2s stats polls never rebuild
/// the whole screen. Tapping it opens a details sheet.
class _StatsChip extends StatelessWidget {
  const _StatsChip();

  static String _fmtBytes(int bytes) {
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
    }
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).round()} MB';
    }
    if (bytes >= 1024) return '${(bytes / 1024).round()} KB';
    return '$bytes B';
  }

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return ValueListenableBuilder<DeviceStats?>(
      valueListenable: app.statsNotifier,
      builder: (context, stats, _) {
        if (stats == null) return const SizedBox.shrink();
        final provider = app.inferenceProvider(app.selectedModel.id);
        final accelerated = provider != null && !provider.contains('CPU');
        final ramColor = stats.lowMemory
            ? theme.colorScheme.error
            : muted;
        return Padding(
          padding: const EdgeInsets.only(right: 8),
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: () => _showStatsSheet(context, app, stats),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(14),
              ),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.speed, size: 14, color: muted),
                    const SizedBox(width: 3),
                    Text('${stats.cpuPercent.round()}%',
                        style: theme.textTheme.labelSmall),
                    const SizedBox(width: 8),
                    Icon(Icons.memory, size: 14, color: ramColor),
                    const SizedBox(width: 3),
                    Text(
                      '${_fmtBytes(stats.appRamBytes)} · '
                      '${_fmtBytes(stats.availMem)} free',
                      style: theme.textTheme.labelSmall,
                    ),
                    const SizedBox(width: 8),
                    Icon(Icons.bolt,
                        size: 14,
                        color: accelerated
                            ? Colors.green.shade400
                            : muted),
                    const SizedBox(width: 3),
                    Text(accelerated ? 'GPU' : 'CPU',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: accelerated
                              ? Colors.green.shade400
                              : muted,
                          fontWeight: accelerated
                              ? FontWeight.w600
                              : FontWeight.w400,
                        )),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  void _showStatsSheet(BuildContext context, AppState app, DeviceStats stats) {
    final provider =
        app.inferenceProvider(app.selectedModel.id) ?? 'Not loaded yet';
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) {
        final theme = Theme.of(ctx);
        final muted = theme.colorScheme.onSurfaceVariant;
        Widget row(String label, String value, {Color? valueColor}) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                Expanded(
                    child: Text(label,
                        style: theme.textTheme.bodyMedium
                            ?.copyWith(color: muted))),
                Text(value,
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(color: valueColor)),
              ],
            ),
          );
        }

        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Device stats', style: theme.textTheme.titleMedium),
                const SizedBox(height: 8),
                row('App memory', _fmtBytes(stats.appRamBytes)),
                row(
                  'Device free / total',
                  '${_fmtBytes(stats.availMem)} / '
                      '${_fmtBytes(stats.totalMem)}',
                  valueColor:
                      stats.lowMemory ? theme.colorScheme.error : null,
                ),
                row('CPU usage',
                    '${stats.cpuPercent.toStringAsFixed(1)}% of one core'),
                row(
                  'Inference provider',
                  provider,
                  valueColor: provider.contains('CPU')
                      ? null
                      : Colors.green.shade600,
                ),
                const SizedBox(height: 8),
                Text(
                  'RAM = this app + free device memory. GPUs do not expose a '
                  'utilization percentage, so GPU shows the active inference '
                  'accelerator (CoreML/NNAPI) instead.',
                  style: theme.textTheme.bodySmall?.copyWith(color: muted),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
