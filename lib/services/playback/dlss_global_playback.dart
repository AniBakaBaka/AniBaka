import 'dart:convert';
import 'dart:io';

import 'package:baka/instance.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'dlss_frame_generation_runtime.dart';
import 'dlss_runtime_installer.dart';
import 'video_enhancement_bridge.dart';

class DlssPlaybackEffects {
  DlssPlaybackEffects({
    this.intensity = .7,
    this.sharpness = .35,
    this.maxHeight = 1080,
    this.superResolution = true,
    this.frameGeneration = true,
    this.neuralRendering = false,
    this.comparison = false,
  });

  double intensity, sharpness;
  int maxHeight;
  bool superResolution, frameGeneration, neuralRendering, comparison;

  factory DlssPlaybackEffects.fromJson(Map<String, dynamic> json) =>
      DlssPlaybackEffects(
        intensity: (json['intensity'] as num?)?.toDouble() ?? .7,
        sharpness: (json['sharpness'] as num?)?.toDouble() ?? .35,
        maxHeight: json['maxHeight'] as int? ?? 1080,
        superResolution: json['superResolution'] as bool? ?? true,
        frameGeneration: json['frameGeneration'] as bool? ?? true,
        neuralRendering: json['neuralRendering'] as bool? ?? false,
        comparison: json['comparison'] as bool? ?? false,
      );

  Map<String, Object> toJson() => {
    'intensity': intensity,
    'sharpness': sharpness,
    'maxHeight': maxHeight,
    'superResolution': superResolution,
    'frameGeneration': frameGeneration,
    'neuralRendering': neuralRendering,
    'comparison': comparison,
  };
}

class DlssGlobalPlayback extends ChangeNotifier {
  static final instance = DlssGlobalPlayback();
  static const _key = 'dlss5_global_playback_enabled';
  static const _effectsKey = 'dlss5_global_playback_effects';
  final _bridge = VideoEnhancementBridge.instance;
  bool enabled = false, busy = false;
  String status = '已关闭';
  String? error;
  CancelToken? _cancel;
  DlssRuntimeInstaller? _installer;
  String? _runtime, _cache, _fgRuntime;
  DlssPlaybackEffects effects = DlssPlaybackEffects();

  Future<void> initialize() async {
    if (!Platform.isWindows) return;
    _bridge.dlssStatus.addListener(_statusChanged);
    final saved = Instances.sp.getString(_effectsKey);
    if (saved != null) {
      effects = DlssPlaybackEffects.fromJson(jsonDecode(saved));
    }
    final active =
        (Instances.sp.getBool(_key) ?? false) &&
        (Instances.sp.getBool('dlss5_playback_enabled') ?? true);
    await Instances.sp.setBool(_key, active);
    await Instances.sp.remove('dlss5_playback_enabled');
    if (active) await setEnabled(true, allowInstall: false);
  }

  void _statusChanged() {
    final next = _bridge.dlssStatus.value;
    if (status == next) return;
    status = next;
    notifyListeners();
  }

  Future<void> setEnabled(bool value, {bool allowInstall = true}) async {
    if (busy || !Platform.isWindows) return;
    busy = true;
    error = null;
    notifyListeners();
    try {
      if (value) await _prepare(allowInstall);
      await _configure(value);
      enabled = value;
      await Instances.sp.setBool(_key, value);
      status = value ? '等待视频画面' : '已关闭';
    } catch (e) {
      error = _cancel?.isCancelled == true ? null : '$e';
    } finally {
      _cancel = null;
      busy = false;
      notifyListeners();
    }
  }

  Future<void> saveEffects() async {
    if (busy) return;
    busy = true;
    error = null;
    notifyListeners();
    try {
      if (enabled) {
        await _prepare(true);
        await _configure(true);
      }
      await Instances.sp.setString(_effectsKey, jsonEncode(effects.toJson()));
    } catch (e) {
      error = '$e';
    } finally {
      _cancel = null;
      busy = false;
      notifyListeners();
    }
  }

  Future<void> _configure(bool active) =>
      VideoEnhancementBridge.channel.invokeMethod<void>(
        'Dlss.Configure',
        active
            ? {
                'enabled': true,
                'runtime': _runtime!,
                'cache': _cache!,
                'fgRuntime': _fgRuntime ?? '',
                ...effects.toJson(),
              }
            : {'enabled': false},
      );

  Future<void> _prepare(bool allowInstall) async {
    final cancel = _cancel = CancelToken();
    if (_runtime == null) {
      var tools = DlssRuntime.load(Instances.sp);
      if (!await tools.isAvailable()) {
        if (!allowInstall) throw StateError('DLSS 运行库未安装');
        final installer = _installer = DlssRuntimeInstaller();
        void progress() {
          status = installer.status;
          notifyListeners();
        }

        installer.addListener(progress);
        try {
          final result = await installer.install(
            await Instances.desktopDataDirectory('tools/dlss5'),
          );
          if (cancel.isCancelled) throw cancel.cancelError!;
          if (result == null) throw StateError(installer.error ?? '安装已取消');
          tools = result;
          await tools.save(Instances.sp);
        } finally {
          installer.removeListener(progress);
          installer.dispose();
          _installer = null;
        }
      }
      _runtime = Directory(tools.directory).absolute.path;
      _cache = (await Instances.desktopDataDirectory('dlss5-realtime')).path;
    }
    if (effects.frameGeneration && _fgRuntime == null) {
      _fgRuntime = (await DlssFrameGenerationRuntime.ensure(
        directory: Directory('$_cache/runtime-dlssg'),
        cancel: cancel,
        allowDownload: allowInstall,
        onProgress: (value) {
          status = value;
          notifyListeners();
        },
      )).path;
    }
    if (cancel.isCancelled) throw cancel.cancelError!;
  }

  void cancelSetup() {
    _cancel?.cancel('已取消');
    _installer?.cancel();
  }

  void close() {
    cancelSetup();
    _bridge.dlssStatus.removeListener(_statusChanged);
  }
}
