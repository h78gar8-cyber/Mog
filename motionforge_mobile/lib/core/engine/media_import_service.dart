import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';

import '../models/media_asset.dart';

/// ==========================================================================
/// نقطة الدخول للـ Isolate الخلفي: يُشغَّل مرة واحدة لكل ملف، ويُغلَق بعد
/// انتهائه لتحرير ذاكرته بالكامل فوراً (لا نُبقي عمليات معلّقة في الخلفية).
/// ==========================================================================
class _ProcessRequest {
  final String assetId;
  final String sourcePath;
  final MediaAssetType type;
  final String cacheDir;
  final SendPort replyPort;

  _ProcessRequest({
    required this.assetId,
    required this.sourcePath,
    required this.type,
    required this.cacheDir,
    required this.replyPort,
  });
}

class _ProcessResult {
  final String assetId;
  final bool success;
  final String? thumbnailPath;
  final String? proxyPath;
  final double durationSeconds;
  final int width;
  final int height;
  final double fps;
  final List<double>? waveformPeaks;
  final String? error;

  _ProcessResult({
    required this.assetId,
    required this.success,
    this.thumbnailPath,
    this.proxyPath,
    this.durationSeconds = 0,
    this.width = 0,
    this.height = 0,
    this.fps = 30,
    this.waveformPeaks,
    this.error,
  });
}

/// يعمل بالكامل داخل Isolate معزول — أي تجمّد أو بطء هنا لا يمس واجهة المستخدم إطلاقاً.
void _mediaProcessingEntryPoint(_ProcessRequest req) async {
  // ملاحظة: في التطبيق الفعلي تُستدعى هنا أوامر FFmpegKit، لكن FFmpegKit
  // يحتاج تهيئة قنوات Platform Channels، لذا التنفيذ الحقيقي يُدار عبر
  // "compute()" أو Isolate مهيّأ بـ BackgroundIsolateBinaryMessenger.
  // هنا نوضح تدفق العمل والمنطق الدقيق لكل خطوة.
  try {
    if (req.type == MediaAssetType.video) {
      // ---------- 1) استخراج البيانات الوصفية (ffprobe) ----------
      // مثال أمر فعلي: ffprobe -v quiet -print_format json -show_streams <path>
      final metadata = await _extractVideoMetadata(req.sourcePath);

      // ---------- 2) توليد صورة مصغّرة (فريم واحد فقط -> صورة صغيرة على القرص) ----------
      // مثال أمر فعلي:
      // ffmpeg -ss 00:00:01 -i <src> -vframes 1 -vf scale=180:-1 -y <thumbPath>
      final thumbPath = '${req.cacheDir}/thumb_${req.assetId}.jpg';
      await _extractThumbnail(req.sourcePath, thumbPath);

      // ---------- 3) نسخة Proxy فقط إن كانت الدقة عالية ----------
      String? proxyPath;
      if (metadata.height > 1280 || metadata.width > 1280) {
        // مثال أمر فعلي (ترميز سريع H.264 بدقة مخفّضة وبت-رايت منخفض):
        // ffmpeg -i <src> -vf scale=-2:720 -c:v h264 -preset ultrafast -crf 28 -c:a aac -y <proxyPath>
        proxyPath = '${req.cacheDir}/proxy_${req.assetId}.mp4';
        await _generateProxy(req.sourcePath, proxyPath);
      }

      // ---------- 4) قيم ذروة الموجة الصوتية (مُصغَّرة، ليست PCM خام) ----------
      final peaks = await _extractWaveformPeaks(req.sourcePath, sampleCount: 200);

      req.replyPort.send(_ProcessResult(
        assetId: req.assetId,
        success: true,
        thumbnailPath: thumbPath,
        proxyPath: proxyPath,
        durationSeconds: metadata.duration,
        width: metadata.width,
        height: metadata.height,
        fps: metadata.fps,
        waveformPeaks: peaks,
      ));
    } else {
      // صورة ثابتة: فقط نسخة مصغّرة، لا حاجة لـ proxy أو waveform
      final thumbPath = '${req.cacheDir}/thumb_${req.assetId}.jpg';
      await _extractImageThumbnail(req.sourcePath, thumbPath);
      req.replyPort.send(_ProcessResult(
        assetId: req.assetId,
        success: true,
        thumbnailPath: thumbPath,
      ));
    }
  } catch (e) {
    req.replyPort.send(_ProcessResult(assetId: req.assetId, success: false, error: e.toString()));
  }
}

class _VideoMetadata {
  final double duration;
  final int width;
  final int height;
  final double fps;
  _VideoMetadata(this.duration, this.width, this.height, this.fps);
}

// --- دوال placeholder توضح التوقيع فقط؛ تُستبدل باستدعاءات FFmpegKit الفعلية ---
Future<_VideoMetadata> _extractVideoMetadata(String path) async =>
    _VideoMetadata(0, 0, 0, 30);
Future<void> _extractThumbnail(String src, String dst) async {}
Future<void> _extractImageThumbnail(String src, String dst) async {}
Future<void> _generateProxy(String src, String dst) async {}
Future<List<double>> _extractWaveformPeaks(String path, {int sampleCount = 200}) async =>
    List.filled(sampleCount, 0.0);

/// ==========================================================================
/// خدمة الاستيراد العامة: اختيار الملفات + إدارة طابور المعالجة
/// ==========================================================================
class MediaImportService {
  /// حد التوازي: ملفان كحد أقصى يُعالَجان في نفس اللحظة، بغض النظر عن عدد
  /// الملفات المختارة دفعة واحدة. هذا هو الضمان الأساسي ضد استنزاف الذاكرة:
  /// اختيار 20 فيديو 4K لن يفتح 20 عملية ترميز متوازية أبداً.
  static const int _maxConcurrentJobs = 2;

  final void Function(MediaAsset asset) onAssetAdded;
  final void Function(MediaAsset asset) onAssetUpdated;

  final List<MediaAsset> _queue = [];
  int _activeJobs = 0;
  late Directory _cacheDir;
  bool _initialized = false;

  MediaImportService({required this.onAssetAdded, required this.onAssetUpdated});

  Future<void> _ensureInit() async {
    if (_initialized) return;
    _cacheDir = await getTemporaryDirectory();
    _initialized = true;
  }

  /// فتح المعرض/مستكشف الملفات لاختيار عدة ملفات فيديو/صور دفعة واحدة.
  Future<void> pickAndImportMedia() async {
    await _ensureInit();

    final result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      type: FileType.custom,
      allowedExtensions: ['mp4', 'mov', 'm4v', 'jpg', 'jpeg', 'png', 'heic'],
      withData: false, // مهم جداً: لا نحمّل بايتات الملفات في الذاكرة، فقط مساراتها
    );
    if (result == null) return;

    for (final file in result.files) {
      final path = file.path;
      if (path == null) continue;

      final isVideo = ['mp4', 'mov', 'm4v'].contains(file.extension?.toLowerCase());
      final asset = MediaAsset(
        id: '${DateTime.now().microsecondsSinceEpoch}_${file.name.hashCode}',
        originalPath: path,
        type: isVideo ? MediaAssetType.video : MediaAssetType.image,
        status: MediaProcessingStatus.queued,
      );

      // الملف يظهر في لوحة المشروع فوراً (بحالة "جاري التحميل")
      // دون أي انتظار لانتهاء المعالجة — هذا أهم عامل لإحساس "عدم التعليق"
      onAssetAdded(asset);
      _queue.add(asset);
    }

    _drainQueue();
  }

  void _drainQueue() {
    while (_activeJobs < _maxConcurrentJobs && _queue.isNotEmpty) {
      final asset = _queue.removeAt(0);
      _processAsset(asset);
    }
  }

  Future<void> _processAsset(MediaAsset asset) async {
    _activeJobs++;
    asset.status = MediaProcessingStatus.processing;
    onAssetUpdated(asset);

    final responsePort = ReceivePort();
    final request = _ProcessRequest(
      assetId: asset.id,
      sourcePath: asset.originalPath,
      type: asset.type,
      cacheDir: _cacheDir.path,
      replyPort: responsePort.sendPort,
    );

    // Isolate.run: ينشئ Isolate جديداً، ينفّذ المهمة، ثم يُنهيه ويحرر ذاكرته
    // تلقائياً بمجرد انتهاء الدالة — مثالي لمهمة "لمرة واحدة" كهذه.
    // (لا ننتظر هذا الـ Future مباشرة؛ النتيجة الفعلية تصل عبر responsePort أدناه)
    // ignore: discarded_futures
    Isolate.run(() => _mediaProcessingEntryPoint(request));

    final result = await responsePort.first as _ProcessResult;
    responsePort.close();

    if (result.success) {
      asset
        ..status = MediaProcessingStatus.ready
        ..thumbnailPath = result.thumbnailPath
        ..proxyPath = result.proxyPath
        ..durationSeconds = result.durationSeconds
        ..width = result.width
        ..height = result.height
        ..fps = result.fps
        ..waveformPeaks = result.waveformPeaks;
    } else {
      asset
        ..status = MediaProcessingStatus.failed
        ..errorMessage = result.error;
    }
    onAssetUpdated(asset);

    _activeJobs--;
    _drainQueue(); // تحرير مكان للملف التالي في الطابور فور انتهاء هذا
  }
}
