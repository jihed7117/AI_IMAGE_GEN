import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';

/// Thin typed wrapper over [SharedPreferences] for app settings.
class AppPrefs {
  final SharedPreferences _p;

  AppPrefs._(this._p);

  static Future<AppPrefs> load() async =>
      AppPrefs._(await SharedPreferences.getInstance());

  static const _kSelectedModel = 'selected_model_id';
  static const _kParams = 'generation_params';
  static const _kCustomModels = 'custom_models';
  static const _kNotificationPermsRequested = 'notification_perms_requested';
  static const _kForceCpuInference = 'force_cpu_inference';

  String get selectedModelId => _p.getString(_kSelectedModel) ?? '';
  Future<void> setSelectedModelId(String id) => _p.setString(_kSelectedModel, id);

  GenerationParams get params {
    final raw = _p.getString(_kParams);
    if (raw == null) return GenerationParams();
    try {
      return GenerationParams.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return GenerationParams();
    }
  }

  Future<void> setParams(GenerationParams params) =>
      _p.setString(_kParams, jsonEncode(params.toJson()));

  List<Map<String, dynamic>> get customModels {
    final raw = _p.getString(_kCustomModels);
    if (raw == null) return const [];
    try {
      return (jsonDecode(raw) as List<dynamic>)
          .map((e) => e as Map<String, dynamic>)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> saveCustomModels(List<Map<String, dynamic>> manifests) =>
      _p.setString(_kCustomModels, jsonEncode(manifests));

  bool get notificationPermsRequested =>
      _p.getBool(_kNotificationPermsRequested) ?? false;
  Future<void> setNotificationPermsRequested() =>
      _p.setBool(_kNotificationPermsRequested, true);

  /// When true, inference is forced onto the CPU provider (no CoreML/NNAPI/
  /// XNNPACK). Useful for benchmarking GPU vs CPU and for troubleshooting.
  bool get forceCpuInference => _p.getBool(_kForceCpuInference) ?? false;
  Future<void> setForceCpuInference(bool value) =>
      _p.setBool(_kForceCpuInference, value);
}
