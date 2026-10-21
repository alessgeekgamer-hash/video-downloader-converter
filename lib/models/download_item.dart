enum DownloadStatus { running, done, error, canceled }

class DownloadItem {
  final String id;
  final String url;
  String title;
  final bool audioOnly;
  DownloadStatus status;
  double progress;
  String? path;
  String? message;
  final DateTime date;

  DownloadItem({
    required this.id,
    required this.url,
    required this.title,
    required this.audioOnly,
    this.status = DownloadStatus.running,
    this.progress = 0,
    this.path,
    this.message,
    DateTime? date,
  }) : date = date ?? DateTime.now();

  Map<String, dynamic> toJson() => {
        'id': id,
        'url': url,
        'title': title,
        'audioOnly': audioOnly,
        'status': status.index,
        'progress': progress,
        'path': path,
        'message': message,
        'date': date.toIso8601String(),
      };

  factory DownloadItem.fromJson(Map<String, dynamic> j) => DownloadItem(
        id: j['id'] as String,
        url: j['url'] as String? ?? '',
        title: j['title'] as String? ?? 'Video',
        audioOnly: j['audioOnly'] as bool? ?? false,
        status: DownloadStatus.values[
            (j['status'] as int?)?.clamp(0, DownloadStatus.values.length - 1) ?? 0],
        progress: (j['progress'] as num?)?.toDouble() ?? 0,
        path: j['path'] as String?,
        message: j['message'] as String?,
        date: DateTime.tryParse(j['date'] as String? ?? ''),
      );
}
