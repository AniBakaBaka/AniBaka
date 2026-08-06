import 'dart:io';
import 'dart:typed_data';

import 'package:baka/instance.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:saver_gallery/saver_gallery.dart';

/// 图片预览与保存。
class ImageUtils {
  static final Dio _dio = Dio();

  static final _invalidFileCharsRe = RegExp(r'[<>:"/\\|?*]');

  /// 全屏预览图片（本地路径或网络地址），支持缩放。
  static Future<void> previewImage(String imagePath) async {
    final context = Instances.navigatorKey.currentContext;
    if (context == null) return;

    await showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.92),
      builder: (dialogContext) {
        final size = MediaQuery.sizeOf(dialogContext);
        final image = _isNetworkPath(imagePath)
            ? CachedNetworkImage(
                imageUrl: imagePath,
                fit: BoxFit.contain,
                placeholder: (_, _) => const Center(
                  child: CircularProgressIndicator(),
                ),
                errorWidget: (_, _, _) => const Icon(
                  Icons.broken_image_outlined,
                  color: Colors.white70,
                  size: 48,
                ),
              )
            : Image.file(
                File(imagePath),
                fit: BoxFit.contain,
                errorBuilder: (_, _, _) => const Icon(
                  Icons.broken_image_outlined,
                  color: Colors.white70,
                  size: 48,
                ),
              );

        return Material(
          color: Colors.transparent,
          child: Stack(
            children: [
              Positioned.fill(
                child: GestureDetector(
                  onTap: () => Navigator.of(dialogContext).pop(),
                  child: ColoredBox(
                    color: Colors.black.withValues(alpha: 0.92),
                  ),
                ),
              ),
              Center(
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: size.width - 24,
                    maxHeight: size.height - 24,
                  ),
                  child: InteractiveViewer(
                    minScale: 0.8,
                    maxScale: 4,
                    child: image,
                  ),
                ),
              ),
              Positioned(
                top: 8,
                right: 8,
                child: SafeArea(
                  child: IconButton(
                    icon: const Icon(Icons.close_rounded, color: Colors.white),
                    onPressed: () => Navigator.of(dialogContext).pop(),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// 保存图片：移动端进相册，桌面端弹出保存对话框。
  /// 返回保存后的文件名/路径，用户取消时返回 null。
  static Future<String?> saveImageToGallery(String imagePath) async {
    final imageData = await _loadImageData(imagePath);

    if (Platform.isAndroid || Platform.isIOS) {
      final granted = await _ensureGalleryPermission();
      if (!granted) {
        throw Exception('Gallery permission denied');
      }

      final result = await SaverGallery.saveImage(
        imageData.bytes,
        fileName: imageData.fileName,
        androidRelativePath: 'Pictures/Baka',
        skipIfExists: false,
      );
      if (!result.isSuccess) {
        throw Exception(result.errorMessage ?? 'Failed to save image');
      }
      return imageData.fileName;
    }

    final savePath = await FilePicker.saveFile(
      dialogTitle: 'Save image',
      fileName: imageData.fileName,
      type: FileType.custom,
      allowedExtensions: [imageData.extension],
    );
    if (savePath == null) return null;

    await File(savePath).writeAsBytes(imageData.bytes, flush: true);
    return savePath;
  }

  static Future<bool> _ensureGalleryPermission() async {
    if (Platform.isAndroid) {
      final androidInfo = await DeviceInfoPlugin().androidInfo;
      if (androidInfo.version.sdkInt >= 29) return true;
      return (await Permission.storage.request()).isGranted;
    }
    if (Platform.isIOS) {
      final status = await Permission.photosAddOnly.request();
      return status.isGranted || status.isLimited;
    }
    return true;
  }

  static bool _isNetworkPath(String path) {
    return path.startsWith('http://') || path.startsWith('https://');
  }

  static Future<({Uint8List bytes, String fileName, String extension})>
  _loadImageData(String imagePath) async {
    if (_isNetworkPath(imagePath)) {
      final response = await _dio.get<List<int>>(
        imagePath,
        options: Options(responseType: ResponseType.bytes),
      );
      final bytes = response.data;
      if (bytes == null || bytes.isEmpty) {
        throw Exception('Image download failed');
      }

      final contentType = response.headers.value(Headers.contentTypeHeader);
      final fileName = _resolveFileName(imagePath, contentType);
      return (
        bytes: Uint8List.fromList(bytes),
        fileName: fileName,
        extension: _fileExtension(fileName),
      );
    }

    final file = File(imagePath);
    final fileName = _sanitizeFileName(file.uri.pathSegments.last);
    return (
      bytes: await file.readAsBytes(),
      fileName: fileName,
      extension: _fileExtension(fileName),
    );
  }

  static String _resolveFileName(String imagePath, String? contentType) {
    final uri = Uri.tryParse(imagePath);
    final lastSegment = uri != null && uri.pathSegments.isNotEmpty
        ? uri.pathSegments.last
        : '';
    final sanitized = _sanitizeFileName(lastSegment);
    if (sanitized.contains('.')) return sanitized;

    final extension = _extensionFromContentType(contentType);
    return 'image_${DateTime.now().millisecondsSinceEpoch}.$extension';
  }

  static String _sanitizeFileName(String value) {
    final cleaned = value.replaceAll(_invalidFileCharsRe, '_').trim();
    return cleaned.isEmpty
        ? 'image_${DateTime.now().millisecondsSinceEpoch}.jpg'
        : cleaned;
  }

  static String _fileExtension(String fileName) {
    final index = fileName.lastIndexOf('.');
    if (index == -1 || index == fileName.length - 1) return 'jpg';
    return fileName.substring(index + 1).toLowerCase();
  }

  static String _extensionFromContentType(String? contentType) {
    final type = contentType?.toLowerCase() ?? '';
    if (type.contains('png')) return 'png';
    if (type.contains('gif')) return 'gif';
    if (type.contains('webp')) return 'webp';
    if (type.contains('bmp')) return 'bmp';
    return 'jpg';
  }
}
