/// 字节量与速率的显示格式化。
///
/// 下载页、Windows 播放器布局、BT 进度条原先各自内联了一份逐行相同的实现
/// （KB 档的小数位还各不相同），这里合并为唯一来源。
library;

const int _kb = 1024;
const int _mb = 1024 * 1024;
const int _gb = 1024 * 1024 * 1024;

String formatBytes(int bytes) {
  if (bytes < _kb) return '$bytes B';
  if (bytes < _mb) return '${(bytes / _kb).toStringAsFixed(1)} KB';
  if (bytes < _gb) return '${(bytes / _mb).toStringAsFixed(1)} MB';
  return '${(bytes / _gb).toStringAsFixed(2)} GB';
}

String formatBytesPerSecond(double bytesPerSecond) {
  if (bytesPerSecond < _kb) return '${bytesPerSecond.toStringAsFixed(0)} B/s';
  if (bytesPerSecond < _mb) {
    return '${(bytesPerSecond / _kb).toStringAsFixed(1)} KB/s';
  }
  return '${(bytesPerSecond / _mb).toStringAsFixed(1)} MB/s';
}
