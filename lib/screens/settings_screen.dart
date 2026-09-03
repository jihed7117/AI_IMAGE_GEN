import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../download_controller.dart';
import '../model_registry.dart';
import '../models.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController _negativeController;
  late final TextEditingController _seedController;

  @override
  void initState() {
    super.initState();
    final params = context.read<AppState>().params;
    _negativeController = TextEditingController(text: params.negativePrompt);
    _seedController = TextEditingController(text: '${params.seed}');
  }

  @override
  void dispose() {
    _negativeController.dispose();
    _seedController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Models', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        for (final model in app.registry.all) _ModelCard(model: model),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              onPressed: () => _showImportDialog(context),
              icon: const Icon(Icons.link),
              label: const Text('Import from manifest URL'),
            ),
            OutlinedButton.icon(
              onPressed: () => _pickAndImportDeviceFiles(context),
              icon: const Icon(Icons.folder_open),
              label: const Text('Load Model from Device'),
            ),
          ],
        ),
        const SizedBox(height: 24),
        Text('Generation defaults',
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        _buildDefaults(app),
        const SizedBox(height: 24),
        Text('Inference', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        _buildInference(app),
        const SizedBox(height: 24),
        Text('About', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        const Card(
          child: ListTile(
            leading: Icon(Icons.info_outline),
            title: Text('AI Image Gen'),
            subtitle: Text(
                'Runs Stable Diffusion 1.5 and SDXL entirely on-device.\n'
                'Models download to your device and inference uses '
                'ONNX Runtime. Generation times scale with your device.'),
          ),
        ),
      ],
    );
  }

  // ------------------------------------------------------------ defaults

  Widget _buildDefaults(AppState app) {
    final params = app.params;
    final theme = Theme.of(context);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              key: const ValueKey('negative_prompt'),
              controller: _negativeController,
              decoration: const InputDecoration(
                labelText: 'Negative prompt (default)',
                hintText: 'blurry, low quality, distorted',
                border: OutlineInputBorder(),
                alignLabelWithHint: true,
              ),
              minLines: 2,
              maxLines: 4,
              onChanged: (v) => app.updateParams(params.copy()..negativePrompt = v),
            ),
            const SizedBox(height: 14),
            Text('Steps: ${params.steps}',
                style: theme.textTheme.labelMedium),
            Slider(
              value: params.steps.toDouble(),
              min: 5,
              max: 50,
              divisions: 45,
              label: '${params.steps}',
              onChanged: (v) => app.updateParams(params.copy()..steps = v.round()),
            ),
            Text('CFG scale: ${params.cfgScale.toStringAsFixed(1)}',
                style: theme.textTheme.labelMedium),
            Slider(
              value: params.cfgScale,
              min: 1,
              max: 15,
              divisions: 140,
              label: params.cfgScale.toStringAsFixed(1),
              onChanged: (v) => app.updateParams(params.copy()..cfgScale = v),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    key: ValueKey('sampler-${params.sampler}'),
                    initialValue: params.sampler,
                    decoration: const InputDecoration(
                        labelText: 'Sampler', border: OutlineInputBorder()),
                    items: const [
                      DropdownMenuItem(
                          value: 'DDIM', child: Text('DDIM (fast)')),
                      DropdownMenuItem(value: 'Euler', child: Text('Euler')),
                    ],
                    onChanged: (v) {
                      if (v == null) return;
                      app.updateParams(params.copy()..sampler = v);
                    },
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    key: const ValueKey('seed'),
                    controller: _seedController,
                    decoration: const InputDecoration(
                      labelText: 'Seed (-1 = random)',
                      border: OutlineInputBorder(),
                    ),
                    keyboardType: TextInputType.number,
                    onChanged: (v) => app.updateParams(
                        params.copy()..seed = int.tryParse(v) ?? -1),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ------------------------------------------------------------ inference

  Widget _buildInference(AppState app) {
    final theme = Theme.of(context);
    final model = app.selectedModel;
    final provider = app.inferenceProvider(model.id);
    return Card(
      child: Column(
        children: [
          SwitchListTile(
            key: const ValueKey('force_cpu'),
            title: const Text('Force CPU inference'),
            subtitle: const Text(
                'Disables GPU/NPU acceleration (CoreML on iOS, NNAPI on '
                'Android). Turn off to measure accelerated speed, on for a '
                'CPU baseline — then compare the [benchmark] log lines.'),
            value: app.forceCpuInference,
            onChanged: (v) => app.setForceCpuInference(v),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.speed),
            title: const Text('Inference provider'),
            subtitle: Text(
              provider ??
                  'Not loaded yet — loads after the model is downloaded '
                      'or generated with.',
            ),
            trailing: provider != null
                ? Icon(Icons.check_circle,
                    color: provider.contains('CPU')
                        ? theme.colorScheme.onSurfaceVariant
                        : Colors.green.shade600)
                : null,
          ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------- imports

  void _showImportDialog(BuildContext context) {
    final controller = TextEditingController();
    final app = context.read<AppState>();
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Import model'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
                'Paste a URL to a JSON manifest describing a custom Stable '
                'Diffusion ONNX model (see tools/import_model.py).'),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              decoration: const InputDecoration(
                labelText: 'Manifest URL',
                hintText: 'https://example.com/model.json',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel')),
          FilledButton(
            onPressed: () async {
              final url = controller.text.trim();
              if (url.isEmpty) return;
              try {
                await app.importCustomModel(url);
                if (ctx.mounted) Navigator.of(ctx).pop();
              } catch (e) {
                if (ctx.mounted) {
                  ScaffoldMessenger.of(ctx).showSnackBar(
                      SnackBar(content: Text('Import failed: $e')));
                }
              }
            },
            child: const Text('Import'),
          ),
        ],
      ),
    );
  }

  Future<void> _pickAndImportDeviceFiles(BuildContext context) async {
    FilePickerResult? result;
    try {
      result = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        type: FileType.custom,
        allowedExtensions: [
          'onnx', 'safetensors', 'ckpt', 'bin', 'pb', 'json', 'txt',
        ],
      );
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('File picker failed: $e')));
      }
      return;
    }
    if (result == null || result.files.isEmpty) return;
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => _DeviceImportDialog(files: result!.files),
    );
  }
}

/// Which part of an ONNX Stable Diffusion model a picked file represents.
enum _DeviceRole {
  unassigned('Unassigned', null),
  textEncoder('Text encoder', 'text_encoder/model.onnx'),
  textEncoder2('Text encoder 2', 'text_encoder_2/model.onnx'),
  unet('UNet', 'unet/model.onnx'),
  unetWeights('UNet weights (external .pb)', 'unet/weights.pb'),
  unetData('UNet weights (.onnx_data)', 'unet/model.onnx_data'),
  vae('VAE decoder', 'vae_decoder/model.onnx'),
  vocab('Tokenizer vocab', 'tokenizer/vocab.json'),
  merges('Tokenizer merges', 'tokenizer/merges.txt');

  final String label;
  final String? target;

  const _DeviceRole(this.label, this.target);

  static _DeviceRole guess(String fileName) {
    final n = fileName.toLowerCase();
    if (n.contains('text_encoder_2') || n.contains('clip_g')) {
      return _DeviceRole.textEncoder2;
    }
    if (n.contains('text_encoder') || n.contains('clip_l')) {
      return _DeviceRole.textEncoder;
    }
    // External-data weight blobs must land next to their model.onnx (the
    // engine loads unet/model.onnx + unet/weights.pb / unet/model.onnx_data).
    if (n.contains('weights.pb') || n.contains('weights.bin')) {
      return _DeviceRole.unetWeights;
    }
    if (n.contains('onnx_data')) return _DeviceRole.unetData;
    if (n.contains('unet')) return _DeviceRole.unet;
    if (n.contains('vae')) return _DeviceRole.vae;
    if (n.contains('vocab')) return _DeviceRole.vocab;
    if (n.contains('merges')) return _DeviceRole.merges;
    return _DeviceRole.unassigned;
  }
}

/// Dialog letting the user assign each picked file a role and import them.
class _DeviceImportDialog extends StatefulWidget {
  final List<PlatformFile> files;
  const _DeviceImportDialog({required this.files});

  @override
  State<_DeviceImportDialog> createState() => _DeviceImportDialogState();
}

class _DeviceImportDialogState extends State<_DeviceImportDialog> {
  late final TextEditingController _nameController;
  late final List<_DeviceRole> _roles;
  late int _resolution;

  bool get _runnable =>
      _roles.contains(_DeviceRole.unet) && _roles.contains(_DeviceRole.vae);

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController();
    _roles = [for (final f in widget.files) _DeviceRole.guess(f.name)];
    _resolution = 512;
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('Import files from device'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _nameController,
                decoration: const InputDecoration(
                  labelText: 'Model name',
                  hintText: 'e.g. My Custom SD 1.5',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              for (var i = 0; i < widget.files.length; i++) ...[
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        widget.files[i].name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                    const SizedBox(width: 8),
                    DropdownButton<_DeviceRole>(
                      value: _roles[i],
                      items: [
                        for (final r in _DeviceRole.values)
                          DropdownMenuItem(
                              value: r, child: Text(r.label)),
                      ],
                      onChanged: (r) {
                        if (r == null) return;
                        setState(() => _roles[i] = r);
                      },
                    ),
                  ],
                ),
                if (i != widget.files.length - 1)
                  const SizedBox(height: 8),
              ],
              const SizedBox(height: 16),
              Row(
                children: [
                  Text('Resolution', style: theme.textTheme.labelMedium),
                  const SizedBox(width: 12),
                  DropdownButton<int>(
                    value: _resolution,
                    items: const [
                      DropdownMenuItem(value: 512, child: Text('512×512')),
                      DropdownMenuItem(value: 768, child: Text('768×768')),
                      DropdownMenuItem(value: 1024, child: Text('1024×1024')),
                    ],
                    onChanged: (v) {
                      if (v == null) return;
                      setState(() => _resolution = v);
                    },
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (!_runnable)
                Text(
                  'No ONNX UNet + VAE decoder selected — the files will be '
                  'imported and stored, but this model cannot generate '
                  'on-device until the weights are converted to ONNX.',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.error),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel')),
        FilledButton(
          onPressed: () => _import(context),
          child: const Text('Import'),
        ),
      ],
    );
  }

  Future<void> _import(BuildContext context) async {
    final app = context.read<AppState>();
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Enter a model name first.')));
      return;
    }
    final files = <DeviceImportFile>[
      for (var i = 0; i < widget.files.length; i++)
        DeviceImportFile(
          widget.files[i].path!,
          _roles[i].target ?? widget.files[i].name,
        ),
    ];
    try {
      await app.importModelFromDevice(
        name: name,
        files: files,
        resolution: _resolution,
        runnable: _runnable,
      );
      if (context.mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Imported “$name”.')));
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Import failed: $e')));
      }
    }
  }
}

class _ModelCard extends StatelessWidget {
  final ModelSpec model;
  const _ModelCard({required this.model});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final downloaded = app.isModelDownloaded(model);
    final status = app.downloads.statusFor(model.id);
    final loadState = app.modelLoadState(model.id);
    final theme = Theme.of(context);

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(model.name,
                                style: theme.textTheme.titleSmall),
                          ),
                          if (model.isCustom) ...[
                            const SizedBox(width: 6),
                            const _CustomBadge(),
                          ],
                          if (model.lcm) ...[
                            const SizedBox(width: 6),
                            const _LcmBadge(),
                          ],
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${model.family.toUpperCase()} · ${model.dtype} · '
                        '${model.resolution}px · ~${model.storageGb}GB storage · '
                        '~${model.ramGb}GB RAM',
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                if (downloaded)
                  const Icon(Icons.check_circle, color: Colors.green, size: 22),
              ],
            ),
            const SizedBox(height: 8),
            _StatusArea(
              model: model,
              status: status,
              downloaded: downloaded,
              downloadedBytes: app.modelDownloadedBytes(model),
            ),
            if (!downloaded) ...[
              const SizedBox(height: 6),
              Builder(builder: (context) {
                final missing = app.modelIncompleteFile(model);
                if (missing == null) return const SizedBox.shrink();
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Incomplete: $missing',
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: theme.colorScheme.error)),
                    const SizedBox(height: 4),
                    TextButton.icon(
                      key: ValueKey('download_missing_${model.id}'),
                      onPressed: () => app.downloadModel(model),
                      icon: const Icon(Icons.download, size: 16),
                      label: const Text('Download missing file'),
                      style: TextButton.styleFrom(
                        padding: EdgeInsets.zero,
                        minimumSize: const Size(0, 32),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        alignment: Alignment.centerLeft,
                      ),
                    ),
                  ],
                );
              }),
            ],
            if (downloaded) ...[
              const SizedBox(height: 6),
              _LoadStatusRow(
                runnable: model.runnable,
                loadState: loadState,
                error: app.modelLoadError(model.id),
              ),
            ],
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: _actions(context, app, downloaded, status),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _actions(BuildContext context, AppState app, bool downloaded,
      ModelDownloadStatus status) {
    final widgets = <Widget>[];
    final started = status.state != DownloadState.none;
    final loadState = app.modelLoadState(model.id);
    switch (status.state) {
      case DownloadState.running:
        widgets.addAll([
          OutlinedButton.icon(
            onPressed: () => app.pauseDownload(model.id),
            icon: const Icon(Icons.pause),
            label: const Text('Pause'),
          ),
          OutlinedButton.icon(
            onPressed: () => app.cancelDownload(model.id),
            icon: const Icon(Icons.close),
            label: const Text('Cancel'),
          ),
        ]);
      case DownloadState.paused:
        widgets.addAll([
          FilledButton.tonalIcon(
            onPressed: () => app.resumeDownload(model.id),
            icon: const Icon(Icons.play_arrow),
            label: const Text('Resume'),
          ),
          OutlinedButton.icon(
            onPressed: () => app.cancelDownload(model.id),
            icon: const Icon(Icons.close),
            label: const Text('Cancel'),
          ),
        ]);
      case DownloadState.failed:
      case DownloadState.cancelled:
        widgets.addAll([
          FilledButton.icon(
            onPressed: () => app.downloadModel(model),
            icon: const Icon(Icons.download),
            label: Text(_downloadLabel(app)),
          ),
          if (started)
            OutlinedButton.icon(
              onPressed: () => app.cancelDownload(model.id),
              icon: const Icon(Icons.close),
              label: const Text('Clear'),
            ),
        ]);
      case DownloadState.completed:
      case DownloadState.none:
        if (!downloaded) {
          widgets.add(FilledButton.icon(
            onPressed: () => app.downloadModel(model),
            icon: const Icon(Icons.download),
            label: Text(_downloadLabel(app)),
          ));
        } else {
          widgets.add(OutlinedButton.icon(
            onPressed: () => _confirmDelete(context, app),
            icon: const Icon(Icons.delete_outline),
            label: const Text('Delete files'),
          ));
        }
        if (started && status.state == DownloadState.failed) {
          widgets.add(OutlinedButton.icon(
            onPressed: () => app.cancelDownload(model.id),
            icon: const Icon(Icons.close),
            label: const Text('Clear'),
          ));
        }
    }
    // If files are missing but the persisted state says the download is still
    // running/paused (e.g. the app was killed mid-download and the service
    // died), the Pause/Resume buttons above can't help — the user would be
    // stuck with no way to re-download. Offer a restart: the native service
    // skips files already on disk, so it only fetches what's missing.
    if (!downloaded &&
        (status.state == DownloadState.running ||
            status.state == DownloadState.paused)) {
      widgets.add(OutlinedButton.icon(
        onPressed: () => app.downloadModel(model),
        icon: const Icon(Icons.replay),
        label: const Text('Restart download'),
      ));
    }
    // Manual fallback: if the files are on disk but auto-loading didn't bring
    // the engine into memory, let the user load it explicitly. Shown in every
    // state (completed, failed, cancelled, …) whenever the model is present.
    if (downloaded &&
        model.runnable &&
        status.state != DownloadState.running &&
        status.state != DownloadState.paused &&
        loadState != ModelLoadState.ready &&
        loadState != ModelLoadState.loading) {
      widgets.add(FilledButton.icon(
        onPressed: () => app.prewarmModel(model),
        icon: const Icon(Icons.play_arrow),
        label: const Text('Load'),
      ));
    }
    return widgets;
  }

  /// Download-button label that reflects partial progress: "Resume download
  /// (X GB left)" when some files are already on disk, plain "Download"
  /// otherwise. Tapping either one re-fetches only the missing files.
  String _downloadLabel(AppState app) {
    final have = app.modelDownloadedBytes(model);
    final totalGb =
        (model.totalBytes / (1024 * 1024 * 1024)).toStringAsFixed(1);
    if (have <= 0) return 'Download ($totalGb GB)';
    final missingGb =
        ((model.totalBytes - have) / (1024 * 1024 * 1024)).toStringAsFixed(1);
    return 'Resume download ($missingGb GB left)';
  }

  Future<void> _confirmDelete(BuildContext context, AppState app) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete model files?'),
        content: Text(
            'This removes the downloaded files for ${model.name}. '
            'You will need to download them again to generate.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true) await app.removeModel(model);
  }
}

/// Engine memory status for a downloaded model.
class _LoadStatusRow extends StatelessWidget {
  final bool runnable;
  final ModelLoadState loadState;
  final String? error;
  const _LoadStatusRow({
    required this.runnable,
    required this.loadState,
    required this.error,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (!runnable) {
      return Text('Stored on device · ONNX conversion needed to generate',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant));
    }
    final (IconData icon, String label, Color color) = switch (loadState) {
      ModelLoadState.ready => (
          Icons.check_circle,
          'Engine loaded in memory',
          Colors.green.shade700,
        ),
      ModelLoadState.loading => (
          Icons.hourglass_top,
          'Loading engine…',
          theme.colorScheme.primary,
        ),
      ModelLoadState.failed => (
          Icons.error_outline,
          'Engine failed to load',
          theme.colorScheme.error,
        ),
      ModelLoadState.notLoaded => (
          Icons.memory,
          'Engine not loaded',
          theme.colorScheme.onSurfaceVariant,
        ),
    };
    return Row(
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 6),
        Expanded(
          child: Text(label,
              style: theme.textTheme.bodySmall?.copyWith(color: color)),
        ),
      ],
    );
  }
}

class _StatusArea extends StatelessWidget {
  final ModelSpec model;
  final ModelDownloadStatus status;
  final bool downloaded;
  final int downloadedBytes;
  const _StatusArea({
    required this.model,
    required this.status,
    required this.downloaded,
    required this.downloadedBytes,
  });

  String _formatBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var value = bytes.toDouble();
    var i = 0;
    while (value >= 1024 && i < units.length - 1) {
      value /= 1024;
      i++;
    }
    return '${value.toStringAsFixed(1)} ${units[i]}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (downloaded) {
      return Text('Ready to use · ${_formatBytes(downloadedBytes)} on device',
          style: TextStyle(color: Colors.green.shade700));
    }
    final fraction = status.fraction;
    final running = status.state == DownloadState.running;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (status.currentFile.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(status.currentFile,
                style: theme.textTheme.bodySmall, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        Row(
          children: [
            Expanded(
              child: Text(
                running
                    ? '${_formatBytes(status.received)} / ${_formatBytes(status.total)}'
                    : _stateLabel(status),
                style: theme.textTheme.bodySmall,
              ),
            ),
          ],
        ),
        if (fraction != null) ...[
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
                value: fraction, minHeight: 6, backgroundColor: theme.colorScheme.surfaceContainerHighest),
          ),
        ],
        if (status.error.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(status.error,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.error),
                maxLines: 2,
                overflow: TextOverflow.ellipsis),
          ),
      ],
    );
  }

  String _stateLabel(ModelDownloadStatus status) {
    switch (status.state) {
      case DownloadState.running:
        return 'Downloading…';
      case DownloadState.paused:
        return 'Paused';
      case DownloadState.failed:
        return 'Failed';
      case DownloadState.cancelled:
        return 'Cancelled';
      case DownloadState.completed:
        return 'Completed';
      case DownloadState.none:
        return 'Not downloaded · ${_formatBytes(model.totalBytes)} to download';
    }
  }
}

class _CustomBadge extends StatelessWidget {
  const _CustomBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text('custom',
          style: Theme.of(context)
              .textTheme
              .labelSmall
              ?.copyWith(color: Theme.of(context).colorScheme.onSecondaryContainer)),
    );
  }
}

/// Badge for models with the LCM-LoRA baked in (generate in ~4 steps).
class _LcmBadge extends StatelessWidget {
  const _LcmBadge();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: scheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text('LCM · 4 steps',
          style: Theme.of(context)
              .textTheme
              .labelSmall
              ?.copyWith(color: scheme.onTertiaryContainer)),
    );
  }
}
