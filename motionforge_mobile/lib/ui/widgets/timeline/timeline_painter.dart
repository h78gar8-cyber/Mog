import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import '../../theme/app_theme.dart';
import '../../../core/models/clip_model.dart';

const double kTrackHeight = 56.0;
const double kTrackSpacing = 6.0;

/// كاش صور مصغّرة صغير جداً على مستوى الراسم نفسه (وليس التايم لاين
/// بأكمله)، يمنع فك تشفير/تحميل نفس ملف الصورة المصغّرة عشرات المرات
/// أثناء كل عملية إعادة رسم (repaint) للتايم لاين.
class _ThumbnailImageCache {
  static final Map<String, ui.Image> _cache = {};
  static final Set<String> _loading = {};

  static ui.Image? get(String path) => _cache[path];

  static void loadIfNeeded(String path, VoidCallback onLoaded) {
    if (_cache.containsKey(path) || _loading.contains(path)) return;
    _loading.add(path);
    // قراءة غير متزامنة بالكامل: لا نحجب دورة الرسم (paint) إطلاقاً حتى
    // لجزء من الثانية أثناء تحميل ملف صورة مصغّرة من القرص.
    File(path).readAsBytes().then((bytes) {
      ui.decodeImageFromList(bytes, (img) {
        _cache[path] = img;
        _loading.remove(path);
        onLoaded();
      });
    });
  }
}

/// CustomPainter بدل بناء عشرات الـ Widgets للمقاطع: الرسم المباشر على
/// Canvas أسرع بكثير من تخطيط شجرة Widgets عند وجود عشرات المقاطع
/// والكيفريمات، وهذا ضروري للحفاظ على 60fps أثناء السحب السريع للتايم لاين.
const double kTrimHandleWidth = 14.0; // يجب أن يطابق نفس القيمة في timeline_widget.dart لكشف اللمس

class TimelinePainter extends CustomPainter {
  final TimelineModel timeline;
  final double pixelsPerSecond;
  final double playheadTime;
  final double viewportStartX; // لتطبيق "الرسم الجزئي" (Culling) للعناصر الظاهرة فقط
  final double viewportWidth;
  final String? selectedClipId;
  final VoidCallback onThumbnailLoaded; // يُستدعى عند وصول صورة مصغّرة جديدة لطلب إعادة رسم

  TimelinePainter({
    required this.timeline,
    required this.pixelsPerSecond,
    required this.playheadTime,
    required this.viewportStartX,
    required this.viewportWidth,
    required this.onThumbnailLoaded,
    this.selectedClipId,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final visibleStart = viewportStartX / pixelsPerSecond;
    final visibleEnd = (viewportStartX + viewportWidth) / pixelsPerSecond;

    canvas.save();
    // إزاحة الرسم بمقدار التمرير الحالي؛ التمرير يُدار يدوياً بدل ScrollView
    // قياسي، لأن هذا يتيح مزامنته بدقة مع منطق الزوم بالإصبعين (focal point)
    canvas.translate(-viewportStartX, 0);

    for (int trackIndex = 0; trackIndex < timeline.layers.length; trackIndex++) {
      final layer = timeline.layers[trackIndex];
      final trackY = trackIndex * (kTrackHeight + kTrackSpacing);

      for (final clip in layer.clips) {
        // ---- Culling: تجاهل رسم أي مقطع خارج المنطقة الظاهرة تماماً ----
        if (clip.endTime < visibleStart || clip.startTime > visibleEnd) continue;
        _paintClip(canvas, clip, trackY);
      }
    }

    _paintPlayhead(canvas, size);
    canvas.restore();
  }

  void _paintClip(Canvas canvas, Clip clip, double trackY) {
    final x = clip.startTime * pixelsPerSecond;
    final w = clip.duration * pixelsPerSecond;
    final rect = Rect.fromLTWH(x, trackY, w, kTrackHeight);
    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(10));

    final isSelected = clip.id == selectedClipId;
    final fillPaint = Paint()
      ..color = isSelected ? AppColors.accent : AppColors.accentSoft;

    canvas.save();
    canvas.clipRRect(rrect); // كل ما يُرسم بعدها (صورة/موجة) يبقى داخل حواف الشريط الدائرية
    canvas.drawRect(rect, fillPaint);

    // ---------- خلفية الصورة المصغّرة (Filmstrip مبسّط: صورة واحدة مكرّرة) ----------
    final thumbPath = clip.asset.thumbnailPath;
    if (thumbPath != null) {
      final image = _ThumbnailImageCache.get(thumbPath);
      if (image != null) {
        _drawTiledThumbnail(canvas, image, rect);
      } else {
        _ThumbnailImageCache.loadIfNeeded(thumbPath, onThumbnailLoaded);
      }
    }

    // ---------- الموجة الصوتية (إن وُجدت) ----------
    final peaks = clip.asset.waveformPeaks;
    if (peaks != null && peaks.isNotEmpty) {
      _drawWaveform(canvas, rect, peaks);
    }

    canvas.restore();

    if (isSelected) {
      final borderPaint = Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2;
      canvas.drawRRect(rrect, borderPaint);
      _drawTrimHandles(canvas, rect);
    }

    // نقاط الكيفريمات (Diamonds) على خاصية الشفافية كمثال توضيحي
    final kfPaint = Paint()..color = AppColors.warning;
    for (final kf in clip.opacity.keyframes) {
      final kx = x + kf.time * pixelsPerSecond;
      final ky = trackY + kTrackHeight - 10;
      _drawDiamond(canvas, Offset(kx, ky), 5, kfPaint);
    }
  }

  /// يرسم نفس الصورة المصغّرة مكررة أفقياً بعرض ثابت (شكل فيلم-سترِب مبسّط)
  /// بدل توليد عشرات الصور المختلفة على طول المقطع — تكلفة أقل بكثير على
  /// المعالجة والذاكرة، وكافٍ بصرياً لتمييز محتوى المقطع أثناء السحب.
  void _drawTiledThumbnail(Canvas canvas, ui.Image image, Rect rect) {
    const tileWidth = kTrackHeight * 0.7;
    final paint = Paint()..filterQuality = FilterQuality.low;
    final src = Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble());

    double cursor = rect.left;
    while (cursor < rect.right) {
      final dst = Rect.fromLTWH(cursor, rect.top, tileWidth, rect.height);
      canvas.drawImageRect(image, src, dst, paint);
      cursor += tileWidth;
    }
    // طبقة تعتيم خفيفة فوق الصور لإبقاء نص/كيفريمات المقطع واضحة فوقها
    canvas.drawRect(rect, Paint()..color = Colors.black.withValues(alpha: 0.25));
  }

  void _drawWaveform(Canvas canvas, Rect rect, List<double> peaks) {
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: 0.85)
      ..strokeWidth = 1.5;
    final midY = rect.top + rect.height * 0.72; // الموجة أسفل الشريط، تحت منطقة الفيلم-سترِب
    final maxBarHeight = rect.height * 0.26;
    final stepX = rect.width / peaks.length;

    for (int i = 0; i < peaks.length; i++) {
      final barHeight = peaks[i].clamp(0.0, 1.0) * maxBarHeight;
      final dx = rect.left + i * stepX;
      canvas.drawLine(Offset(dx, midY - barHeight / 2), Offset(dx, midY + barHeight / 2), paint);
    }
  }

  void _drawTrimHandles(Canvas canvas, Rect clipRect) {
    final handlePaint = Paint()..color = Colors.white;
    final gripPaint = Paint()
      ..color = AppColors.accentSoft
      ..strokeWidth = 2;

    for (final isLeft in [true, false]) {
      final handleRect = isLeft
          ? Rect.fromLTWH(clipRect.left, clipRect.top, kTrimHandleWidth, clipRect.height)
          : Rect.fromLTWH(clipRect.right - kTrimHandleWidth, clipRect.top, kTrimHandleWidth, clipRect.height);

      final rrect = RRect.fromRectAndCorners(
        handleRect,
        topLeft: isLeft ? const Radius.circular(10) : Radius.zero,
        bottomLeft: isLeft ? const Radius.circular(10) : Radius.zero,
        topRight: !isLeft ? const Radius.circular(10) : Radius.zero,
        bottomRight: !isLeft ? const Radius.circular(10) : Radius.zero,
      );
      canvas.drawRRect(rrect, handlePaint);

      // خطان صغيران (Grip lines) في منتصف المقبض لإيحاء بصري بأنه قابل للسحب
      final cx = handleRect.center.dx;
      final cy = handleRect.center.dy;
      canvas.drawLine(Offset(cx - 2, cy - 8), Offset(cx - 2, cy + 8), gripPaint);
      canvas.drawLine(Offset(cx + 2, cy - 8), Offset(cx + 2, cy + 8), gripPaint);
    }
  }

  void _drawDiamond(Canvas canvas, Offset center, double r, Paint paint) {
    final path = Path()
      ..moveTo(center.dx, center.dy - r)
      ..lineTo(center.dx + r, center.dy)
      ..lineTo(center.dx, center.dy + r)
      ..lineTo(center.dx - r, center.dy)
      ..close();
    canvas.drawPath(path, paint);
  }

  void _paintPlayhead(Canvas canvas, Size size) {
    final x = playheadTime * pixelsPerSecond;
    final paint = Paint()
      ..color = Colors.redAccent
      ..strokeWidth = 2;
    canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);

    // مقبض صغير أعلى المؤشر لسهولة الإمساك به بالإصبع
    final handlePaint = Paint()..color = Colors.redAccent;
    canvas.drawCircle(Offset(x, 6), 6, handlePaint);
  }

  @override
  bool shouldRepaint(covariant TimelinePainter oldDelegate) {
    return oldDelegate.pixelsPerSecond != pixelsPerSecond ||
        oldDelegate.playheadTime != playheadTime ||
        oldDelegate.viewportStartX != viewportStartX ||
        oldDelegate.selectedClipId != selectedClipId ||
        oldDelegate.timeline != timeline;
  }
}
