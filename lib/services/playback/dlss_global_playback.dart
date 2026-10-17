import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:baka/instance.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'dlss_frame_generation_runtime.dart';
import 'dlss_runtime_installer.dart';

@immutable
class DlssPlaybackEffects {
  const DlssPlaybackEffects({
    this.intensity = .7,
    this.sharpness = .35,
    this.maxHeight = 1080,
    this.superResolution = true,
    this.frameGeneration = true,
    this.neuralRendering = false,
    this.comparison = false,
  });

  final double intensity;
  final double sharpness;
  final int maxHeight;
  final bool superResolution;
  final bool frameGeneration;
  final bool neuralRendering;
  final bool comparison;

  factory DlssPlaybackEffects.fromJson(Map<String, dynamic> json) {
    final intensity = json['intensity'];
    final sharpness = json['sharpness'];
    return DlssPlaybackEffects(
      intensity: intensity is num && intensity.isFinite
          ? intensity.toDouble().clamp(.1, 2.0)
          : .7,
      sharpness: sharpness is num && sharpness.isFinite
          ? sharpness.toDouble().clamp(0.0, 1.0)
          : .35,
      maxHeight: json['maxHeight'] == 720 ? 720 : 1080,
      superResolution: json['superResolution'] is bool
          ? json['superResolution'] as bool
          : true,
      frameGeneration: json['frameGeneration'] is bool
          ? json['frameGeneration'] as bool
          : true,
      neuralRendering: json['neuralRendering'] == true,
      comparison: json['comparison'] == true,
    );
  }

  DlssPlaybackEffects copyWith({
    double? intensity,
    double? sharpness,
    int? maxHeight,
    bool? superResolution,
    bool? frameGeneration,
    bool? neuralRendering,
    bool? comparison,
  }) => DlssPlaybackEffects(
    intensity: intensity ?? this.intensity,
    sharpness: sharpness ?? this.sharpness,
    maxHeight: maxHeight ?? this.maxHeight,
    superResolution: superResolution ?? this.superResolution,
    frameGeneration: frameGeneration ?? this.frameGeneration,
    neuralRendering: neuralRendering ?? this.neuralRendering,
    comparison: comparison ?? this.comparison,
  );

  Map<String, dynamic> toJson() => {
    'intensity': intensity,
    'sharpness': sharpness,
    'maxHeight': maxHeight,
    'superResolution': superResolution,
    'frameGeneration': frameGeneration,
    'neuralRendering': neuralRendering,
    'comparison': comparison,
  };

  @override
  bool operator ==(Object other) =>
      other is DlssPlaybackEffects &&
      intensity == other.intensity &&
      sharpness == other.sharpness &&
      maxHeight == other.maxHeight &&
      superResolution == other.superResolution &&
      frameGeneration == other.frameGeneration &&
      neuralRendering == other.neuralRendering &&
      comparison == other.comparison;

  @override
  int get hashCode => Object.hash(
    intensity,
    sharpness,
    maxHeight,
    superResolution,
    frameGeneration,
    neuralRendering,
    comparison,
  );
}

/// Configures the shared Windows video renderer, including preview players.
/// URLs, HTTP headers, audio, tracks and playback controls stay with media_kit.
class DlssGlobalPlayback extends ChangeNotifier {
  static final instance = DlssGlobalPlayback();
  static const _key = 'dlss5_global_playback_enabled';
  static const _effectsKey = 'dlss5_global_playback_effects';
  static const _playbackKey = 'dlss5_playback_enabled';
  static const _channel = MethodChannel('com.alexmercerind/media_kit_video');
  bool enabled = false;
  bool playbackEnabled = true;
  bool busy = false;
  String status = '关闭后使用普通播放器画面';
  String? error;
  Timer? _timer;
  CancelToken? _cancel;
  DlssRuntimeInstaller? _installer;
  bool _polling = false;
  Map<String, String> _runtimePaths = const {};
  DlssPlaybackEffects effects = const DlssPlaybackEffects();
  bool get hasFallback =>
      enabled && playbackEnabled && status.contains('普通画面：');
  bool get hasEnhancedOutput =>
      enabled && playbackEnabled && status.contains('增强画面已提交');

  Future<void> initialize() async {
    if (!Platform.isWindows) return;
    playbackEnabled = Instances.sp.getBool(_playbackKey) ?? true;
    try {
      final saved = Instances.sp.getString(_effectsKey);
      if (saved != null) {
        effects = DlssPlaybackEffects.fromJson(
          jsonDecode(saved) as Map<String, dynamic>,
        );
      }
    } catch (_) {
      effects = const DlssPlaybackEffects();
    }
    if (Instances.sp.getBool(_key) ?? false) {
      await _enable(allowInstall: false);
    }
  }

  Future<void> setEnabled(bool value) async {
    if (!Platform.isWindows || busy) return;
    if (value) {
      await _enable(allowInstall: true);
    } else {
      busy = true;
      notifyListeners();
      try {
        await _channel.invokeMethod<void>('Dlss.Configure', {
          'enabled': false,
          'runtime': '',
          'cache': '',
          'fgRuntime': '',
        });
        enabled = false;
        _timer?.cancel();
        _timer = null;
        await Instances.sp.setBool(_key, false);
        error = null;
        status = '已关闭，所有内置播放恢复普通画面';
      } catch (e) {
        error = '关闭失败：$e';
      } finally {
        busy = false;
        notifyListeners();
      }
    }
  }

  Future<bool> applyEffects(DlssPlaybackEffects value) async {
    if (!Platform.isWindows || busy) return false;
    if (enabled && playbackEnabled) {
      return _enable(allowInstall: true, nextEffects: value);
    }
    busy = true;
    notifyListeners();
    try {
      await Instances.sp.setString(_effectsKey, jsonEncode(value.toJson()));
      effects = value;
      error = null;
      status = '效果已保存，开启播放增强后生效';
      return true;
    } catch (e) {
      error = '保存效果失败：$e';
      return false;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// The laboratory switch is the master gate. This toggle preserves it.
  Future<void> setPlaybackEnabled(bool value) async {
    if (!Platform.isWindows || busy || !enabled) return;
    if (value) {
      await _enable(allowInstall: true, nextPlaybackEnabled: true);
      return;
    }
    busy = true;
    notifyListeners();
    try {
      await _channel.invokeMethod<void>('Dlss.Configure', {
        'enabled': false,
        'runtime': _runtimePaths['runtime'] ?? '',
        'cache': _runtimePaths['cache'] ?? '',
        'fgRuntime': _runtimePaths['fgRuntime'] ?? '',
        ...effects.toJson(),
      });
      playbackEnabled = false;
      _timer?.cancel();
      _timer = null;
      await Instances.sp.setBool(_playbackKey, false);
      error = null;
      status = '播放增强已关闭，可从播放器 DLSS 按钮重新开启';
    } catch (e) {
      error = '切换播放增强失败：$e';
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<bool> _enable({
    required bool allowInstall,
    DlssPlaybackEffects? nextEffects,
    bool? nextPlaybackEnabled,
  }) async {
    final selected = nextEffects ?? effects;
    final active = nextPlaybackEnabled ?? playbackEnabled;
    busy = true;
    error = null;
    status = '正在检查全局 DLSS 环境…';
    notifyListeners();
    final cancel = _cancel = CancelToken();
    try {
      var tools = DlssRuntime.load(Instances.sp);
      if (!await tools.isAvailable()) {
        if (!allowInstall) throw StateError('增强环境缺失，请在实验室重新开启并配置');
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
          if (result == null) throw StateError(installer.error ?? '增强环境配置未完成');
          tools = result;
          await tools.save(Instances.sp);
        } finally {
          installer.removeListener(progress);
          installer.dispose();
          _installer = null;
        }
      }
      if (cancel.isCancelled) throw cancel.cancelError!;
      final cache = await Instances.desktopDataDirectory('dlss5-realtime');
      final fg = selected.frameGeneration
          ? await DlssFrameGenerationRuntime.ensure(
              directory: Directory('${cache.path}/runtime-dlssg'),
              cancel: cancel,
              allowDownload: allowInstall,
              onProgress: (value) {
                status = value;
                notifyListeners();
              },
            )
          : null;
      if (cancel.isCancelled) throw cancel.cancelError!;
      final paths = {
        'runtime': Directory(tools.directory).absolute.path,
        'cache': cache.absolute.path,
        'fgRuntime': fg?.path ?? '',
      };
      await _channel.invokeMethod<void>('Dlss.Configure', {
        'enabled': active,
        ...paths,
        ...selected.toJson(),
      });
      _runtimePaths = paths;
      enabled = true;
      playbackEnabled = active;
      effects = selected;
      await Instances.sp.setBool(_playbackKey, active);
      await Instances.sp.setString(_effectsKey, jsonEncode(selected.toJson()));
      await Instances.sp.setBool(_key, true);
      status = active
          ? '已请求开启，等待增强画面；不支持时自动回退并显示原因'
          : '播放增强已关闭，可从播放器 DLSS 按钮重新开启';
      _scheduleStatus();
      return true;
    } catch (e) {
      error = cancel.isCancelled ? null : '配置全局增强失败：$e';
      status = enabled
          ? '配置未完成，当前播放继续使用已应用的效果'
          : cancel.isCancelled
          ? '配置已取消'
          : '普通播放可继续使用；请检查环境或重新构建 Windows 应用';
      return false;
    } finally {
      _cancel = null;
      busy = false;
      notifyListeners();
    }
  }

  Future<void> refreshStatus() async {
    if (!enabled || !playbackEnabled || busy || _polling) return;
    _polling = true;
    try {
      final value = await _channel.invokeMethod<String>('Dlss.Status');
      if (enabled &&
          playbackEnabled &&
          !busy &&
          value != null &&
          value != status) {
        status = value;
        notifyListeners();
      }
    } catch (e) {
      error = '读取增强状态失败：$e';
      notifyListeners();
    } finally {
      _polling = false;
    }
  }

  void _scheduleStatus() {
    _timer?.cancel();
    _timer = null;
    if (!enabled || !playbackEnabled) return;
    _timer = Timer(
      hasEnhancedOutput || hasFallback
          ? const Duration(seconds: 2)
          : const Duration(milliseconds: 250),
      () async {
        final timer = _timer;
        await refreshStatus();
        if (identical(_timer, timer)) _scheduleStatus();
      },
    );
  }

  void cancelSetup() {
    _cancel?.cancel('已取消');
    _installer?.cancel();
  }

  void close() {
    cancelSetup();
    _timer?.cancel();
    _timer = null;
  }
}
