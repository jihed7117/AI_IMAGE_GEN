import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../models.dart';
import 'gallery_screen.dart';

class GenerateScreen extends StatefulWidget {
  const GenerateScreen({super.key});

  @override
  State<GenerateScreen> createState() => _GenerateScreenState();
}

class _GenerateScreenState extends State<GenerateScreen> {
  late final TextEditingController _promptController;

  @override
  void initState() {
    super.initState();
    _promptController =
        TextEditingController(text: context.read<AppState>().prompt);
  }

  @override
  void dispose() {
    _promptController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final model = app.selectedModel;
    final theme = Theme.of(context);

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _LatestImageCard(app: app),
        const SizedBox(height: 16),
        _ModelSelector(model: model),
        const SizedBox(height: 16),
        TextField(
          key: const ValueKey('prompt'),
          controller: _promptController,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Prompt',
            hintText: 'A majestic castle on a cliff at sunset…',
            border: OutlineInputBorder(),
            alignLabelWithHint: true,
          ),
          minLines: 3,
          maxLines: 6,
          onChanged: app.setPrompt,
        ),
        const SizedBox(height: 20),
        _buildGenButton(app, model, theme),
        if (app.gen.running || app.gen.error != null)
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: _ProgressPanel(app: app),
          ),
      ],
    );
  }

  Widget _buildGenButton(AppState app, ModelSpec model, ThemeData theme) {
    if (app.gen.running) {
      return FilledButton.icon(
        onPressed: app.cancelGeneration,
        icon: const Icon(Icons.stop),
        label: const Text('Stop generation'),
      );
    }
    final downloaded = app.isModelDownloaded(model);
    final runnable = model.runnable;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FilledButton.icon(
          onPressed: app.canGenerate ? app.generate : null,
          icon: const Icon(Icons.auto_awesome),
          label: Text(!downloaded
              ? 'Model not downloaded — go to Engine'
              : !runnable
                  ? 'Imported weights not runnable (need ONNX)'
                  : 'Generate (${model.resolution}×${model.resolution})'),
        ),
        const SizedBox(height: 12),
        _ModelLoadChip(app: app, model: model),
      ],
    );
  }
}

/// Shows whether the selected model's engine is loaded in memory.
class _ModelLoadChip extends StatelessWidget {
  final AppState app;
  final ModelSpec model;
  const _ModelLoadChip({required this.app, required this.model});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = app.modelLoadState(model.id);
    final (IconData icon, String label, Color color) = switch (state) {
      ModelLoadState.ready => (
          Icons.check_circle,
          'Model loaded',
          Colors.green.shade700,
        ),
      ModelLoadState.loading => (
          Icons.hourglass_top,
          'Loading model…',
          theme.colorScheme.primary,
        ),
      ModelLoadState.failed => (
          Icons.error_outline,
          'Model failed to load',
          theme.colorScheme.error,
        ),
      ModelLoadState.notLoaded => (
          Icons.memory,
          'Model not loaded — first generation will load it',
          theme.colorScheme.onSurfaceVariant,
        ),
    };
    final error = app.modelLoadError(model.id);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 16, color: color),
            const SizedBox(width: 6),
            Expanded(
              child: Text(label,
                  style: theme.textTheme.bodySmall?.copyWith(color: color)),
            ),
          ],
        ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(error,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.error),
                maxLines: 2,
                overflow: TextOverflow.ellipsis),
          ),
      ],
    );
  }
}

/// Preview of the most recently generated image, shown on the Generate tab so
/// the latest result is visible without switching to the Gallery tab. Tapping
/// it opens the full-screen viewer.
class _LatestImageCard extends StatelessWidget {
  final AppState app;
  const _LatestImageCard({required this.app});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final item = app.gallery.isEmpty ? null : app.gallery.first;
    if (item == null) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            children: [
              Icon(Icons.image_outlined,
                  size: 32, color: theme.colorScheme.outline),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Latest image', style: theme.textTheme.titleSmall),
                    const SizedBox(height: 2),
                    Text(
                      'Your generated image will appear here.',
                      style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    }
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => GalleryDetail(item: item)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AspectRatio(
              aspectRatio: 1,
              child: Image.file(
                File(item.path),
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => const ColoredBox(
                  color: Colors.black26,
                  child: Center(child: Icon(Icons.broken_image)),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Latest image',
                            style: theme.textTheme.labelMedium),
                        if (item.prompt.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(
                              item.prompt,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall,
                            ),
                          ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: Icon(Icons.share_outlined,
                        size: 20, color: theme.colorScheme.onSurfaceVariant),
                    tooltip: 'Share',
                    onPressed: () => app.shareImage(item.path),
                  ),
                  Icon(Icons.open_in_full,
                      size: 18, color: theme.colorScheme.onSurfaceVariant),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ModelSelector extends StatelessWidget {
  final ModelSpec model;
  const _ModelSelector({required this.model});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final models = app.registry.all;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Active model',
            style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 8),
        DropdownButtonFormField<String>(
          initialValue: model.id,
          decoration: const InputDecoration(border: OutlineInputBorder()),
          items: [
            for (final m in models)
              DropdownMenuItem(
                  value: m.id,
                  child: Text('${m.name} (${m.ramGb}GB RAM)')),
          ],
          onChanged: (id) {
            if (id != null) app.selectModel(id);
          },
        ),
        const SizedBox(height: 8),
        Text(
          model.notes,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
      ],
    );
  }
}

class _ProgressPanel extends StatelessWidget {
  final AppState app;
  const _ProgressPanel({required this.app});

  String get _stageText {
    final phase = app.gen.phase;
    switch (phase) {
      case GenPhase.loading:
        return 'Loading model…';
      case GenPhase.textEncoder:
        return 'Encoding prompt…';
      case GenPhase.sampling:
        return 'Sampling step ${app.gen.step}/${app.gen.total}';
      case GenPhase.vae:
        return 'Decoding image…';
      case GenPhase.saving:
        return 'Saving…';
      case GenPhase.idle:
        return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    final error = app.gen.error;
    if (error != null) {
      return Card(
        color: Theme.of(context).colorScheme.errorContainer,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Text(error,
              style: TextStyle(
                  color: Theme.of(context).colorScheme.onErrorContainer)),
        ),
      );
    }
    final phase = app.gen.phase;
    final total = app.gen.total;
    final showBar = phase == GenPhase.sampling && total > 0;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 12),
                Expanded(child: Text(_stageText)),
                if (app.gen.elapsed != null)
                  Text(
                    app.gen.elapsed!.inMinutes > 0
                        ? '${app.gen.elapsed!.inMinutes}m ${app.gen.elapsed!.inSeconds % 60}s'
                        : '${app.gen.elapsed!.inSeconds}s',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
              ],
            ),
            if (showBar) ...[
              const SizedBox(height: 12),
              LinearProgressIndicator(
                  value: app.gen.step / total, minHeight: 6),
            ],
          ],
        ),
      ),
    );
  }
}
