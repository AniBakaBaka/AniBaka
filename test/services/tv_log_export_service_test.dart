import 'dart:io';

import 'package:baka/services/tv_log_export_service.dart';
import 'package:baka/utils/app_logger.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('serves the log archive only from the generated download URL', () async {
    final tempDirectory = await Directory.systemTemp.createTemp(
      'baka_tv_log_export_test_',
    );
    final bytes = List<int>.generate(128, (index) => index);
    final file = File('${tempDirectory.path}${Platform.pathSeparator}logs.zip');
    await file.writeAsBytes(bytes);
    final archive = LogArchive(
      file: file,
      fileName: 'baka-logs-test.zip',
      logFileCount: 2,
      sizeBytes: bytes.length,
    );
    final session = TvLogExportSession(
      createArchive: () async => archive,
      findLanAddress: () async => InternetAddress.loopbackIPv4,
    );
    final client = HttpClient();

    try {
      final info = await session.start();
      final downloaded = session.downloadCount.first;
      final request = await client.getUrl(Uri.parse(info.url));
      final response = await request.close();
      final responseBytes = await response.fold<List<int>>(
        <int>[],
        (buffer, chunk) => buffer..addAll(chunk),
      );

      expect(response.statusCode, HttpStatus.ok);
      expect(response.headers.contentType?.mimeType, 'application/zip');
      expect(responseBytes, bytes);
      expect(await downloaded, 1);

      final missingRequest = await client.getUrl(
        Uri.parse(info.url).replace(path: '/logs/wrong/file.zip'),
      );
      final missingResponse = await missingRequest.close();
      await missingResponse.drain<void>();
      expect(missingResponse.statusCode, HttpStatus.notFound);
    } finally {
      client.close(force: true);
      await session.stop();
      await tempDirectory.delete(recursive: true);
    }
  });
}
