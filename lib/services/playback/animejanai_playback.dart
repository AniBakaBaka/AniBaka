import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

import 'package:baka/instance.dart';
import 'package:baka/core/app_logger.dart';
import 'animejanai_runtime.dart';
import 'video_enhancement_bridge.dart';
import 'animejanai_types.dart';

export 'animejanai_types.dart';

/// Application settings and shared downloads; actual filter status belongs to
/// each playback, not to whichever player happened to update a global log last.
class AnimeJaNaiService extends ChangeNotifier {
  AnimeJaNaiService({AnimeJaNaiInstaller? installer})
    : installer = installer ?? AnimeJaNaiInstaller();
  static final instance = AnimeJaNaiService();
  final AnimeJaNaiInstaller installer;
  bool enabled = false;
  bool _preparing = false, _closed = false;
  AnimeJaNaiBackend backend = AnimeJaNaiBackend.auto;
  AnimeJaNaiProfile profile = AnimeJaNaiProfile.balanced;
  AnimeJaNaiLook look = AnimeJaNaiLook.original;
  bool interpolation = false;
  AnimeJaNaiFrameMultiplier frameMultiplier = AnimeJaNaiFrameMultiplier.x2;
  AnimeJaNaiInterpolationMode interpolationMode =
      AnimeJaNaiInterpolationMode.full;
  int get slot => interpolation
      ? frameMultiplier.slot(profile, mode: interpolationMode)
      : profile.slot;
  AnimeJaNaiPicture picture = AnimeJaNaiPicture();
  AnimeJaNaiRuntime? runtime;
  AnimeJaNaiGpu? gpu;
  String? error;
  int revision = 0;
  int _setupGeneration = 0;
  bool get busy => _preparing || installer.busy;
  String get status => busy
      ? installer.status
      : error ?? (runtime == null ? '未安装' : '${runtime!.backend.label} 环境已就绪');
  Future<void> _installs = Future<void>.value();

  void _notify() {
    if (!_closed) notifyListeners();
  }

  Future<void> initialize() async {
    if (!Platform.isWindows) return;
    installer.addListener(_notify);
    enabled =
        (Instances.sp.getBool('animejanai_enabled') ?? false) &&
        (Instances.sp.getBool('animejanai_playback') ?? true);
    await Instances.sp.setBool('animejanai_enabled', enabled);
    await Instances.sp.remove('animejanai_playback');
    backend = AnimeJaNaiBackend.fromStorage(
      Instances.sp.getString('animejanai_backend'),
    );
    profile = AnimeJaNaiProfile.fromStorage(
      Instances.sp.getString('animejanai_profile'),
    );
    look = AnimeJaNaiLook.fromStorage(
      Instances.sp.getString('animejanai_look'),
    );
    interpolation = Instances.sp.getBool('animejanai_interpolation') ?? false;
    frameMultiplier = AnimeJaNaiFrameMultiplier.fromStorage(
      Instances.sp.getString('animejanai_frame_multiplier'),
    );
    interpolationMode = AnimeJaNaiInterpolationMode.fromStorage(
      Instances.sp.getString('animejanai_interpolation_mode'),
    );
    picture = AnimeJaNaiPicture.fromStorage(
      Instances.sp.getString('animejanai_picture'),
    );
    if (enabled) await _prepare(allowInstall: false);
  }

  Future<AnimeJaNaiRuntime> runtimeFor(
    AnimeJaNaiBackend selected, {
    bool allowInstall = true,
  }) {
    final result = _installs.then((_) async {
      final directory = await Instances.desktopDataDirectory(
        'tools/animejanai',
      );
      final ready = await installer.ensure(
        directory,
        selected,
        sm: gpu?.sm,
        allowInstall: allowInstall,
      );
      await installer.ensureLook(ready, look, allowInstall: allowInstall);
      if (interpolation) {
        await installer.ensureInterpolation(
          ready,
          allowInstall: allowInstall,
          model: animeJaNaiInterpolationModel(interpolationMode),
        );
      }
      return ready;
    });
    _installs = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<bool> _prepare({required bool allowInstall}) async {
    final generation = _setupGeneration;
    _preparing = true;
    error = null;
    _notify();
    try {
      if (backend != AnimeJaNaiBackend.directML) {
        gpu ??= await compute((_) => AnimeJaNaiGpu.probe(), null);
      }
      if (_closed || generation != _setupGeneration) {
        throw const AnimeJaNaiInstallCancelled();
      }
      final selected = selectAnimeJaNaiBackend(backend, gpu);
      final ready = await runtimeFor(selected, allowInstall: allowInstall);
      if (_closed || generation != _setupGeneration) {
        throw const AnimeJaNaiInstallCancelled();
      }
      runtime = ready;
      return true;
    } catch (e) {
      error = e.toString();
      return false;
    } finally {
      _preparing = false;
      _notify();
    }
  }

  Future<void> setEnabled(bool value) async {
    if (!Platform.isWindows || busy) return;
    if (value) {
      if (runtime == null) {
        if (!await _prepare(allowInstall: true)) return;
      } else if (!await _prepareOptions(interpolation: interpolation)) {
        return;
      }
    }
    enabled = value;
    error = null;
    await Instances.sp.setBool('animejanai_enabled', value);
    revision++;
    _notify();
  }

  Future<void> setBackend(AnimeJaNaiBackend value) async {
    if (busy || value == backend) return;
    final previous = backend;
    backend = value;
    if (enabled && !await _prepare(allowInstall: true)) {
      backend = previous;
      _notify();
      return;
    }
    await Instances.sp.setString('animejanai_backend', value.name);
    revision++;
    _notify();
  }

  Future<void> setProfile(AnimeJaNaiProfile value) async {
    if (busy || value == profile) return;
    profile = value;
    await Instances.sp.setString('animejanai_profile', value.name);
    revision++;
    _notify();
  }

  Future<void> setLook(AnimeJaNaiLook value) async {
    if (busy || value == look) return;
    _preparing = true;
    error = null;
    _notify();
    try {
      if (enabled && runtime != null) {
        await installer.ensureLook(runtime!, value);
      }
      look = value;
      error = null;
      await Instances.sp.setString('animejanai_look', value.name);
      revision++;
    } catch (e) {
      error = '$e';
    } finally {
      _preparing = false;
    }
    _notify();
  }

  Future<bool> _prepareOptions({required bool interpolation}) async {
    _preparing = true;
    error = null;
    _notify();
    try {
      await installer.ensureLook(runtime!, look);
      if (interpolation) {
        await installer.ensureInterpolation(
          runtime!,
          model: animeJaNaiInterpolationModel(interpolationMode),
        );
      }
      return true;
    } catch (e) {
      error = '$e';
      return false;
    } finally {
      _preparing = false;
      _notify();
    }
  }

  Future<void> setInterpolation(bool value) async {
    if (busy || value == interpolation) return;
    if (value &&
        enabled &&
        runtime != null &&
        !await _prepareOptions(interpolation: true)) {
      return;
    }
    interpolation = value;
    error = null;
    await Instances.sp.setBool('animejanai_interpolation', value);
    revision++;
    _notify();
  }

  Future<void> setFrameMultiplier(AnimeJaNaiFrameMultiplier value) async {
    if (busy || value == frameMultiplier) return;
    frameMultiplier = value;
    await Instances.sp.setString('animejanai_frame_multiplier', value.name);
    revision++;
    _notify();
  }

  Future<void> setInterpolationMode(AnimeJaNaiInterpolationMode value) async {
    if (busy || value == interpolationMode) return;
    _preparing = true;
    error = null;
    _notify();
    try {
      if (enabled && interpolation && runtime != null) {
        await installer.ensureInterpolation(
          runtime!,
          model: animeJaNaiInterpolationModel(value),
        );
      }
      interpolationMode = value;
      await Instances.sp.setString('animejanai_interpolation_mode', value.name);
      revision++;
    } catch (e) {
      error = '$e';
    } finally {
      _preparing = false;
      _notify();
    }
  }

  void adjustPicture(AnimeJaNaiAdjustment key, double value) {
    if (picture[key] == value) return;
    picture[key] = value;
    revision++;
    _notify();
  }

  Future<void> savePicture() =>
      Instances.sp.setString('animejanai_picture', picture.toStorage());

  Future<void> close() async {
    _closed = true;
    installer.removeListener(_notify);
    cancelSetup();
    await _installs;
    installer.dispose();
  }

  void cancelSetup() {
    _setupGeneration++;
    installer.cancel();
  }
}

abstract class AnimeJaNaiPlayer extends ChangeNotifier {
  bool get playing;
  Map<String, String> get values;
  Future<void> command(List<String> args);
  Future<String> property(String name, {bool fresh = false});
  Future<void> pause();
  Future<void> play();
  Future<void> renderFrame();
}

class NativeAnimeJaNaiPlayer extends AnimeJaNaiPlayer {
  NativeAnimeJaNaiPlayer(this.player) {
    _ready = _attach();
  }
  final Player player;
  final _bridge = VideoEnhancementBridge.instance;
  late final Future<void> _ready;
  VideoProperties? _state;
  int? _handle;
  bool _closed = false;
  Future<Map<String, String>>? _reading;

  Future<void> _attach() async {
    final handle = await player.handle;
    if (_closed) return;
    _handle = handle;
    final state = _state = _bridge.attach(handle);
    state.addListener(notifyListeners);
    state.values.addAll(await _bridge.snapshot(handle));
    if (!_closed) notifyListeners();
  }

  @override
  bool get playing => player.state.playing;
  @override
  Map<String, String> get values => _state?.values ?? const {};
  @override
  Future<void> command(List<String> args) =>
      (player.platform as NativePlayer).command(args);
  @override
  Future<String> property(String name, {bool fresh = false}) async {
    await _ready;
    if (fresh && !_closed) {
      final values = await (_reading ??= _bridge
          .snapshot(_handle!)
          .whenComplete(() => _reading = null));
      _state!.values.addAll(values);
    }
    return _state?.values[name] ?? '';
  }

  @override
  Future<void> pause() => player.pause();
  @override
  Future<void> play() => player.play();
  @override
  Future<void> renderFrame() async {
    await _ready;
    await VideoEnhancementBridge.channel.invokeMethod<void>(
      'Video.RenderFrame',
      {'handle': _handle},
    );
  }

  @override
  void dispose() {
    _closed = true;
    notifyListeners();
    _state?.removeListener(notifyListeners);
    if (_handle case final handle?) _bridge.detach(handle);
    super.dispose();
  }
}

class AnimeJaNaiPlayback extends ChangeNotifier {
  AnimeJaNaiPlayback({
    AnimeJaNaiService? service,
    this.canPause,
    this.logDirectory,
  }) : service = service ?? AnimeJaNaiService.instance {
    _revision = this.service.revision;
    this.service.addListener(_changed);
  }
  final AnimeJaNaiService service;
  final bool Function()? canPause;
  final Future<Directory> Function()? logDirectory;
  AnimeJaNaiStatus status = AnimeJaNaiStatus.off;
  AnimeJaNaiPlayer? _player;
  AnimeJaNaiRuntime? _applied, _preferenceRuntime;
  AnimeJaNaiBackend? _decoderBackend;
  String? _configurationError;
  File? _stats;
  Timer? _timer;
  int _generation = 0, _revision = 0;
  bool _disposed = false, _polling = false, _configured = false;
  bool _filterAttached = false, _configuring = false;
  bool _wePaused = false, _pausePending = false, _manualResume = false;
  Future<void>? _pauseOperation;
  bool _recovering = false;
  bool _updating = false;
  Future<void> _updates = Future<void>.value();
  StreamSubscription<FileSystemEvent>? _statsChanges;
  bool _scheduled = false, _dirty = false, _logDirty = true;
  String _lastLog = '';
  AnimeJaNaiLook? _appliedLook;
  int? _appliedSlot;
  final _picture = <String, (String, double)>{};
  final _ownedFilters = <String>{};
  final _recentErrors = <String>[];
  String _inputDescription = '';
  bool _comparing = false;
  bool _wasBuilding = false;
  String? get hwdec => _configured
      ? (_applied?.backend == AnimeJaNaiBackend.tensorRT ? 'nvdec' : 'd3d11va')
      : null;

  void _set(AnimeJaNaiPhase phase, String message, {String details = ''}) {
    if (_disposed) return;
    if (status.phase == phase &&
        status.message == message &&
        status.backend == _applied?.backend &&
        status.details == details) {
      return;
    }
    status = AnimeJaNaiStatus(
      phase,
      message,
      backend: _applied?.backend,
      details: details,
    );
    if (phase == AnimeJaNaiPhase.failed) {
      Log.w('AnimeJaNai', '$message\n$details');
    }
    notifyListeners();
  }

  void beginMedia() {
    _generation++;
    _updating = false;
    _stopMonitoring();
    _recovering = false;
    _wePaused = false;
    _manualResume = false;
    _configured = false;
    _decoderBackend = null;
    _configurationError = null;
    _recentErrors.clear();
    _comparing = false;
    _wasBuilding = false;
    _set(AnimeJaNaiPhase.waiting, '等待视频');
  }

  void attach(AnimeJaNaiPlayer player) {
    detach();
    player.addListener(_requestUpdate);
    _generation++;
    _updating = false;
    _player = player;
    _configured = false;
    _filterAttached = false;
    _ownedFilters.clear();
    _decoderBackend = null;
    _timer?.cancel();
    _picture.clear();
    _comparing = false;
    _wasBuilding = false;
  }

  void detach() {
    _player?.removeListener(_requestUpdate);
    _player?.dispose();
    _generation++;
    _stopMonitoring();
    _player = null;
    _configured = false;
    _filterAttached = false;
    _ownedFilters.clear();
    _decoderBackend = null;
    _wePaused = false;
  }

  bool _current(int generation, AnimeJaNaiPlayer player) =>
      !_disposed && generation == _generation && identical(_player, player);

  Future<void> configure() async {
    final player = _player;
    if (_disposed || player == null) return;
    final generation = _generation;
    _applied = service.runtime;
    _preferenceRuntime = service.runtime;
    _configurationError = null;
    _configured = false;
    _wasBuilding = false;
    if (_filterAttached) {
      try {
        await _restorePicture(player, generation);
        await _removeFilter(player, generation);
      } catch (_) {}
      _filterAttached = false;
    }
    if (!_current(generation, player)) return;
    if (!service.enabled || _applied == null) {
      _set(
        service.error == null ? AnimeJaNaiPhase.off : AnimeJaNaiPhase.failed,
        service.error ?? 'AnimeJaNai 已关闭',
      );
      return;
    }
    try {
      final dir =
          await (logDirectory?.call() ??
              Instances.desktopDataDirectory('animejanai/logs'));
      if (!_current(generation, player)) return;
      _stats = File(
        '${dir.path}/${identityHashCode(this)}-$generation-${DateTime.now().microsecondsSinceEpoch}.log',
      );
      // Arm decoding before open, but attach the filter only after the first
      // decoded frame identifies hardware vs software input. Codec metadata
      // alone cannot tell whether NVDEC will actually accept the stream.
      _configured = true;
      _decoderBackend = _applied!.backend;
      _set(AnimeJaNaiPhase.waiting, '等待 ${_applied!.backend.label} 超分画面');
    } catch (e) {
      if (_current(generation, player)) {
        _configurationError = '$e';
        _set(AnimeJaNaiPhase.failed, 'AnimeJaNai 配置失败', details: '$e');
      }
    } finally {
      _configuring = false;
    }
  }

  void opened() {
    if (_configured && !_disposed) {
      _stopMonitoring();
      _logDirty = true;
      _lastLog = '';
      final stats = _stats!;
      final watched = stats.absolute.uri;
      _statsChanges = stats.parent.watch().listen((event) {
        if (File(event.path).absolute.uri == watched) {
          _logDirty = true;
          _requestUpdate();
        }
      });
      _requestUpdate();
    }
  }

  Future<void> retry() async {
    if (!service.enabled || service.busy || !status.failed) return;
    await configure();
    opened();
  }

  void _stopMonitoring() {
    _timer?.cancel();
    _timer = null;
    _statsChanges?.cancel();
    _statsChanges = null;
  }

  /// Called for both UI and remote playback events. A manual unpause during
  /// compilation relinquishes the pause lease, so a later pause is preserved.
  void playingChanged(bool playing) {
    if (playing && !_pausePending && _wePaused) {
      _wePaused = false;
      _manualResume = true;
    }
  }

  void userPaused() {
    _wePaused = false;
    _manualResume = true;
  }

  void nativeLog(String prefix, String level, String text) {
    if ((_configured || _configuring) &&
        (level == 'error' || level == 'fatal' || level == 'warn')) {
      _recentErrors.add('[$prefix] ${text.trim()}');
      if (_recentErrors.length > 24) _recentErrors.removeAt(0);
    }
    final player = _player;
    if ((!_configured && !_configuring) ||
        player == null ||
        _recovering ||
        (level != 'error' && level != 'fatal')) {
      return;
    }
    final component = '$prefix $text'.toLowerCase();
    if (component.contains('animejanai') ||
        component.contains('anibaka_aji') ||
        component.contains('tensorrt') ||
        component.contains('directml')) {
      if (_configuring) {
        _configurationError = text;
        return;
      }
      unawaited(_recover(text, _generation, player));
    }
  }

  bool ownsError(String text) =>
      (_configured || _configuring || _filterAttached) &&
      RegExp(
        r'animejanai|anibaka_aji|tensorrt|directml|aji_|inference shim',
        caseSensitive: false,
      ).hasMatch(text);

  Future<void> _releasePause(AnimeJaNaiPlayer player, int generation) async {
    await _pauseOperation;
    if (!_current(generation, player)) return;
    final resume = _wePaused && !player.playing;
    _wePaused = false;
    if (resume && _current(generation, player)) await player.play();
  }

  void _changed() {
    if (_disposed || _updating || _revision == service.revision) return;
    _revision = service.revision;
    final generation = ++_generation;
    final wasComparing = _comparing;
    _comparing = false;
    if (wasComparing) _appliedSlot = null;
    _updating = true;
    _updates = _updates
        .then((_) async {
          final player = _player;
          if (player == null || !_current(generation, player)) return;
          if (wasComparing) await _releasePause(player, generation);
          final next = service.runtime;
          // Preferences can be edited before enabling this enhancement.
          // Saving them must not rebuild ordinary playback.
          if (!service.enabled &&
              ((!_configured && !_filterAttached) ||
                  status.phase == AnimeJaNaiPhase.off)) {
            return;
          }
          if (_configured && next == _preferenceRuntime) {
            if (!service.enabled) {
              // AJI's runtime API switches to passthrough without rebuilding
              // the filter chain or invalidating frames held by the renderer.
              _stopMonitoring();
              await _restorePicture(player, generation);
              if (_filterAttached) {
                await player.command([
                  'vf-command',
                  'anibaka_aji',
                  'slot',
                  '0',
                ]);
              } else {
                _configured = false;
              }
              if (!_current(generation, player)) return;
              _appliedSlot = null;
              if (!player.playing) {
                await player.command(['seek', '0', 'relative+exact']);
              }
              await _releasePause(player, generation);
              _set(AnimeJaNaiPhase.off, 'AnimeJaNai 播放增强已关闭');
              return;
            }
            if (!_filterAttached) return;
            if (_appliedLook != service.look) {
              // vf add replaces matching labels atomically. Keep the current
              // chain visible until its replacement is ready to be attached.
              _filterAttached = false;
              _wasBuilding = false;
              final previous = _stats!;
              _stats = File(
                '${previous.parent.path}/${identityHashCode(this)}-$generation-${DateTime.now().microsecondsSinceEpoch}.log',
              );
              _configurationError = null;
              _set(AnimeJaNaiPhase.waiting, '正在切换模型风格');
              opened();
              return;
            }
            await _applyPicture(player, generation);
            if (!_current(generation, player)) return;
            if (_appliedSlot == service.slot) {
              // GPU picture options redraw the current frame themselves.
              // A decoder seek would unnecessarily rebuild the upload graph.
              return;
            }
            _wasBuilding = false;
            await player.command([
              'vf-command',
              'anibaka_aji',
              'slot',
              '${service.slot}',
            ]);
            _appliedSlot = service.slot;
            if (!_current(generation, player)) return;
            if (!player.playing) {
              await player.command(['seek', '0', 'relative+exact']);
            }
            _set(AnimeJaNaiPhase.waiting, '等待超分画面');
            opened();
          } else if (service.enabled &&
              next != null &&
              next == _preferenceRuntime &&
              _decoderBackend == next.backend) {
            // Re-enabling on the same media reuses its player and decoder.
            await configure();
            if (_current(generation, player)) opened();
          } else {
            await _releasePause(player, generation);
            // Both render APIs can present either backend through mpv's format
            // conversion. Reuse the texture/context while changing decoders.
            final changeDecoder = _decoderBackend != next?.backend;
            await configure();
            if (!_current(generation, player) || !_configured) return;
            if (changeDecoder) {
              await player.command(['set', 'hwdec', hwdec!]);
            }
            if (_current(generation, player)) opened();
          }
        })
        .catchError((Object e) {
          if (!_disposed && generation == _generation) {
            _set(AnimeJaNaiPhase.failed, '切换 AnimeJaNai 失败', details: '$e');
          }
        })
        .whenComplete(() {
          _updating = false;
          if (_revision != service.revision) _changed();
          if (_dirty) _requestUpdate();
        });
  }

  void _requestUpdate() {
    _dirty = true;
    if (_scheduled || _polling || _updating || _disposed) return;
    _scheduled = true;
    scheduleMicrotask(() {
      _scheduled = false;
      unawaited(poll());
    });
  }

  Future<void> poll() async {
    final player = _player;
    final stats = _stats;
    if (_disposed ||
        player == null ||
        stats == null ||
        !_configured ||
        _polling ||
        _recovering ||
        _updating ||
        _comparing ||
        !service.enabled) {
      return;
    }
    _polling = true;
    _dirty = false;
    final generation = _generation;
    try {
      if (!_filterAttached) {
        final input = player.values;
        final width = int.tryParse(input['video-params/w'] ?? '') ?? 0;
        final height = int.tryParse(input['video-params/h'] ?? '') ?? 0;
        if (width == 0 || height == 0) return;
        final pixelFormat = input['video-params/pixelformat'] ?? '';
        final decoder = input['hwdec-current'] ?? '';
        _inputDescription =
            '$width×$height, pixelformat=$pixelFormat, hwdec-current=$decoder';
        // mpv can expose container dimensions before a decoded frame exists.
        // An unavailable decoder/format is not evidence of software decoding:
        // attaching hwupload_cuda now can receive CUDA frames when NVDEC starts.
        if (pixelFormat.isEmpty || decoder.isEmpty) return;
        // A D3D11 frame after requesting NVDEC is from the old decoder. Wait
        // for replacement metadata too if the decoder has changed to NVDEC
        // while the format still describes a software frame.
        if (_applied!.backend == AnimeJaNaiBackend.tensorRT &&
            (pixelFormat == 'd3d11' ||
                decoder == 'd3d11va' ||
                (decoder == 'nvdec' && !pixelFormat.startsWith('cuda')))) {
          return;
        }
        if (_applied!.backend == AnimeJaNaiBackend.directML &&
            (pixelFormat.startsWith('cuda') ||
                decoder == 'nvdec' ||
                (decoder == 'd3d11va' && pixelFormat != 'd3d11'))) {
          return;
        }
        _configuring = true;
        _filterAttached = true;
        try {
          final config = File('${stats.path}.conf');
          await config.writeAsString(
            _applied!.configuration(service.look, inputHeight: height),
          );
          if (!_current(generation, player)) return;
          _ownedFilters.add('anibaka_aji');
          if (_applied!.backend == AnimeJaNaiBackend.tensorRT &&
              !pixelFormat.startsWith('cuda')) {
            _ownedFilters.add('anibaka_aji_input');
          }
          await player.command([
            'vf',
            'add',
            _applied!.filter(
              stats.path,
              service.profile,
              softwareDecoded: !pixelFormat.startsWith('cuda'),
              configPath: config.path,
              interpolation: service.interpolation,
              multiplier: service.frameMultiplier,
              mode: service.interpolationMode,
            ),
          ]);
          if (_configurationError != null) {
            throw StateError(_configurationError!);
          }
          if (!_current(generation, player)) return;
          _appliedLook = service.look;
          _appliedSlot = service.slot;
          await _applyPicture(player, generation);
          if (!player.playing) {
            await player.command(['seek', '0', 'relative+exact']);
          }
        } catch (e) {
          if (_current(generation, player)) {
            await _recover('$e', generation, player);
          }
          return;
        } finally {
          _configuring = false;
        }
        return;
      }
      if (_logDirty) {
        _logDirty = false;
        _lastLog = await stats.exists() ? await stats.readAsString() : '';
      }
      final log = _lastLog;
      if (!_current(generation, player)) return;
      if (log.contains('Building TensorRT engine')) {
        _wasBuilding = true;
        // AJI requires poll commands while a manually paused filter builds.
        // This timer exists only during engine compilation.
        _timer ??= Timer.periodic(const Duration(milliseconds: 500), (_) {
          _logDirty = true;
          _requestUpdate();
        });
        _set(
          AnimeJaNaiPhase.building,
          '正在编译 TensorRT 引擎，完成后自动生效',
          details: log,
        );
        if (!_wePaused &&
            !_manualResume &&
            player.playing &&
            (canPause?.call() ?? true)) {
          _pausePending = true;
          _wePaused = true;
          try {
            _pauseOperation = player.pause();
            await _pauseOperation;
          } finally {
            _pauseOperation = null;
            _pausePending = false;
          }
        }
        if (!_current(generation, player)) return;
        // A paused filter receives no frames: explicitly wake its async builder.
        await player.command(['vf-command', 'anibaka_aji', 'poll', '1']);
        return;
      }
      _timer?.cancel();
      _timer = null;
      final refreshPausedFrame = _wasBuilding && !player.playing && !_wePaused;
      _wasBuilding = false;
      await _releasePause(player, generation);
      if (!_current(generation, player)) return;
      if (refreshPausedFrame && !player.playing) {
        await player.command(['seek', '0', 'relative+exact']);
        return;
      }
      if (log.contains('build FAILED') || log.contains('ERROR:')) {
        await _recover(log, generation, player);
        return;
      }
      final values = player.values;
      final width = int.tryParse(values['video-params/w'] ?? '') ?? 0;
      final height = int.tryParse(values['video-params/h'] ?? '') ?? 0;
      if (width == 0 || height == 0) return;
      final outWidth = int.tryParse(values['video-out-params/w'] ?? '') ?? 0;
      final outHeight = int.tryParse(values['video-out-params/h'] ?? '') ?? 0;
      final resolution = RegExp(
        r'New Video Resolution: (\d+)x(\d+)',
      ).allMatches(log).lastOrNull;
      final upscaled =
          log.contains('Applied Model:') &&
          outWidth ==
              (resolution == null
                  ? width * 2
                  : int.parse(resolution.group(1)!)) &&
          outHeight ==
              (resolution == null
                  ? height * 2
                  : int.parse(resolution.group(2)!));
      final rife = RegExp(
        r'RIFE v(\d+) Interpolation ([\d.]+)x[^\r\n]*New Video FPS: ([\d.]+)',
        caseSensitive: false,
      ).firstMatch(log);
      final interpolated =
          rife != null &&
          rife.group(1) ==
              (service.interpolationMode == AnimeJaNaiInterpolationMode.fast
                  ? '4141'
                  : '414') &&
          double.tryParse(rife.group(2)!) == service.frameMultiplier.factor &&
          (double.tryParse(rife.group(3)!) ?? 0) > 0;
      final active =
          (values['vf'] ?? '').contains('anibaka_aji') &&
          (service.interpolation ? interpolated : upscaled) &&
          (log.contains('Applied Model:')
              ? upscaled
              : outWidth == width && outHeight == height);
      if (active) {
        final frames = service.interpolation
            ? ' · RIFE ${service.frameMultiplier.label} · ${service.interpolationMode == AnimeJaNaiInterpolationMode.fast ? '快速 · ' : ''}目标 ${rife!.group(3)} fps'
            : '';
        _set(
          AnimeJaNaiPhase.active,
          '${_applied!.backend.label} · ${service.profile.label} · ${service.look.label} · $width×$height → $outWidth×$outHeight$frames',
          details: '输入：$_inputDescription\n$log',
        );
        _statsChanges?.cancel();
        _statsChanges = null;
      } else if (log.contains('No Chains Activated')) {
        await _recover(
          '当前片源不匹配所选处理方案（支持最高 1080p、61 fps 输入）\n$log',
          generation,
          player,
        );
      } else if (service.interpolation && !interpolated) {
        _set(AnimeJaNaiPhase.waiting, '等待 RIFE 补帧生效', details: log);
      } else {
        _set(AnimeJaNaiPhase.waiting, '等待超分画面');
      }
    } catch (e) {
      if (_current(generation, player)) {
        await _recover('$e', generation, player);
      }
    } finally {
      _polling = false;
      if (_dirty) _requestUpdate();
    }
  }

  Future<void> _recover(
    String reason,
    int generation,
    AnimeJaNaiPlayer player,
  ) async {
    if (!_current(generation, player) || _recovering) return;
    reason = '${_recentErrors.join('\n')}\n$_inputDescription\n$reason';
    _recovering = true;
    _stopMonitoring();
    _configured = false;
    // An inference failure must not silently change the user's backend or
    // remove the requested effects and continue ordinary playback.
    _wePaused = false;
    _manualResume = true;
    try {
      await _pauseOperation;
      if (_current(generation, player) && player.playing) await player.pause();
    } catch (e) {
      reason = '$reason\n$e';
    } finally {
      _recovering = false;
      if (_current(generation, player)) {
        _set(
          AnimeJaNaiPhase.failed,
          'AnimeJaNai 处理失败，请检查错误后重试',
          details: reason,
        );
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    detach();
    service.removeListener(_changed);
    super.dispose();
  }

  Future<void> _removeFilter(AnimeJaNaiPlayer player, int generation) async {
    final owned = [for (final name in _ownedFilters) '@$name'];
    if (owned.isNotEmpty && _current(generation, player)) {
      await player.command(['vf', 'remove', owned.join(',')]);
    }
    if (_current(generation, player)) {
      _filterAttached = false;
      _ownedFilters.clear();
    }
  }

  Future<AnimeJaNaiComparison> captureComparison({
    required Future<Uint8List?> Function() captureFrame,
  }) {
    final player = _player;
    if (player == null ||
        !status.active ||
        _comparing ||
        !(canPause?.call() ?? true)) {
      return Future.error(StateError('请先等待超分生效，再生成同帧对比'));
    }
    final requested = _generation;
    _comparing = true;
    final savedStatus = status;
    final operation = _updates.then((_) async {
      if (!_current(requested, player) || !_comparing) {
        throw StateError('播放会话已改变');
      }
      final generation = ++_generation;
      var originalMode = false;
      var success = false;
      try {
        if (!_current(generation, player)) throw StateError('播放会话已改变');
        _set(AnimeJaNaiPhase.preparing, '正在生成同帧原画 / 超分对比');
        if (player.playing) {
          _wePaused = true;
          _pausePending = true;
          try {
            _pauseOperation = player.pause();
            await _pauseOperation;
          } finally {
            _pauseOperation = null;
            _pausePending = false;
          }
        }
        final position = double.tryParse(
          await player.property('time-pos', fresh: true),
        );
        final enhancedWidth = int.tryParse(
          player.values['video-out-params/w'] ?? '',
        );
        final originalWidth = int.tryParse(
          player.values['video-params/w'] ?? '',
        );
        if (position == null ||
            enhancedWidth == null ||
            originalWidth == null) {
          throw StateError('当前帧信息不可用');
        }
        Future<Uint8List> capture(int width) async {
          if (!_current(generation, player)) throw StateError('播放会话已改变');
          final restart = player.values['playback-restart'];
          await player.command(['seek', '$position', 'absolute+exact']);
          final ready = Completer<void>();
          void check() {
            if (ready.isCompleted) return;
            if (!_current(generation, player)) {
              ready.completeError(StateError('播放会话已改变'));
            } else if (player.values['playback-restart'] != restart &&
                player.values['seeking'] == 'no' &&
                int.tryParse(player.values['video-out-params/w'] ?? '') ==
                    width) {
              ready.complete();
            }
          }

          player.addListener(check);
          addListener(check);
          try {
            check();
            await ready.future.timeout(const Duration(seconds: 8));
          } finally {
            player.removeListener(check);
            removeListener(check);
          }
          await player.renderFrame().timeout(const Duration(seconds: 8));
          if (!_current(generation, player)) throw StateError('播放会话已改变');
          final image = await captureFrame();
          if (image == null || image.isEmpty) throw StateError('当前画面无法截图');
          return image;
        }

        // A property-change event precedes mpv's GPU option update. Decode the
        // selected frame before both captures so an immediate comparison also
        // includes adjustments that have not reached the renderer yet.
        final enhanced = await capture(enhancedWidth);
        if (!_current(generation, player)) throw StateError('播放会话已改变');
        await player.command(['vf-command', 'anibaka_aji', 'slot', '0']);
        originalMode = true;
        await _restorePicture(player, generation, clear: false);
        final original = await capture(originalWidth);
        if (!_current(generation, player)) throw StateError('播放会话已改变');
        await player.command([
          'vf-command',
          'anibaka_aji',
          'slot',
          '${service.slot}',
        ]);
        originalMode = false;
        await _applyPicture(player, generation);
        await player.command(['seek', '$position', 'absolute+exact']);
        if (!_current(generation, player)) throw StateError('播放会话已改变');
        success = true;
        _set(
          savedStatus.phase,
          savedStatus.message,
          details: savedStatus.details,
        );
        var closed = false;
        return AnimeJaNaiComparison(original, enhanced, () async {
          if (closed) return;
          closed = true;
          if (_current(generation, player)) {
            _comparing = false;
            await _releasePause(player, generation);
          }
        });
      } finally {
        if (!success && _current(generation, player)) {
          try {
            if (originalMode && _configured) {
              await player.command([
                'vf-command',
                'anibaka_aji',
                'slot',
                '${service.slot}',
              ]);
              await _applyPicture(player, generation);
              if (!player.playing) {
                await player.command(['seek', '0', 'relative+exact']);
              }
            }
          } finally {
            _comparing = false;
            await _releasePause(player, generation);
            if (_configured) {
              _set(
                savedStatus.phase,
                savedStatus.message,
                details: savedStatus.details,
              );
            }
          }
        }
      }
    });
    _updates = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  Future<void> _applyPicture(AnimeJaNaiPlayer player, int generation) async {
    for (final adjustment in AnimeJaNaiAdjustment.values) {
      if (!_current(generation, player)) return;
      final key = adjustment.property;
      final amount = service.picture[adjustment];
      final applied = _picture[key];
      if (amount == (applied?.$2 ?? 0)) continue;
      final original = applied?.$1 ?? await player.property(key);
      if (!_current(generation, player)) return;
      final base = double.parse(original);
      final value = (base + amount).clamp(
        key == 'sharpen' ? 0 : -100,
        key == 'sharpen' ? 2 : 100,
      );
      await player.command(['set', key, '$value']);
      if (!_current(generation, player)) return;
      if (amount == 0) {
        _picture.remove(key);
      } else {
        _picture[key] = (original, amount);
      }
    }
  }

  Future<void> _restorePicture(
    AnimeJaNaiPlayer player,
    int generation, {
    bool clear = true,
  }) async {
    for (final entry in _picture.entries) {
      if (!_current(generation, player)) return;
      await player.command(['set', entry.key, entry.value.$1]);
    }
    if (!_current(generation, player)) return;
    if (clear) {
      _picture.clear();
    } else {
      _picture.updateAll((_, value) => (value.$1, 0));
    }
  }
}

class AnimeJaNaiComparison {
  const AnimeJaNaiComparison(this.original, this.enhanced, this.close);
  final Uint8List original, enhanced;
  final Future<void> Function() close;
}
