import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'models.dart';
import 'model_registry.dart';

/// Live status of one model download.
class ModelDownloadStatus {
  final String jobId;
  final DownloadState state;
  final int received;
  final int total;
  final String currentFile;
  final String error;

  /// True when this status came from a real-time service event (the download
  /// transitioned state while the app was running). False for states read back
  /// from the persisted state files by the poller (e.g. after a restart).
  final bool isLive;

  const ModelDownloadStatus({
    required this.jobId,
    required this.state,
    this.received = 0,
    this.total = 0,
    this.currentFile = '',
    this.error = '',
    this.isLive = false,
  });

  double? get fraction {
    if (total <= 0) return null;
    return (received / total).clamp(0.0, 1.0);
  }

  factory ModelDownloadStatus.fromEvent(Map<dynamic, dynamic> args) {
    return ModelDownloadStatus(
      jobId: args['jobId'] as String? ?? '',
      state: downloadStateFromName(args['state'] as String?),
      received: (args['received'] as num?)?.toInt() ?? 0,
      total: (args['total'] as num?)?.toInt() ?? 0,
      currentFile: args['currentFile'] as String? ?? '',
      error: args['error'] as String? ?? '',
      isLive: true,
    );
  }
}

/// Talks to the Android foreground download service.
///
/// Emits live events on the `aiimagegen/downloads` method channel and also
/// polls the state JSON files the service persists, so status survives app
/// restarts.
class DownloadController {
  static const MethodChannel _channel = MethodChannel('aiimagegen/downloads');

  final ModelRegistry _registry;
  final Map<String, ModelDownloadStatus> _status = {};
  final Map<String, StreamController<ModelDownloadStatus>> _streams = {};
  Timer? _poller;
  bool _listening = false;

  DownloadController(this._registry) {
    // Monitor persisted download states from startup (not only once a download
    // is started), so a model whose download finished in an earlier session is
    // discovered and can be loaded.
    _ensureListening();
  }

  ModelDownloadStatus statusFor(String modelId) => _status[modelId] ??
      ModelDownloadStatus(jobId: modelId, state: DownloadState.none);

  /// Real-time stream for a model's download (replays latest state).
  Stream<ModelDownloadStatus> streamFor(String modelId) {
    return _streams.putIfAbsent(
      modelId,
      () => StreamController<ModelDownloadStatus>.broadcast(),
    ).stream;
  }

  void _emit(String modelId, ModelDownloadStatus status) {
    _status[modelId] = status;
    _streams[modelId]?.add(status);
  }

  void _ensureListening() {
    if (_listening) return;
    _listening = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'downloadEvent') {
        final args = call.arguments as Map<dynamic, dynamic>;
        _emit(
          args['jobId'] as String? ?? '',
          ModelDownloadStatus.fromEvent(args),
        );
      }
    });
    _poller = Timer.periodic(const Duration(milliseconds: 800), (_) {
      _pollPersistedStates();
    });
  }

  Future<void> _pollPersistedStates() async {
    for (final model in _registry.all) {
      final file = await _stateFileFor(model.id);
      if (!file.existsSync()) {
        _emit(
          model.id,
          ModelDownloadStatus(jobId: model.id, state: DownloadState.none),
        );
        continue;
      }
      try {
        final j = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
        _emit(
          model.id,
          ModelDownloadStatus(
            jobId: j['jobId'] as String? ?? model.id,
            state: downloadStateFromName(j['state'] as String?),
            received: (j['received'] as num?)?.toInt() ?? 0,
            total: (j['total'] as num?)?.toInt() ?? 0,
            currentFile: j['currentFile'] as String? ?? '',
            error: j['error'] as String? ?? '',
          ),
        );
      } catch (_) {
        // ignore malformed state files
      }
    }
  }

  Future<File> _stateFileFor(String jobId) async {
    final dir = await getApplicationSupportDirectory();
    return File(p.join(dir.path, 'downloads_$jobId.json'));
  }

  Future<void> start(ModelSpec model) async {
    _ensureListening();
    final dir = await _registry.modelDir(model);
    await dir.create(recursive: true);
    final filesJson = jsonEncode(
      model.files
          .map((f) => {
                'path': f.path,
                'url': f.url,
                'size': f.size,
              })
          .toList(),
    );
    try {
      await _channel.invokeMethod('start', {
        'jobId': model.id,
        'label': model.name,
        'destDir': dir.path,
        'filesJson': filesJson,
      });
    } on PlatformException catch (e) {
      throw Exception(e.message ?? 'Failed to start download');
    }
  }

  Future<void> pause(String jobId) =>
      _channel.invokeMethod('pause', {'jobId': jobId});

  Future<void> resume(String jobId) =>
      _channel.invokeMethod('resume', {'jobId': jobId});

  Future<void> cancel(String jobId) =>
      _channel.invokeMethod('cancel', {'jobId': jobId});

  /// Deletes the persisted state file for [jobId] (e.g. when a model is
  /// removed), so a deleted model doesn't resurrect stale download state.
  Future<void> clearState(String jobId) async {
    final file = await _stateFileFor(jobId);
    try {
      if (file.existsSync()) file.deleteSync();
    } catch (_) {
      // best effort
    }
    _status.remove(jobId);
  }

  /// True when a download for [jobId] is currently active natively.
  Future<bool> isActive(String? jobId) async {
    try {
      final result =
          await _channel.invokeMethod<bool>('isDownloading', {'jobId': jobId});
      return result ?? false;
    } on PlatformException {
      return false;
    }
  }

  void dispose() {
    _poller?.cancel();
    _poller = null;
    _channel.setMethodCallHandler(null);
    for (final controller in _streams.values) {
      controller.close();
    }
    _streams.clear();
  }
}
