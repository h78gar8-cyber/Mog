import 'models/clip_model.dart';

/// كل الدوال هنا "نقية" قدر الإمكان: تُعدّل أرقاماً فقط (inPoint/duration/
/// startTime)، ولا تفتح أي ملف ولا تستدعي FFmpeg. هذا هو سر الاستجابة
/// الفورية أثناء سحب مقابض القص بالإصبع.
class EditOperations {
  static const double minClipDuration = 0.15; // أقل مدة مسموحة لمقطع (ثانية)

  /// سحب المقبض الأيسر (تقصير من البداية): نزيد inPoint ونزيد startTime
  /// بنفس المقدار، ونُنقص duration بنفس المقدار — الفريم المعروض عند
  /// نقطة القص الجديدة يتغيّر فوراً لأن كل هذه القيم تُقرأ لحظياً عند الرندرة.
  static void trimStart(Clip clip, double newStartTime) {
    final delta = newStartTime - clip.startTime;
    final newDuration = clip.duration - delta;
    final newInPoint = clip.inPoint + delta;

    if (newDuration < minClipDuration) return; // منع القص لدرجة اختفاء المقطع
    if (newInPoint < 0) return; // لا يوجد محتوى قبل بداية الملف الأصلي

    clip.startTime = newStartTime;
    clip.duration = newDuration;
    clip.inPoint = newInPoint;
  }

  /// سحب المقبض الأيمن (تقصير من النهاية): duration فقط يتغيّر.
  /// نمنع تجاوز مدة الملف الأصلي الفعلية إن كانت معروفة (asset.durationSeconds > 0).
  static void trimEnd(Clip clip, double newEndTime) {
    final newDuration = newEndTime - clip.startTime;
    if (newDuration < minClipDuration) return;

    final assetDuration = clip.asset.durationSeconds;
    if (assetDuration > 0 && (clip.inPoint + newDuration) > assetDuration) {
      clip.duration = assetDuration - clip.inPoint;
      return;
    }
    clip.duration = newDuration;
  }

  /// التقسيم عند نقطة زمنية (عادة موقع المؤشر الحالي): يُنتج مقطعاً جديداً
  /// بنفس المصدر (asset) مع inPoint/startTime محسوبَين، دون أي نسخ فعلي
  /// لبيانات الفيديو — كلا الجزأين يشيران لنفس ملف asset.originalPath.
  static Clip? split(EditorLayer layer, Clip clip, double atTime) {
    if (atTime <= clip.startTime + minClipDuration ||
        atTime >= clip.endTime - minClipDuration) {
      return null; // نقطة القص قريبة جداً من أحد الطرفين؛ لا فائدة من التقسيم
    }

    final firstPartDuration = atTime - clip.startTime;
    final secondPartInPoint = clip.inPoint + firstPartDuration;
    final secondPartDuration = clip.duration - firstPartDuration;

    final secondClip = Clip(
      id: 'clip_${DateTime.now().microsecondsSinceEpoch}',
      asset: clip.asset,
      startTime: atTime,
      duration: secondPartDuration,
      inPoint: secondPartInPoint,
    );
    // نسخ التأثيرات المُفعَّلة (نفس النوع والقيم) للجزء الثاني، فكل جزء
    // يصبح مستقلاً بالكامل بعد التقسيم ويمكن تعديله دون التأثير على الآخر.
    for (final fx in clip.effects) {
      secondClip.effects.add(EffectInstance(type: fx.type, enabled: fx.enabled, params: Map.of(fx.params)));
    }

    // المقطع الأصلي يُقتَطع ليصبح الجزء الأول فقط
    clip.duration = firstPartDuration;

    final insertIndex = layer.clips.indexOf(clip) + 1;
    layer.clips.insert(insertIndex, secondClip);
    return secondClip;
  }
}
