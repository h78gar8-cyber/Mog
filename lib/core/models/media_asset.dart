import 'package:flutter/foundation.dart';

enum MediaAssetType { video, image, audio }

/// مراحل معالجة الملف بالخلفية — الواجهة تعرض شكلاً مختلفاً لكل حالة
/// (Placeholder رمادي -> Progress -> صورة مصغّرة نهائية).
enum MediaProcessingStatus { queued, processing, ready, failed }

/// كائن بيانات وحيد لكل ملف مستورد. يُبنى فوراً عند اختيار الملف (بالمسار
/// الأصلي فقط)، ثم تُملأ بقية الحقول تدريجياً من الـ Isolate الخلفي دون
/// حجب واجهة المستخدم في أي لحظة.
class MediaAsset {
  final String id;
  final String originalPath; // المسار الحقيقي؛ يُستخدم دائماً عند التصدير النهائي
  final MediaAssetType type;

  MediaProcessingStatus status;
  String? thumbnailPath; // صورة مصغّرة صغيرة الحجم على القرص (وليست في الذاكرة)
  String? proxyPath;     // نسخة منخفضة الدقة على القرص، تُستخدم أثناء السحب/التحرير فقط
  double durationSeconds;
  int width;
  int height;
  double fps;
  List<double>? waveformPeaks; // مصفوفة صغيرة من قيم الذروة (وليس PCM خام)
  String? errorMessage;

  MediaAsset({
    required this.id,
    required this.originalPath,
    required this.type,
    this.status = MediaProcessingStatus.queued,
    this.thumbnailPath,
    this.proxyPath,
    this.durationSeconds = 0.0,
    this.width = 0,
    this.height = 0,
    this.fps = 30.0,
    this.waveformPeaks,
    this.errorMessage,
  });

  bool get isHighResolution => height > 1280 || width > 1280; // عتبة تفعيل الـ Proxy (~720p+)

  /// المسار الذي يجب استخدامه فعلياً أثناء التحرير الحي على التايم لاين:
  /// البروكسي إن وُجد (أخف وأسرع فك تشفير)، وإلا الأصلي مباشرة.
  String get editingPath => proxyPath ?? originalPath;
}

/// إشعار خفيف (ValueNotifier) لكل أصل على حدة، بدل إعادة بناء لوحة المشروع
/// بأكملها مع كل تحديث تقدّم لملف واحد فقط بين عشرات الملفات المستوردة.
class MediaAssetNotifier extends ValueNotifier<MediaAsset> {
  MediaAssetNotifier(super.value);
  void update(MediaAsset Function(MediaAsset current) updater) {
    value = updater(value);
  }
}
