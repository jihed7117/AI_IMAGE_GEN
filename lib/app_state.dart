import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'database.dart';
import 'download_controller.dart';
import 'generation_worker.dart';
import 'model_registry.dart';
import 'models.dart';
import 'prefs.dart';

/// Phases of a generation run shown to the user.
enum GenPhase { idle, loading, textEncoder, sampling, vae, saving }

/// Whether a model's ONNX engine is resident in memory in the worker isolate.
enum ModelLoadState { notLoaded, loading, ready, failed }

/// Live device resource snapshot shown in the app-bar monitor.
class DeviceStats {
  /// This app's own RAM footprint in bytes (PSS on Android, resident size on
  /// iOS).
  final int appRamBytes;

  /// App CPU usage as a percentage of one core (from two cpuTimeNanos
  /// samples; 0 until the second poll).
  final double cpuPercent;

  /// Device free / total RAM in bytes.
  final int availMem;
  final int totalMem;
  final bool lowMemory;

  const DeviceStats({
    required this.appRamBytes,
    required this.cpuPercent,
    required this.availMem,
    required this.totalMem,
    required this.lowMemory,
  });
}

class GenStatus {
  final GenPhase phase;
  final int step;
  final int total;
  final String? error;
  final Duration? elapsed;
  final String? resultPath;
  final int? seed;
  final String? modelId;

  const GenStatus({
    this.phase = GenPhase.idle,
    this.step = 0,
    this.total = 0,
    this.error,
    this.elapsed,
    this.resultPath,
    this.seed,
    this.modelId,
  });

  bool get running => phase != GenPhase.idle;
}

/// Root application state; exposed through Provider.
class AppState extends ChangeNotifier {
  static const MethodChannel _systemChannel = MethodChannel('aiimagegen/system');

  late final AppPrefs prefs;
  late final ModelRegistry registry;
  late final GalleryDb db;
  late final DownloadController downloads;

  GenerationWorker? _worker;
  GenStatus gen = const GenStatus();
  int? _genReqId;
  String _prompt = '';

  final Map<String, ModelLoadState> _modelLoadStates = {};
  final Map<String, String> _modelLoadErrors = {};
  final Map<String, String> _modelProviders = {};
  final Map<String, String> _lastDownloadSig = {};

  /// Latest resource snapshot for the app-bar monitor (null until the first
  /// successful native query, e.g. never on desktop).
  final ValueNotifier<DeviceStats?> statsNotifier = ValueNotifier<DeviceStats?>(null);
  Timer? _statsTimer;
  int? _lastCpuWall;
  int? _lastCpuTime;

  List<GalleryItem> gallery = [];
  bool galleryFavoritesOnly = false;
  late String modelsRoot;

  String get prompt => _prompt;

  ModelLoadState modelLoadState(String id) =>
      _modelLoadStates[id] ?? ModelLoadState.notLoaded;

  String? modelLoadError(String id) => _modelLoadErrors[id];

  /// Label of the provider the model's engine loaded on (e.g.
  /// "NNAPI (GPU/NPU)"), or null before the first successful load.
  String? inferenceProvider(String id) => _modelProviders[id];

  /// When true, the engine is forced onto the CPU provider. Changing it
  /// reloads the selected model so the new setting takes effect immediately.
  bool get forceCpuInference => prefs.forceCpuInference;

  Future<void> setForceCpuInference(bool value) async {
    await prefs.setForceCpuInference(value);
    notifyListeners();
    final model = selectedModel;
    if (model.runnable && isModelDownloaded(model)) {
      // Evict the resident engine (loaded under the old setting) and reload
      // it under the new one.
      unawaited(unloadModel(model.id));
      unawaited(prewarmModel(model));
    }
  }

  /// True when every file of [model] is on disk under its model directory
  /// (`modelsRoot/<id>/…`).
  bool isModelDownloaded(ModelSpec model) =>
      model.filesPresent(p.join(modelsRoot, model.id));

  /// Explains why [isModelDownloaded] is false, or null when it is true.
  String? modelIncompleteFile(ModelSpec model) =>
      model.firstIncompleteFile(p.join(modelsRoot, model.id));

  Future<void> init() async {
    prefs = await AppPrefs.load();
    registry = ModelRegistry(prefs);
    db = GalleryDb();
    downloads = DownloadController(registry);
    _worker = await GenerationWorker.start();
    final root = await registry.modelRoot();
    modelsRoot = root.path;
    // Sample CPU/RAM every 2s for the app-bar monitor; the first sample is
    // taken immediately so the chip appears without waiting.
    _statsTimer = Timer.periodic(
        const Duration(seconds: 2), (_) => _pollStats());
    unawaited(_pollStats());
    await reloadGallery();
    // Load the selected model into memory right away so the first generation
    // is instant (no restart or extra tap needed).
    final selected = selectedModel;
    await _applyModelDefaults(selected);
    for (final model in registry.all) {
      _listenDownloadCompletion(model);
    }
    debugPrint('init: root=$modelsRoot selected=${selected.id} '
        'downloaded=${isModelDownloaded(selected)}');
    if (selected.runnable && isModelDownloaded(selected)) {
      unawaited(prewarmModel(selected));
    }
    // Ask for notification permission once on Android 13+.
    try {
      if (!prefs.notificationPermsRequested) {
        await _systemChannel.invokeMethod('requestNotificationPermission');
        await prefs.setNotificationPermsRequested();
      }
    } catch (_) {
      // Not supported on this platform; ignore.
    }
  }

  /// Prewarm automatically when a model finishes downloading, so generation
  /// can start instantly without a restart.
  ///
  /// Only real-time completions (observed while the app is running) always
  /// load the finished model. Persisted "completed" states caught up by the
  /// poller after a restart are only prewarmed for the selected model or when
  /// nothing else is resident yet — otherwise re-emitting every completed model
  /// would keep evicting the engine cache.
  void _listenDownloadCompletion(ModelSpec model) {
    downloads.streamFor(model.id).listen((status) {
      // Surface live download progress to the UI (e.g. the model card) by
      // notifying whenever the status actually changes.
      final sig = '${status.state}|${status.received}|${status.total}|'
          '${status.currentFile}|${status.error}';
      if (_lastDownloadSig[model.id] != sig) {
        _lastDownloadSig[model.id] = sig;
        notifyListeners();
      }
      if (status.state != DownloadState.completed) return;
      final state = _modelLoadStates[model.id];
      if (state == ModelLoadState.ready || state == ModelLoadState.loading) {
        return;
      }
      if (!status.isLive &&
          model.id != selectedModel.id &&
          _modelLoadStates.isNotEmpty) {
        return;
      }
      prewarmModel(model);
    });
  }

  // ------------------------------------------------------ resource monitor

  /// Queries the native side for a resource snapshot and publishes it to
  /// [statsNotifier]. CPU % is derived from the delta between two
  /// cpuTimeNanos/wallNanos samples, so it is 0 until the second poll.
  Future<void> _pollStats() async {
    try {
      final raw = await _systemChannel
          .invokeMapMethod<String, dynamic>('getStats');
      if (raw == null) return;
      final wall = (raw['wallNanos'] as num?)?.toInt() ?? 0;
      final cpu = (raw['cpuTimeNanos'] as num?)?.toInt() ?? 0;
      final lastWall = _lastCpuWall;
      final lastCpu = _lastCpuTime;
      _lastCpuWall = wall;
      _lastCpuTime = cpu;
      var cpuPercent = 0.0;
      if (lastWall != null && lastCpu != null && wall > lastWall) {
        cpuPercent = (cpu - lastCpu) / (wall - lastWall) * 100;
        if (cpuPercent < 0) cpuPercent = 0;
      }
      statsNotifier.value = DeviceStats(
        appRamBytes: (raw['appRamBytes'] as num?)?.toInt() ?? 0,
        cpuPercent: cpuPercent.clamp(0, 999),
        availMem: (raw['availMem'] as num?)?.toInt() ?? 0,
        totalMem: (raw['totalMem'] as num?)?.toInt() ?? 0,
        lowMemory: raw['lowMemory'] == true,
      );
    } catch (_) {
      // Channel not supported on this platform (e.g. desktop); keep the last
      // known value instead of crashing the app.
    }
  }

  // --------------------------------------------------------- device memory

  /// Queries the native side for a device-memory snapshot:
  /// `{availMem, totalMem, lowMemory}` (bytes). Returns null when the query
  /// is unsupported on this platform, so callers can skip the memory gate.
  Future<Map<String, dynamic>?> _systemMemory() async {
    try {
      return await _systemChannel
          .invokeMapMethod<String, dynamic>('getMemoryInfo');
    } catch (_) {
      return null;
    }
  }

  /// Returns an error message when the device likely does not have enough
  /// free memory to run [model] (per its manifest's `ram_gb` requirement),
  /// or null when memory is fine or cannot be measured.
  Future<String?> _memoryCheckError(ModelSpec model) async {
    final requiredBytes = model.ramGb <= 0 ? null : model.ramGb * (1 << 30);
    if (requiredBytes == null) return null;
    final info = await _systemMemory();
    if (info == null) return null;
    final availBytes = (info['availMem'] as num?)?.toDouble();
    if (availBytes == null || availBytes <= 0) return null;
    if (availBytes >= requiredBytes) return null;
    final needGb = (requiredBytes / (1 << 30)).toStringAsFixed(1);
    final haveGb = (availBytes / (1 << 30)).toStringAsFixed(1);
    return 'Not enough free memory to run this model: it needs ~$needGb GB '
        'free RAM but only ~$haveGb GB is available. Close other apps and '
        'try again.';
  }

  // ---------------------------------------------------------------- model

  ModelSpec get selectedModel {
    final id = prefs.selectedModelId;
    return registry.byId(id) ?? registry.defaultModel;
  }

  Future<void> selectModel(String id) async {
    await registry.setSelected(id);
    final model = registry.byId(id);
    if (model != null) {
      await _applyModelDefaults(model);
      unawaited(prewarmModel(model));
    }
    notifyListeners();
  }

  /// LCM models need a different recipe than plain SD: ~4 steps and a low CFG
  /// scale (the default 25 steps / CFG 7.5 produces garbage with the LCM
  /// adapter). Apply those defaults when an LCM model becomes active, unless
  /// the user has already tuned the params toward LCM values.
  Future<void> _applyModelDefaults(ModelSpec model) async {
    if (!model.lcm) return;
    final p = params;
    if (p.steps > 8 || p.cfgScale > 2.5) {
      await updateParams(p.copy()..steps = 4..cfgScale = 1.5);
    }
  }

  Future<void> importCustomModel(String url) async {
    await registry.importFromManifestUrl(url);
    notifyListeners();
  }

  /// Copies user-picked device files into app storage and registers the model.
  Future<void> importModelFromDevice({
    required String name,
    required List<DeviceImportFile> files,
    required int resolution,
    required bool runnable,
  }) async {
    final model = await registry.importFromDevice(
      name: name,
      files: files,
      resolution: resolution,
      runnable: runnable,
    );
    _listenDownloadCompletion(model);
    notifyListeners();
  }

  Future<void> removeModel(ModelSpec model) async {
    if (model.isCustom) {
      final manifests = prefs.customModels
          .where((m) => m['id'] != model.id)
          .toList();
      await prefs.saveCustomModels(manifests);
    }
    _modelLoadStates.remove(model.id);
    _modelLoadErrors.remove(model.id);
    _modelProviders.remove(model.id);
    unawaited(_worker?.unload(model.id));
    await downloads.clearState(model.id);
    await registry.deleteFromDisk(model);
    notifyListeners();
  }

  int modelDownloadedBytes(ModelSpec model) {
    var total = 0;
    for (final f in model.files) {
      final file = File('$modelsRoot/${model.id}/${f.path}');
      if (file.existsSync()) total += file.lengthSync();
    }
    return total;
  }

  // ---------------------------------------------------------------- params

  GenerationParams get params => prefs.params;

  Future<void> updateParams(GenerationParams next) async {
    await prefs.setParams(next);
    notifyListeners();
  }

  // ---------------------------------------------------------------- gallery

  Future<void> reloadGallery() async {
    gallery = await db.list(favoritesOnly: galleryFavoritesOnly);
    notifyListeners();
  }

  void setGalleryFavoritesOnly(bool value) {
    galleryFavoritesOnly = value;
    reloadGallery();
  }

  Future<void> toggleFavorite(GalleryItem item) async {
    await db.setFavorite(item.id, !item.favorite);
    await reloadGallery();
  }

  Future<void> deleteGalleryItem(GalleryItem item) async {
    await db.delete(item.id);
    try {
      final f = File(item.path);
      if (f.existsSync()) await f.delete();
    } catch (_) {
      // best effort
    }
    await reloadGallery();
  }

  /// Adds a just-generated image to the gallery.
  Future<void> addToGallery(String path, GenOutcome outcome, ModelSpec model) async {
    await db.insert(GalleryItem(
      path: path,
      prompt: _prompt,
      negativePrompt: params.negativePrompt,
      modelId: model.id,
      seed: outcome.seed,
      steps: params.steps,
      cfg: params.cfgScale,
      sampler: params.sampler,
      resolution: '${model.resolution}x${model.resolution}',
      createdAt: DateTime.now(),
    ));
    await reloadGallery();
  }

  // ------------------------------------------------------------ generation

  Future<Directory> galleryDir() async {
    final support = await getApplicationSupportDirectory();
    return Directory(p.join(support.path, 'gallery'))..createSync(recursive: true);
  }

  /// Copies a just-generated image into the device's system photo gallery,
  /// under `Pictures/AI Image Gen/`, so it shows up in the stock gallery app.
  /// Best-effort: failures are logged and never surfaced, because the image is
  /// always kept in the in-app gallery regardless.
  Future<void> saveImageToSystemGallery(String path) async {
    try {
      await _systemChannel.invokeMethod('saveImageToGallery', {'path': path});
    } catch (e) {
      debugPrint('saveImageToGallery failed: $e');
    }
  }

  /// Opens the system share sheet with the image at [path]. Returns false when
  /// the platform has no share support or the file is missing.
  Future<bool> shareImage(String path) async {
    try {
      final ok = await _systemChannel
          .invokeMethod<bool>('shareImage', {'path': path});
      return ok ?? false;
    } catch (e) {
      debugPrint('shareImage failed: $e');
      return false;
    }
  }

  bool get canGenerate =>
      !gen.running &&
      selectedModel.runnable &&
      isModelDownloaded(selectedModel);

  Future<void> generate() async {
    final model = selectedModel;
    final worker = _worker;
    if (worker == null) return;
    if (!isModelDownloaded(model)) {
      gen = const GenStatus(
          phase: GenPhase.idle, error: 'Model files are not downloaded yet.');
      notifyListeners();
      return;
    }
    if (!model.runnable) {
      gen = const GenStatus(
          phase: GenPhase.idle,
          error: 'This model was imported from device but its weights are not '
              'ONNX-converted yet, so it cannot generate images locally.');
      notifyListeners();
      return;
    }
    // Verify there is enough free memory to hold the model weights plus the
    // working tensors before kicking off a (potentially minutes-long) run, so
    // the app fails with a clear message instead of being killed by the OS.
    final memError = await _memoryCheckError(model);
    if (memError != null) {
      _setGen(GenStatus(phase: GenPhase.idle, error: memError));
      return;
    }
    final outDir = await galleryDir();
    final reqId = _genReqId = DateTime.now().millisecondsSinceEpoch;
    _setGen(GenStatus(phase: GenPhase.loading, modelId: model.id));
    final stopwatch = Stopwatch()..start();
    try {
      final outcome = await worker.generate(
        model: model,
        rootDir: p.join(modelsRoot, model.id),
        prompt: _prompt,
        negativePrompt: params.negativePrompt,
        params: params,
        outputDir: outDir.path,
        forceCpu: prefs.forceCpuInference,
        onProgress: (stage, step, total) {
          final phase = _phaseForStage(stage);
          _setGen(GenStatus(
            phase: phase,
            step: step,
            total: total,
            elapsed: stopwatch.elapsed,
            modelId: model.id,
          ));
        },
      );
      if (_genReqId != reqId) return;
      _genReqId = null;
      if (outcome.provider.isNotEmpty) {
        _modelProviders[model.id] = outcome.provider;
      }
      debugPrint('[benchmark] ${outcome.benchmark}');
      await addToGallery(outcome.path, outcome, model);
      unawaited(saveImageToSystemGallery(outcome.path));
      _setGen(const GenStatus());
      return;
    } catch (e) {
      if (_genReqId != reqId) return;
      _genReqId = null;
      _setGen(GenStatus(
        phase: GenPhase.idle,
        error: e.toString(),
        elapsed: stopwatch.elapsed,
        modelId: model.id,
      ));
    }
  }

  void cancelGeneration() {
    final reqId = _genReqId;
    if (reqId != null) _worker?.cancel(reqId);
  }

  static GenPhase _phaseForStage(String stage) {
    switch (stage) {
      case 'loading':
        return GenPhase.loading;
      case 'text_encoder':
        return GenPhase.textEncoder;
      case 'sampling':
        return GenPhase.sampling;
      case 'vae':
        return GenPhase.vae;
      case 'saving':
        return GenPhase.saving;
      default:
        return GenPhase.loading;
    }
  }

  void _setGen(GenStatus status) {
    gen = status;
    notifyListeners();
  }

  void setPrompt(String value) {
    _prompt = value;
    notifyListeners();
  }

  void setNegativePrompt(String value) {
    updateParams(params.copy()..negativePrompt = value);
  }

  /// Loads a model's ONNX engine into the worker's memory so the first
  /// generation needs no model-loading step. Keeps at most one model resident.
  Future<void> prewarmModel(ModelSpec model) async {
    final worker = _worker;
    if (worker == null) return;
    if (!model.runnable || !isModelDownloaded(model)) {
      debugPrint('prewarm skip ${model.id}: runnable=${model.runnable} '
          'downloaded=${isModelDownloaded(model)}');
      return;
    }
    final current = _modelLoadStates[model.id];
    if (current == ModelLoadState.ready || current == ModelLoadState.loading) {
      return;
    }
    final memError = await _memoryCheckError(model);
    if (memError != null) {
      debugPrint('prewarm skip ${model.id}: $memError');
      _modelLoadStates[model.id] = ModelLoadState.failed;
      _modelLoadErrors[model.id] = memError;
      notifyListeners();
      return;
    }
    _modelLoadStates[model.id] = ModelLoadState.loading;
    _modelLoadErrors.remove(model.id);
    notifyListeners();
    debugPrint('prewarm start: ${model.id}');
    try {
      await worker
          .prewarm(
            model: model,
            rootDir: p.join(modelsRoot, model.id),
            forceCpu: prefs.forceCpuInference,
            onProvider: (provider) {
              _modelProviders[model.id] = provider;
            },
          )
          .timeout(const Duration(minutes: 3), onTimeout: () {
        throw Exception(
            'Model load timed out after 3 minutes — the ONNX engine could '
            'not load this model on this device.');
      });
      debugPrint('prewarm ok: ${model.id}');
      _modelLoadStates.clear();
      _modelLoadStates[model.id] = ModelLoadState.ready;
      notifyListeners();
    } catch (e) {
      debugPrint('prewarm failed for ${model.id}: $e');
      _modelLoadStates[model.id] = ModelLoadState.failed;
      _modelLoadErrors[model.id] = e.toString();
      notifyListeners();
    }
  }

  /// Releases a model's engine from memory (e.g. to free RAM after removal).
  Future<void> unloadModel(String id) async {
    _modelLoadStates.remove(id);
    _modelLoadErrors.remove(id);
    notifyListeners();
    await _worker?.unload(id);
  }

  // -------------------------------------------------------------- downloads

  Future<void> downloadModel(ModelSpec model) => downloads.start(model);
  Future<void> pauseDownload(String id) => downloads.pause(id);
  Future<void> resumeDownload(String id) => downloads.resume(id);
  Future<void> cancelDownload(String id) => downloads.cancel(id);

  @override
  Future<void> dispose() async {
    _statsTimer?.cancel();
    _statsTimer = null;
    statsNotifier.dispose();
    await _worker?.dispose();
    downloads.dispose();
    await db.close();
    super.dispose();
  }
}
