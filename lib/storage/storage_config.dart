import 'dart:convert';

import 'package:baka/storage/storage_provider.dart';
import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';

class StorageConfig {
  final String id;
  final String name;
  final StorageProviderType type;
  final String path;
  final String? username;
  final String? password;
  final String rootPath;

  const StorageConfig({
    required this.id,
    required this.name,
    required this.type,
    required this.path,
    this.username,
    this.password,
    this.rootPath = '/',
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'type': type.index,
    'path': path,
    'username': username,
    'password': password,
    'rootPath': rootPath,
  };

  factory StorageConfig.fromJson(Map<String, dynamic> json) => StorageConfig(
    id: json['id'] as String,
    name: json['name'] as String,
    type: StorageProviderType.values[json['type'] as int],
    path: json['path'] as String,
    username: json['username'] as String?,
    password: json['password'] as String?,
    rootPath: json['rootPath'] as String? ?? '/',
  );
}

abstract final class StorageConfigService {
  static const _boxName = 'storage_configs';
  static const _configsKey = 'configs';

  static Box<dynamic>? _box;
  static Future<void>? _initFuture;
  static List<StorageConfig> _configs = const [];

  static final configsListenable = ValueNotifier<List<StorageConfig>>(_configs);

  static Future<void> init() => _initFuture ??= _initialize();

  static Future<void> _initialize() async {
    final box = await Hive.openBox<dynamic>(_boxName);
    _box = box;
    _publish(_decode(box.get(_configsKey)));
  }

  static List<StorageConfig> _decode(Object? raw) {
    if (raw == null) return const [];

    try {
      final values = raw is String ? jsonDecode(raw) : raw;
      if (values is! List) return const [];

      final configs = <StorageConfig>[];
      for (final value in values) {
        if (value is! Map) continue;
        try {
          configs.add(StorageConfig.fromJson(value.cast<String, dynamic>()));
        } catch (error) {
          debugPrint('Invalid storage config: $error');
        }
      }
      return configs;
    } catch (error) {
      debugPrint('Failed to load storage configs: $error');
      return const [];
    }
  }

  static Future<void> save(StorageConfig config) async {
    await init();
    final configs = List<StorageConfig>.of(_configs);
    final index = configs.indexWhere((item) => item.id == config.id);
    if (index < 0) {
      configs.add(config);
    } else {
      configs[index] = config;
    }
    await _persist(configs);
  }

  static Future<void> delete(String id) async {
    await init();
    final index = _configs.indexWhere((config) => config.id == id);
    if (index < 0) return;

    final configs = List<StorageConfig>.of(_configs)..removeAt(index);
    await _persist(configs);
  }

  static Future<void> _persist(List<StorageConfig> configs) async {
    await _box!.put(_configsKey, [
      for (final config in configs) config.toJson(),
    ]);
    _publish(configs);
  }

  static void _publish(List<StorageConfig> configs) {
    _configs = List<StorageConfig>.unmodifiable(configs);
    configsListenable.value = _configs;
  }
}
