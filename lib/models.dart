import 'dart:io';

/// State of a model download.
enum DownloadState { none, running, paused, completed, failed, cancelled }

DownloadState downloadStateFromName(String? name) {
  switch (name) {
    case 'running':
      return DownloadState.running;
    case 'paused':
      return DownloadState.paused;
    case 'completed':
      return DownloadState.completed;
    case 'failed':
      return DownloadState.failed;
    case 'cancelled':
      return DownloadState.cancelled;
    default:
      return DownloadState.none;
  }
}

String downloadStateName(DownloadState s) {
  switch (s) {
    case DownloadState.running:
      return 'running';
    case DownloadState.paused:
      return 'paused';
    case DownloadState.completed:
      return 'completed';
    case DownloadState.failed:
      return 'failed';
    case DownloadState.cancelled:
      return 'cancelled';
    case DownloadState.none:
      return 'none';
  }
}

/// Reads a numeric value tolerantly. Older manifests persisted some numbers
/// as strings (e.g. `"2.10"`), which would otherwise throw on `as num?`.
num? _num(dynamic value) {
  if (value is num) return value;
  if (value is String) return num.tryParse(value);
  return null;
}

/// Reads a string value tolerantly. A malformed manifest (e.g. a numeric
/// `id` or `name`) should degrade to a fallback instead of crashing the
/// whole model list with a type-cast error.
String _str(dynamic value, String fallback) {
  if (value is String) return value;
  if (value is num || value is bool) return value.toString();
  return fallback;
}

/// A single file of a model (e.g. `unet/model.onnx`).
class ModelFile {
  final String path;
  final String url;
  final int size;
  final String? sha256;

  const ModelFile({
    required this.path,
    required this.url,
    this.size = 0,
    this.sha256,
  });

  factory ModelFile.fromJson(Map<String, dynamic> j) => ModelFile(
        path: _str(j['path'], ''),
        url: _str(j['url'], ''),
        size: _num(j['size'])?.toInt() ?? 0,
        sha256: j['sha256'] is String ? j['sha256'] as String : null,
      );

  Map<String, dynamic> toJson() => {
        'path': path,
        'url': url,
        'size': size,
        if (sha256 != null) 'sha256': sha256,
      };
}

/// A diffusion model (SD 1.5 / SDXL / custom). Backed by a JSON manifest
/// which doubles as the on-device config used by the generation engine.
class ModelSpec {
  final Map<String, dynamic> manifest;

  ModelSpec(this.manifest);

  factory ModelSpec.fromJson(Map<String, dynamic> j) => ModelSpec(j);

  Map<String, dynamic> toJson() => manifest;

  String get id => _str(manifest['id'], 'unknown');
  String get name => _str(manifest['name'], id);
  String get family => _str(manifest['family'], 'sd15');
  String get dtype => _str(manifest['dtype'], 'fp32');
  int get resolution => _num(manifest['resolution'])?.toInt() ?? 512;
  int get storageGb => _num(manifest['storage_gb'])?.toInt() ?? 4;
  int get ramGb => _num(manifest['ram_gb'])?.toInt() ?? 4;
  bool get isCustom => manifest['custom'] == true;
  String get sourceUrl => _str(manifest['source_url'], '');
  String get samplePrompt => _str(manifest['sample_prompt'], '');
  String get notes => _str(manifest['notes'], '');
  double get vaeScale => _num(manifest['vae_scale'])?.toDouble() ?? 0.18215;
  int get maxLength => _num(manifest['maxLength'])?.toInt() ?? 77;
  int get latentChannels => _num(manifest['latentChannels'])?.toInt() ?? 4;
  int get latentSize => resolution ~/ 8;

  bool get isSdxl => family == 'sdxl';

  /// True for models with the LCM-LoRA adapter baked into the UNet (e.g. the
  /// bundle produced by tools/build_lcm_sd15.py). They generate in ~4 steps
  /// with a low CFG scale, which the app applies automatically.
  bool get lcm => manifest['lcm'] == true;

  /// False for models imported from device whose files are ONNX-unconvertible
  /// weights (e.g. .safetensors/.ckpt): the files are stored locally but the
  /// engine cannot run them yet.
  bool get runnable => manifest['runnable'] != false;

  /// File entries of the manifest. Malformed entries (non-map values, or
  /// maps missing `path`/`url`) are skipped instead of throwing, so a bad
  /// custom manifest cannot take down the whole model list.
  List<ModelFile> get files {
    final raw = manifest['files'];
    if (raw is! List) return const [];
    return [
      for (final e in raw)
        if (e is Map)
          ModelFile.fromJson(e.map((k, v) => MapEntry('$k', v))),
    ];
  }

  Map<String, dynamic> get schedulerConfig {
    final s = manifest['scheduler'];
    if (s is Map) return s.map((k, v) => MapEntry('$k', v));
    return const {};
  }

  int get totalBytes => files.fold(0, (a, f) => a + f.size);

  /// Engine config passed to the generation worker isolate.
  Map<String, dynamic> get engineConfig {
    final cfg = <String, dynamic>{
      'id': id,
      'family': family,
      'dtype': dtype,
      'resolution': resolution,
      'latentChannels': latentChannels,
      'maxLength': maxLength,
      'vaeScale': vaeScale,
      'textDim': isSdxl ? 2048 : 768,
      'scheduler': schedulerConfig,
    };
    return cfg;
  }

  /// True when every expected model file already exists on disk, i.e. the
  /// model is ready to run.
  ///
  /// The downloader only renames a `.part` file to its final name once the
  /// whole file has been written (checked against the server's Content-Length),
  /// so a file present on disk is complete. Manifest sizes can drift upstream,
  /// so presence is checked instead of exact byte sizes.
  bool filesPresent(String rootDir) {
    for (final f in files) {
      final file = File('$rootDir/${f.path}');
      if (!file.existsSync()) return false;
      if (f.size > 0 && file.lengthSync() <= 0) return false;
    }
    return true;
  }

  /// True when at least one file is present (used to decide resume vs fresh).
  bool anyFilePresent(String rootDir) {
    for (final f in files) {
      if (File('$rootDir/${f.path}').existsSync()) return true;
    }
    return false;
  }

  /// Returns a human-readable description of the first expected file that is
  /// missing on disk under [rootDir], or null when every file is present.
  /// Useful to explain why [filesPresent] is false.
  String? firstIncompleteFile(String rootDir) {
    for (final f in files) {
      final file = File('$rootDir/${f.path}');
      if (!file.existsSync()) return '${f.path} (missing)';
      if (f.size > 0 && file.lengthSync() <= 0) {
        return '${f.path} (empty)';
      }
    }
    return null;
  }
}

/// Generation parameters the user can tweak (persisted).
class GenerationParams {
  int steps;
  double cfgScale;
  int seed; // -1 => random
  String negativePrompt;
  String sampler; // 'DDIM' | 'Euler'

  GenerationParams({
    this.steps = 25,
    this.cfgScale = 7.5,
    this.seed = -1,
    this.negativePrompt = '',
    this.sampler = 'DDIM',
  });

  GenerationParams copy() => GenerationParams(
        steps: steps,
        cfgScale: cfgScale,
        seed: seed,
        negativePrompt: negativePrompt,
        sampler: sampler,
      );

  factory GenerationParams.fromJson(Map<String, dynamic> j) => GenerationParams(
        steps: (j['steps'] as num?)?.toInt() ?? 25,
        cfgScale: (j['cfgScale'] as num?)?.toDouble() ?? 7.5,
        seed: (j['seed'] as num?)?.toInt() ?? -1,
        negativePrompt: j['negativePrompt'] as String? ?? '',
        sampler: j['sampler'] as String? ?? 'DDIM',
      );

  Map<String, dynamic> toJson() => {
        'steps': steps,
        'cfgScale': cfgScale,
        'seed': seed,
        'negativePrompt': negativePrompt,
        'sampler': sampler,
      };
}

/// One saved image in the gallery.
class GalleryItem {
  final int id;
  final String path;
  final String prompt;
  final String negativePrompt;
  final String modelId;
  final int seed;
  final int steps;
  final double cfg;
  final String sampler;
  final String resolution;
  final bool favorite;
  final DateTime createdAt;

  const GalleryItem({
    this.id = 0,
    required this.path,
    required this.prompt,
    this.negativePrompt = '',
    this.modelId = '',
    this.seed = 0,
    this.steps = 0,
    this.cfg = 0,
    this.sampler = '',
    this.resolution = '',
    this.favorite = false,
    required this.createdAt,
  });

  GalleryItem copyWith({bool? favorite}) => GalleryItem(
        id: id,
        path: path,
        prompt: prompt,
        negativePrompt: negativePrompt,
        modelId: modelId,
        seed: seed,
        steps: steps,
        cfg: cfg,
        sampler: sampler,
        resolution: resolution,
        favorite: favorite ?? this.favorite,
        createdAt: createdAt,
      );

  factory GalleryItem.fromMap(Map<String, dynamic> m) => GalleryItem(
        id: m['id'] as int,
        path: m['path'] as String,
        prompt: m['prompt'] as String? ?? '',
        negativePrompt: m['negative_prompt'] as String? ?? '',
        modelId: m['model_id'] as String? ?? '',
        seed: m['seed'] as int? ?? 0,
        steps: m['steps'] as int? ?? 0,
        cfg: (m['cfg'] as num?)?.toDouble() ?? 0,
        sampler: m['sampler'] as String? ?? '',
        resolution: m['resolution'] as String? ?? '',
        favorite: (m['favorite'] as int? ?? 0) == 1,
        createdAt:
            DateTime.fromMillisecondsSinceEpoch(m['created_at'] as int? ?? 0),
      );

  Map<String, dynamic> toMap() => {
        'id': id,
        'path': path,
        'prompt': prompt,
        'negative_prompt': negativePrompt,
        'model_id': modelId,
        'seed': seed,
        'steps': steps,
        'cfg': cfg,
        'sampler': sampler,
        'resolution': resolution,
        'favorite': favorite ? 1 : 0,
        'created_at': createdAt.millisecondsSinceEpoch,
      };
}

/// Progress events from the generation engine.
class GenProgress {
  final String stage; // 'loading' | 'text_encoder' | 'sampling' | 'vae' | 'saving'
  final int step;
  final int total;
  const GenProgress(this.stage, this.step, this.total);
}

class GenResult {
  final String path;
  final Duration elapsed;
  const GenResult(this.path, this.elapsed);
}

class GenError {
  final String message;
  const GenError(this.message);
}
