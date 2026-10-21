import 'package:flutter_test/flutter_test.dart';
import 'package:video_downloader_converter/models/download_item.dart';

void main() {
  test('DownloadItem se serializa y deserializa correctamente', () {
    final item = DownloadItem(
      id: 'dl-1',
      url: 'https://www.youtube.com/watch?v=abc',
      title: 'Video de prueba',
      audioOnly: false,
    );
    item.progress = 42.5;

    final json = item.toJson();
    final restored = DownloadItem.fromJson(json);

    expect(restored.id, 'dl-1');
    expect(restored.title, 'Video de prueba');
    expect(restored.audioOnly, false);
    expect(restored.progress, 42.5);
    expect(restored.status, DownloadStatus.running);
  });
}
