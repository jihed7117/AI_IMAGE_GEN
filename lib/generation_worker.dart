import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:onnxruntime/onnxruntime.dart';

import 'models.dart';
import 'tokenizer.dart';

/// Outcome of a completed generation.
class GenOutcome {
  final String path;
  final Duration elapsed;
  final int seed;

  /// Label of the provider the UNet ran on (e.g. "NNAPI (GPU/NPU)").
  final String provider;

  /// Per-stage timings and step stats, used for CPU vs GPU benchmarking.
  final Map<String, dynamic> benchmark;
  const GenOutcome(this.path, this.elapsed, this.seed,
      {this.provider = '', this.benchmark = const {}});
}

/// Runs the diffusion pipeline in a dedicated isolate so the UI thread stays
/// responsive during (potentially minutes-long) generations.
class GenerationWorker {
  final ReceivePort _receivePort;
  SendPort? _sendPort;
  final Map<int, _PendingRequest> _pending = {};
  int _nextReqId = 1;
  bool _disposed = false;

  GenerationWorker._(this._receivePort) {
    _receivePort.listen(_onMessage);
  }

  static Future<GenerationWorker> start() async {
    final receivePort = ReceivePort();
    await Isolate.spawn(_workerMain, receivePort.sendPort,
        debugName: 'diffusion-engine');
    return GenerationWorker._(receivePort);
  }

  Future<GenOutcome> generate({
    required ModelSpec model,
    required String rootDir,
    required String prompt,
    required String negativePrompt,
    required GenerationParams params,
    required String outputDir,
    bool forceCpu = false,
    void Function(String stage, int step, int total)? onProgress,
  }) async {
    final reqId = _nextReqId++;
    final completer = Completer<GenOutcome>();
    _pending[reqId] = _PendingRequest.gen(completer, onProgress);
    _sendPort!.send({
      'cmd': 'generate',
      'reqId': reqId,
      'engine': model.engineConfig,
      'rootDir': rootDir,
      'prompt': prompt,
      'negativePrompt': negativePrompt,
      'params': params.toJson(),
      'outputDir': outputDir,
      'forceCpu': forceCpu,
    });
    return completer.future;
  }

  /// Loads the model into memory in the worker isolate ahead of time so a
  /// later [generate] can start immediately. Only one model stays resident:
  /// prewarming a model unloads any previously loaded one.
  Future<void> prewarm({
    required ModelSpec model,
    required String rootDir,
    bool forceCpu = false,
    void Function(String provider)? onProvider,
  }) async {
    final reqId = _nextReqId++;
    final completer = Completer<void>();
    _pending[reqId] = _PendingRequest.warm(completer, onProvider);
    _sendPort!.send({
      'cmd': 'prewarm',
      'reqId': reqId,
      'engine': model.engineConfig,
      'rootDir': rootDir,
      'forceCpu': forceCpu,
    });
    return completer.future;
  }

  /// Releases the model from memory in the worker isolate.
  Future<void> unload(String modelId) async {
    final reqId = _nextReqId++;
    final completer = Completer<void>();
    _pending[reqId] = _PendingRequest.warm(completer, null);
    _sendPort!.send({'cmd': 'unload', 'reqId': reqId, 'modelId': modelId});
    return completer.future;
  }

  void cancel(int reqId) {
    _sendPort?.send({'cmd': 'cancel', 'reqId': reqId});
  }

  void _onMessage(dynamic raw) {
    if (raw is SendPort) {
      _sendPort = raw;
      return;
    }
    final msg = raw as Map<String, dynamic>;
    final reqId = msg['reqId'] as int;
    final type = msg['type'] as String? ?? '';
    // Only a terminal message (result/prewarmed/unloaded/error) may remove the
    // pending entry. Progress messages ('stage'/'progress') must keep it, or
    // the eventual response would find no pending request and be dropped,
    // leaving the future uncompleted forever ("Loading model…" hang).
    final isTerminal = type == 'result' ||
        type == 'prewarmed' ||
        type == 'unloaded' ||
        type == 'error';
    final pending = isTerminal ? _pending.remove(reqId) : _pending[reqId];
    if (pending == null) return;
    switch (type) {
      case 'stage':
        pending.onProgress?.call(msg['stage'] as String, 0, 0);
      case 'progress':
        pending.onProgress?.call('sampling', (msg['step'] as num?)?.toInt() ?? 0,
            (msg['total'] as num?)?.toInt() ?? 0);
      case 'result':
        pending.gen?.complete(GenOutcome(
          msg['path'] as String,
          Duration(milliseconds: (msg['elapsedMs'] as num?)?.toInt() ?? 0),
          (msg['seed'] as num?)?.toInt() ?? 0,
          provider: msg['provider'] as String? ?? '',
          benchmark:
              (msg['benchmark'] as Map?)?.cast<String, dynamic>() ?? const {},
        ));
      case 'prewarmed':
        final provider = msg['provider'] as String? ?? '';
        if (provider.isNotEmpty) pending.onProvider?.call(provider);
        pending.warm?.complete();
      case 'unloaded':
        pending.warm?.complete();
      case 'error':
        final error = Exception(msg['message'] as String? ?? 'Generation failed');
        final g = pending.gen;
        if (g != null) {
          g.completeError(error);
        } else {
          pending.warm?.completeError(error);
        }
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _sendPort?.send({'cmd': 'close'});
    _receivePort.close();
  }
}

class _PendingRequest {
  final Completer<GenOutcome>? gen;
  final Completer<void>? warm;
  final void Function(String stage, int step, int total)? onProgress;
  final void Function(String provider)? onProvider;
  _PendingRequest.gen(this.gen, this.onProgress)
      : warm = null,
        onProvider = null;
  _PendingRequest.warm(this.warm, this.onProvider)
      : gen = null,
        onProgress = null;
}

// --------------------------------------------------------------------------
// Isolate side
// --------------------------------------------------------------------------

void _workerMain(SendPort sendPort) {
  final receivePort = ReceivePort();
  sendPort.send(receivePort.sendPort);
  final engineCache = <String, _Engine>{};
  final active = <int, _Generation>{};

  receivePort.listen((raw) {
    final msg = raw as Map<String, dynamic>;
    switch (msg['cmd']) {
      case 'generate':
        final reqId = msg['reqId'] as int;
        try {
          final config = (msg['engine'] as Map).cast<String, dynamic>();
          final rootDir = msg['rootDir'] as String;
          final forceCpu = msg['forceCpu'] == true;
          final engine = engineCache[config['id']];
          if (engine == null) {
            sendPort.send({'reqId': reqId, 'type': 'stage', 'stage': 'loading'});
            engineCache[config['id']] =
                _Engine.load(config, rootDir, forceCpu: forceCpu);
          }
          final generation = _Generation(engineCache[config['id']]!, msg, sendPort);
          active[reqId] = generation;
          generation.run().then((result) {
            active.remove(reqId);
            if (result != null) {
              sendPort.send({
                'reqId': reqId,
                'type': 'result',
                'path': result.path,
                'elapsedMs': result.elapsedMs,
                'seed': result.seed,
                'provider': result.provider,
                'benchmark': result.benchmark,
              });
            }
          }, onError: (Object e) {
            active.remove(reqId);
            sendPort.send({
              'reqId': reqId,
              'type': 'error',
              'message': e.toString(),
            });
          });
        } catch (e) {
          sendPort.send({
            'reqId': reqId,
            'type': 'error',
            'message': e.toString(),
          });
        }
      case 'prewarm':
        final reqId = msg['reqId'] as int;
        try {
          final config = (msg['engine'] as Map).cast<String, dynamic>();
          final rootDir = msg['rootDir'] as String;
          final id = config['id'] as String;
          final forceCpu = msg['forceCpu'] == true;
    if (engineCache[id] == null) {
      sendPort.send({'reqId': reqId, 'type': 'stage', 'stage': 'loading'});
      engineCache[id] = _Engine.load(config, rootDir, forceCpu: forceCpu);
    }
    for (final entry in engineCache.entries.toList()) {
      if (entry.key != id) {
        entry.value.dispose();
        engineCache.remove(entry.key);
      }
    }
    sendPort.send({
      'reqId': reqId,
      'type': 'prewarmed',
      'modelId': id,
      'provider': engineCache[id]?.primaryProviderLabel ?? '',
    });
        } catch (e) {
          sendPort.send({
            'reqId': reqId,
            'type': 'error',
            'message': e.toString(),
          });
        }
      case 'unload':
        final reqId = msg['reqId'] as int;
        final id = msg['modelId'] as String;
        final engine = engineCache.remove(id);
        engine?.dispose();
        sendPort.send({'reqId': reqId, 'type': 'unloaded', 'modelId': id});
      case 'cancel':
        active[msg['reqId']]?.cancelled = true;
      case 'close':
        for (final engine in engineCache.values) {
          engine.dispose();
        }
        engineCache.clear();
        receivePort.close();
    }
  });
}

class _GenerationResult {
  final String path;
  final int elapsedMs;
  final int seed;
  final String provider;
  final Map<String, dynamic> benchmark;
  const _GenerationResult(this.path, this.elapsedMs, this.seed,
      {required this.provider, required this.benchmark});
}

class _Generation {
  final _Engine engine;
  final Map<String, dynamic> msg;
  final SendPort sendPort;
  bool cancelled = false;
  final String prompt;
  final String negativePrompt;
  final GenerationParams params;
  final String outputDir;

  _Generation(this.engine, this.msg, this.sendPort)
      : prompt = msg['prompt'] as String,
        negativePrompt = msg['negativePrompt'] as String,
        params = GenerationParams.fromJson(
            (msg['params'] as Map).cast<String, dynamic>()),
        outputDir = msg['outputDir'] as String;

  void _stage(String s) =>
      sendPort.send({'reqId': msg['reqId'], 'type': 'stage', 'stage': s});

  Future<_GenerationResult?> run() async {
    final stopwatch = Stopwatch()..start();
    final seed = params.seed >= 0
        ? params.seed
        : DateTime.now().millisecondsSinceEpoch & 0x7fffffff;
    final benchmark = <String, dynamic>{};

    _stage('text_encoder');
    final tText = stopwatch.elapsedMilliseconds;
    final context = await engine.encodeText(prompt, negativePrompt);
    benchmark['textEncoderMs'] = stopwatch.elapsedMilliseconds - tText;

    _stage('sampling');
    final tSample = stopwatch.elapsedMilliseconds;
    int? lastStepAt;
    final stepDurations = <int>[];
    final latents = engine.sample(
      context: context,
      steps: params.steps,
      cfgScale: params.cfgScale,
      seed: seed,
      isCancelled: () => cancelled,
      onProgress: (step, total) {
        if (cancelled) throw GenerationCancelled();
        final now = stopwatch.elapsedMilliseconds;
        if (lastStepAt != null) stepDurations.add(now - lastStepAt!);
        lastStepAt = now;
        sendPort.send({
          'reqId': msg['reqId'],
          'type': 'progress',
          'step': step,
          'total': total,
        });
      },
    );
    benchmark['samplingMs'] = stopwatch.elapsedMilliseconds - tSample;
    benchmark['steps'] = params.steps;
    benchmark['msPerStep'] = stepDurations.isEmpty
        ? 0
        : stepDurations.reduce((a, b) => a + b) ~/ stepDurations.length;

    _stage('vae');
    final tVae = stopwatch.elapsedMilliseconds;
    final rgb = engine.decodeImage(latents);
    benchmark['vaeMs'] = stopwatch.elapsedMilliseconds - tVae;

    _stage('saving');
    final tSave = stopwatch.elapsedMilliseconds;
    final png = img.encodePng(img.Image.fromBytes(
      width: engine.width,
      height: engine.height,
      bytes: rgb.buffer,
      numChannels: 3,
      order: img.ChannelOrder.rgb,
    ));
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final file = File('$outputDir/img_${stamp}_$seed.png');
    file.writeAsBytesSync(png);
    benchmark['savingMs'] = stopwatch.elapsedMilliseconds - tSave;
    stopwatch.stop();
    benchmark['totalMs'] = stopwatch.elapsedMilliseconds;
    final provider = engine.primaryProviderLabel;
    debugPrint('[benchmark] provider=$provider '
        'text=${benchmark['textEncoderMs']}ms '
        'sampling=${benchmark['samplingMs']}ms '
        '(${params.steps} steps, ~${benchmark['msPerStep']}ms/step) '
        'vae=${benchmark['vaeMs']}ms '
        'save=${benchmark['savingMs']}ms '
        'total=${benchmark['totalMs']}ms');
    return _GenerationResult(
      file.path,
      stopwatch.elapsedMilliseconds,
      seed,
      provider: provider,
      benchmark: benchmark,
    );
  }
}

class GenerationCancelled implements Exception {}

// --------------------------------------------------------------------------
// Engine
// --------------------------------------------------------------------------

class _Engine {
  final Map<String, dynamic> config;
  final String family;
  final int resolution;
  final int latentChannels;
  final double vaeScale;
  final int maxLength;
  final int textDim;

  /// True when the ONNX weights are half precision (fp16). The UNet/VAE of
  /// fp16 models declare float16 inputs, so latents and hidden states must be
  /// converted to fp16 before being fed to the sessions.
  final bool fp16;

  OrtSession? textEncoder;
  OrtSession? textEncoder2;
  late OrtSession unet;
  late OrtSession vae;
  late OrtRunOptions runOptions;
  ClipTokenizer? tokenizer;
  ClipTokenizer? tokenizer2;

  /// Provider each session actually loaded on (e.g. "NNAPI (GPU/NPU)").
  String? textEncoderProvider;
  String? textEncoder2Provider;
  String? unetProvider;
  String? vaeProvider;

  /// Label of the provider the UNet (the biggest, slowest session) loaded on;
  /// used for logs, the settings screen, and benchmark reports.
  String get primaryProviderLabel => unetProvider ?? 'CPU';

  late List<double> alphasCumprod;

  int get width => resolution;
  int get height => resolution;
  int get latentSize => resolution ~/ 8;

  _Engine._(this.config)
      : family = config['family'] as String,
        resolution = (config['resolution'] as num?)?.toInt() ?? 512,
        latentChannels = (config['latentChannels'] as num?)?.toInt() ?? 4,
        vaeScale = (config['vaeScale'] as num?)?.toDouble() ?? 0.18215,
        maxLength = (config['maxLength'] as num?)?.toInt() ?? 77,
        textDim = (config['textDim'] as num?)?.toInt() ?? 768,
        fp16 = config['dtype'] == 'fp16';

  static _Engine load(Map<String, dynamic> config, String rootDir,
      {bool forceCpu = false}) {
    final engine = _Engine._(config);
    final isSdxl = engine.family == 'sdxl';

    // Session options tried in order, best first: the hardware accelerator
    // (NNAPI on Android, CoreML on iOS, XNNPACK otherwise) with the CPU
    // appended last so ops the accelerator cannot run fall back to the CPU
    // automatically, then CPU-only options. ORT_ENABLE_ALL is only used as a
    // last resort because it can hang while optimizing fp16 / external-data
    // models on CPU (SD 1.5's UNet is external-data: unet/model.onnx +
    // weights.pb); basic optimization is what most on-device apps ship with.
    // [forceCpu] skips the accelerator entirely (used for CPU vs GPU
    // benchmarking and troubleshooting).
    final candidates = _sessionOptionCandidates(forceCpu: forceCpu);
    engine.runOptions = OrtRunOptions();
    try {
      if (File('$rootDir/text_encoder/model.onnx').existsSync()) {
        final loaded = _loadSession(
            File('$rootDir/text_encoder/model.onnx'), candidates,
            description: 'text encoder');
        engine.textEncoder = loaded.session;
        engine.textEncoderProvider = loaded.label;
      }
      if (isSdxl && File('$rootDir/text_encoder_2/model.onnx').existsSync()) {
        final loaded = _loadSession(
            File('$rootDir/text_encoder_2/model.onnx'), candidates,
            description: 'text encoder 2');
        engine.textEncoder2 = loaded.session;
        engine.textEncoder2Provider = loaded.label;
      }
      final unet = _loadSession(File('$rootDir/unet/model.onnx'), candidates,
          description: 'UNet', required: true);
      engine.unet = unet.session;
      engine.unetProvider = unet.label;
      final vae = _loadSession(File('$rootDir/vae_decoder/model.onnx'),
          candidates,
          description: 'VAE decoder', required: true);
      engine.vae = vae.session;
      engine.vaeProvider = vae.label;
    } finally {
      for (final c in candidates) {
        c.options.release();
      }
    }

    if (File('$rootDir/tokenizer/vocab.json').existsSync()) {
      engine.tokenizer = ClipTokenizer.loadFromDir('$rootDir/tokenizer');
    }
    if (isSdxl && File('$rootDir/tokenizer_2/vocab.json').existsSync()) {
      engine.tokenizer2 = ClipTokenizer.loadFromDir('$rootDir/tokenizer_2');
    }
    final scheduler = config['scheduler'];
    engine._buildSchedules(
        scheduler is Map ? scheduler.map((k, v) => MapEntry('$k', v)) : const {});
    return engine;
  }

  /// Session-option candidates tried in order when loading a model.
  static List<({OrtSessionOptions options, String label})>
      _sessionOptionCandidates({bool forceCpu = false}) {
    final accelerated = forceCpu ? null : _acceleratedOptions();
    return [
      if (accelerated != null) accelerated,
      (options: _cpuOptions(GraphOptimizationLevel.ortEnableBasic),
          label: 'CPU'),
      (options: _cpuOptions(GraphOptimizationLevel.ortEnableAll),
          label: 'CPU (full optimization)'),
    ];
  }

  /// Whether this binary was built with [provider] registered, per ORT's own
  /// GetAvailableProviders query. This is the "does my device/build support
  /// hardware acceleration" check; actually being able to run the model is
  /// still verified per-session by [load]'s fallback chain.
  static bool _hasProvider(OrtProvider provider) {
    try {
      return OrtEnv.instance.availableProviders().contains(provider);
    } catch (e) {
      debugPrint('availableProviders query failed: $e');
      return false;
    }
  }

  /// Builds session options that route inference to the device's accelerator:
  /// CoreML (GPU/ANE) on iOS, NNAPI (GPU/NPU/DSP) on Android, and the
  /// XNNPACK-optimized CPU backend as a no-accelerator fallback. The CPU
  /// provider is appended last so unsupported ops degrade per-node instead of
  /// failing the whole session. Returns null when no accelerator is usable.
  static ({OrtSessionOptions options, String label})? _acceleratedOptions() {
    try {
      if (Platform.isIOS && _hasProvider(OrtProvider.coreml)) {
        final options = _baseOptions();
        // enableOnSubgraph lets CoreML run the parts of the graph it supports
        // (most of a diffusion UNet) and leaves the rest to the CPU.
        options.appendCoreMLProvider(CoreMLFlags.enableOnSubgraph);
        options.appendCPUProvider(CPUFlags.useArena);
        return (options: options, label: 'CoreML (GPU/ANE)');
      }
      if (Platform.isAndroid && _hasProvider(OrtProvider.nnapi)) {
        final options = _baseOptions();
        // NNAPI routes to the fastest available accelerator (GPU/NPU/DSP) and
        // falls back per-node to its own CPU implementation when needed.
        options.appendNnapiProvider(NnapiFlags.useFp16);
        options.appendCPUProvider(CPUFlags.useArena);
        return (options: options, label: 'NNAPI (GPU/NPU)');
      }
      if (_hasProvider(OrtProvider.xnnpack)) {
        final options = _baseOptions();
        options.appendXnnpackProvider();
        options.appendCPUProvider(CPUFlags.useArena);
        return (options: options, label: 'XNNPACK');
      }
    } catch (e) {
      debugPrint('accelerator session options failed, using CPU: $e');
    }
    return null;
  }

  static OrtSessionOptions _baseOptions() {
    return OrtSessionOptions()
      ..setIntraOpNumThreads(math.max(1, Platform.numberOfProcessors ~/ 2))
      ..setSessionGraphOptimizationLevel(GraphOptimizationLevel.ortEnableBasic);
  }

  static OrtSessionOptions _cpuOptions(GraphOptimizationLevel level) {
    final options = OrtSessionOptions()
      ..setIntraOpNumThreads(math.max(1, Platform.numberOfProcessors ~/ 2))
      ..setSessionGraphOptimizationLevel(level);
    options.appendCPUProvider(CPUFlags.useArena);
    return options;
  }

  /// Loads one ONNX session, failing with a clear message instead of a raw
  /// ORT error.
  ///
  /// Tries each [candidates] option set in order (accelerator first, CPU
  /// last). If the accelerator cannot actually run the model — e.g. the
  /// device lacks GPU/NPU support and session creation fails — the load
  /// silently falls back to the next candidate instead of failing the app.
  static ({OrtSession session, String label}) _loadSession(
    File file,
    List<({OrtSessionOptions options, String label})> candidates, {
    String description = 'model',
    bool required = false,
  }) {
    if (!file.existsSync()) {
      throw Exception(required
          ? 'Missing $description file: ${file.path}. The download may be '
              'incomplete — delete the model files and download again.'
          : 'Missing $description file: ${file.path}.');
    }
    Object? lastError;
    for (final candidate in candidates) {
      debugPrint('loading $description (${candidate.label}): ${file.path}');
      final sw = Stopwatch()..start();
      try {
        final session = OrtSession.fromFile(file, candidate.options);
        debugPrint('loaded $description on ${candidate.label} in '
            '${sw.elapsedMilliseconds}ms');
        return (session: session, label: candidate.label);
      } catch (e) {
        lastError = e;
        debugPrint('load $description (${candidate.label}) failed after '
            '${sw.elapsedMilliseconds}ms: $e');
      }
    }
    throw Exception('Failed to load $description (${file.path}) on any '
        'provider: $lastError');
  }

  void _buildSchedules(Map<String, dynamic> scheduler) {
    final betaStart = (scheduler['beta_start'] as num?)?.toDouble() ?? 0.00085;
    final betaEnd = (scheduler['beta_end'] as num?)?.toDouble() ?? 0.012;
    final trainSteps =
        (scheduler['num_train_timesteps'] as num?)?.toInt() ?? 1000;

    final betas = List<double>.generate(
        trainSteps,
        (i) => betaStart + (betaEnd - betaStart) * i / (trainSteps - 1));
    final alphas = betas.map((b) => 1.0 - b).toList();
    final cumprod = <double>[];
    var acc = 1.0;
    for (final a in alphas) {
      acc *= a;
      cumprod.add(acc);
    }
    alphasCumprod = cumprod;
  }

  void dispose() {
    textEncoder?.release();
    textEncoder2?.release();
    unet.release();
    vae.release();
    runOptions.release();
  }

  // ------------------------------------------------------------- text encoding

  Future<_Context> encodeText(String prompt, String negativePrompt) async {
    final isSdxl = family == 'sdxl';
    final tok = tokenizer;
    if (tok == null) throw Exception('Tokenizer not found for this model');

    final posIds = tok.encode(prompt, maxLength: maxLength);
    final negIds =
        tok.encode(negativePrompt.isEmpty ? '' : negativePrompt, maxLength: maxLength);

    var posHidden = <double>[];
    var negHidden = <double>[];
    List<double>? posPooled;
    List<double>? negPooled;

    final te = textEncoder;
    if (te != null) {
      posHidden = _runTextEncoder(te, posIds).hidden;
      negHidden = _runTextEncoder(te, negIds).hidden;
    }

    if (isSdxl) {
      final tok2 = tokenizer2;
      final te2 = textEncoder2;
      if (tok2 == null || te2 == null) {
        throw Exception('SDXL requires tokenizer_2 and text_encoder_2');
      }
      final posIds2 = tok2.encode(prompt, maxLength: maxLength);
      final negIds2 = tok2.encode(
          negativePrompt.isEmpty ? '' : negativePrompt,
          maxLength: maxLength);
      final p2 = _runTextEncoder(te2, posIds2);
      final n2 = _runTextEncoder(te2, negIds2);
      posHidden = [...posHidden, ...p2.hidden];
      negHidden = [...negHidden, ...n2.hidden];
      posPooled = p2.pooled;
      negPooled = n2.pooled;
    }

    return _Context(
      posHidden: posHidden,
      negHidden: negHidden,
      posPooled: posPooled,
      negPooled: negPooled,
    );
  }

  ({List<double> hidden, List<double>? pooled}) _runTextEncoder(
      OrtSession session, List<int> ids) {
    // CLIP input_ids is declared int32 in the SD 1.5 / SDXL ONNX exports;
    // feeding int64 makes ORT reject the input ("Unexpected input data type").
    final idsData = Int32List.fromList(ids);
    final inputName = session.inputNames.first;
    final hiddenName = _firstOutput(session, const ['last_hidden_state'])!;
    final pooledName = _firstOutput(session, const ['text_embeds', 'pooler_output']);

    final outputs = <String>[hiddenName, if (pooledName != null) pooledName];
    final inputs = <String, OrtValue>{
      inputName:
          OrtValueTensor.createTensorWithDataList(idsData, [1, maxLength]),
    };
    final out = session.run(runOptions, inputs, outputs);
    try {
      final hidden = _flattenDoubles(out[0]!.value);
      List<double>? pooled;
      if (pooledName != null && out.length > 1) {
        pooled = _flattenDoubles(out[1]!.value);
      }
      return (hidden: hidden, pooled: pooled);
    } finally {
      for (final o in out) {
        o?.release();
      }
    }
  }

  String? _firstOutput(OrtSession session, List<String> preferences) {
    for (final pref in preferences) {
      for (final name in session.outputNames) {
        if (name == pref) return name;
      }
    }
    return session.outputNames.first;
  }

  // ---------------------------------------------------------------- sampling

  Float32List sample({
    required _Context context,
    required int steps,
    required double cfgScale,
    required int seed,
    bool Function()? isCancelled,
    required void Function(int step, int total) onProgress,
  }) {
    final n = latentChannels * latentSize * latentSize;
    final rng = math.Random(seed);
    final latents = Float32List(n);
    for (var i = 0; i < n; i++) {
      latents[i] = _gaussian(rng);
    }

    final timesteps = <int>[];
    for (var i = 0; i < steps; i++) {
      timesteps.add((999 * i / (steps - 1)).round());
    }

    final isSdxl = family == 'sdxl';
    final te2Name =
        isSdxl && unet.inputNames.contains('text_embeds') ? 'text_embeds' : null;
    final timeIdsName =
        isSdxl && unet.inputNames.contains('time_ids') ? 'time_ids' : null;

    var stepIndex = steps - 1;
    while (stepIndex >= 0) {
      onProgress(steps - stepIndex, steps);
      final t = timesteps[stepIndex];
      final tPrev = stepIndex > 0 ? timesteps[stepIndex - 1] : 0;

      final uncond = _runUnet(
          latents, t, context.negHidden, context.negPooled,
          te2Name: te2Name, timeIdsName: timeIdsName);
      if (isCancelled?.call() ?? false) {
        throw GenerationCancelled();
      }
      final cond = _runUnet(
          latents, t, context.posHidden, context.posPooled,
          te2Name: te2Name, timeIdsName: timeIdsName);
      if (isCancelled?.call() ?? false) {
        throw GenerationCancelled();
      }

      for (var i = 0; i < n; i++) {
        uncond[i] += cfgScale * (cond[i] - uncond[i]);
      }

      _samplerStep(latents, uncond, t, tPrev);
      stepIndex--;
    }
    return latents;
  }

  Float32List _runUnet(
    Float32List sample,
    int timestep,
    List<double> hidden,
    List<double>? pooled, {
    String? te2Name,
    String? timeIdsName,
  }) {
    Map<String, OrtValue> builtInputs = {};
    try {
      builtInputs = _buildUnetInputs(
          sample, timestep, hidden, pooled,
          te2Name: te2Name, timeIdsName: timeIdsName);
      List<OrtValue?> out;
      try {
        out = unet.run(runOptions, builtInputs, null);
      } catch (_) {
        // Some exports expect a scalar timestep; retry once.
        for (final v in builtInputs.values) {
          v.release();
        }
        builtInputs = _buildUnetInputs(sample, timestep, hidden, pooled,
            te2Name: te2Name, timeIdsName: timeIdsName, scalarTimestep: true);
        out = unet.run(runOptions, builtInputs, null);
      }
      try {
        final value = _flattenDoubles(out[0]!.value);
        for (final v in out) {
          v?.release();
        }
        return value;
      } catch (_) {
        for (final v in out) {
          v?.release();
        }
        rethrow;
      }
    } finally {
      for (final v in builtInputs.values) {
        v.release();
      }
    }
  }

  Map<String, OrtValue> _buildUnetInputs(
    Float32List sample,
    int timestep,
    List<double> hidden,
    List<double>? pooled, {
    String? te2Name,
    String? timeIdsName,
    bool scalarTimestep = false,
  }) {
    // Canonical SD ONNX input ordering; names are mapped positionally below
    // so models with differently-named inputs still work.
    final values = <OrtValue>[
      fp16
          ? OrtValueTensor.createTensorWithFloat16List(
              sample, [1, latentChannels, latentSize, latentSize])
          : OrtValueTensor.createTensorWithDataList(
              sample, [1, latentChannels, latentSize, latentSize]),
      // timestep is declared int32 in fp32 exports but float16 in fp16 ones.
      fp16
          ? OrtValueTensor.createTensorWithFloat16List(
              [timestep.toDouble()], scalarTimestep ? <int>[] : [1])
          : OrtValueTensor.createTensorWithDataList(
              Int32List.fromList([timestep]),
              scalarTimestep ? <int>[] : [1]),
      fp16
          ? OrtValueTensor.createTensorWithFloat16List(
              hidden, [1, maxLength, textDim])
          : OrtValueTensor.createTensorWithDataList(
              Float32List.fromList(hidden), [1, maxLength, textDim]),
    ];
    if (te2Name != null) {
      values.add(OrtValueTensor.createTensorWithDataList(
          Float32List.fromList(pooled ?? const []), [1, 1280]));
    }
    if (timeIdsName != null) {
      final timeIds = Int64List.fromList([0, 0, resolution, resolution, 0, 0]);
      try {
        values.add(OrtValueTensor.createTensorWithDataList(timeIds, [6]));
      } catch (_) {
        values.add(OrtValueTensor.createTensorWithDataList(timeIds, [1, 6]));
      }
    }
    final names = unet.inputNames;
    final map = <String, OrtValue>{};
    for (var i = 0; i < values.length; i++) {
      map[names[i]] = values[i];
    }
    return map;
  }

  void _samplerStep(Float32List latents, Float32List eps, int t, int tPrev) {
    final at = alphasCumprod[t];
    final ap = alphasCumprod[tPrev];
    final sAt = math.sqrt(at);
    final sAp = math.sqrt(ap);
    final s1mt = math.sqrt(1 - at);
    final s1mp = math.sqrt(1 - ap);
    for (var i = 0; i < latents.length; i++) {
      latents[i] = sAp * ((latents[i] - s1mt * eps[i]) / sAt) + s1mp * eps[i];
    }
  }

  // ------------------------------------------------------------------- vae

  Uint8List decodeImage(Float32List latents) {
    final scale = vaeScale;
    final scaled = Float32List(latents.length);
    for (var i = 0; i < latents.length; i++) {
      scaled[i] = latents[i] / scale;
    }
    final inputName = vae.inputNames.first;
    final inputs = <String, OrtValue>{
      inputName: fp16
          ? OrtValueTensor.createTensorWithFloat16List(
              scaled, [1, latentChannels, latentSize, latentSize])
          : OrtValueTensor.createTensorWithDataList(
              scaled, [1, latentChannels, latentSize, latentSize]),
    };
    final out = vae.run(runOptions, inputs, null);
    try {
      final value = out[0]!.value as List;
      final channels = value[0] as List;
      final heightPlane = channels[0] as List;
      final h = heightPlane.length;
      final widthPlane = heightPlane[0] as List;
      final w = widthPlane.length;
      final rgb = Uint8List(h * w * 3);
      var idx = 0;
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          final r = _toByte(((channels[0] as List)[y][x] as num).toDouble());
          final g = _toByte(((channels[1] as List)[y][x] as num).toDouble());
          final b = _toByte(((channels[2] as List)[y][x] as num).toDouble());
          rgb[idx++] = r;
          rgb[idx++] = g;
          rgb[idx++] = b;
        }
      }
      return rgb;
    } finally {
      for (final o in out) {
        o?.release();
      }
    }
  }

  static int _toByte(double v) {
    final x = ((v + 1.0) / 2.0 * 255.0).clamp(0.0, 255.0);
    return x.round();
  }

  // ---------------------------------------------------------------- helpers

  static double _gaussian(math.Random rng) {
    final u1 = rng.nextDouble();
    final u2 = rng.nextDouble();
    return math.sqrt(-2 * math.log(1 - u1)) * math.cos(2 * math.pi * u2);
  }

  static Float32List _flattenDoubles(dynamic value) {
    final out = Float32List(_count(value));
    var idx = 0;
    void walk(dynamic node) {
      if (node is List) {
        for (final e in node) {
          walk(e);
        }
      } else {
        out[idx++] = (node as num).toDouble();
      }
    }

    walk(value);
    return out;
  }

  static int _count(dynamic node) {
    if (node is List) {
      return node.fold<int>(0, (sum, e) => sum + _count(e));
    }
    return 1;
  }
}

class _Context {
  final List<double> posHidden;
  final List<double> negHidden;
  final List<double>? posPooled;
  final List<double>? negPooled;
  const _Context({
    required this.posHidden,
    required this.negHidden,
    this.posPooled,
    this.negPooled,
  });
}
