import 'package:uuid/uuid.dart';

const _uuid = Uuid();

String newClientMsgId() => _uuid.v4().replaceAll('-', '');

String defaultImageFilename(String mimeType) =>
    'image_${_uuid.v4().replaceAll('-', '')}.${imageExtension(mimeType)}';

String imageExtension(String mimeType) {
  switch (mimeType.toLowerCase()) {
    case 'image/png':
      return 'png';
    case 'image/gif':
      return 'gif';
    default:
      return 'jpg';
  }
}

class Logger {
  Logger._();

  /// Replace bearer tokens / JWT-looking strings with `***` before logging.
  static String redact(String? input) {
    if (input == null || input.isEmpty) return '';
    var out = input;
    out = out.replaceAll(RegExp(r'Bearer\s+[A-Za-z0-9._\-]+'), 'Bearer ***');
    out = out.replaceAll(RegExp(r'eyJ[A-Za-z0-9._\-]{20,}'), '***');
    return out;
  }
}

/// Fixed-capacity FIFO set used to drop duplicate `event_id` /
/// `message.uuid` / `client_msg_id` from realtime publications.
class DedupCache {
  DedupCache({this.capacity = 256});

  final int capacity;
  final _set = <String>{};
  final _queue = <String>[];

  /// Returns `true` if [key] is new (and records it). `false` if duplicate.
  bool add(String? key) {
    if (key == null || key.isEmpty) return true;
    if (!_set.add(key)) return false;
    _queue.add(key);
    if (_queue.length > capacity) {
      _set.remove(_queue.removeAt(0));
    }
    return true;
  }
}
