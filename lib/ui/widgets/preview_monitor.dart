import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../../core/models/clip_model.dart';

/// نسبة عرض الـ Overlay الافتراضية من عرض الكانفاس الكامل عند scale=100%
const double kOverlayBaseFraction = 0.4;

/// شاشة المعاينة: تعرض فريم الخلفية، وفوقه كل طبقات الـ Overlay كعناصر
/// مستقلة قابلة للمس كل واحدة على حدة. الاعتماد هنا على GestureDetector
/// منفصل لكل Overlay (بدل معالج لمس واحد يفسّر الإحداثيات يدوياً) يستفيد
/// من "Gesture Arena" المدمج في فلاتر: العنصر الأعلى بصرياً في الـ Stack
/// يفوز تلقائياً باللمس عند التداخل، وهو بالضبط سلوك "اضغط على الفيديو
/// العلوي لتحريكه" المطلوب دون أي كود Hit-testing يدوي إضافي.
class PreviewMonitor extends StatelessWidget {
  final ui.Image? backgroundFrame;
  final bool isProxy;
  final Size canvasResolution; // دقة المشروع الحقيقية (مثال: 1080x1920)
  final List<Clip> overlayClips; // مرتّبة من الأسفل للأعلى (نفس ترتيب الطبقات)
  final String? selectedOverlayClipId;
  final double currentTime;
  final ValueChanged<String> onOverlaySelected;
  final VoidCallback onOverlayChanged; // لإعلام الشاشة الرئيسية بضرورة إعادة الرندرة

  const PreviewMonitor({
    super.key,
    required this.backgroundFrame,
    required this.canvasResolution,
    required this.overlayClips,
    required this.currentTime,
    required this.onOverlaySelected,
    required this.onOverlayChanged,
    this.isProxy = false,
    this.selectedOverlayClipId,
  });

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: canvasResolution.width / canvasResolution.height,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.black,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: AppColors.divider, width: 1),
        ),
        clipBehavior: Clip.antiAlias,
        child: LayoutBuilder(builder: (context, constraints) {
          final boxSize = Size(constraints.maxWidth, constraints.maxHeight);
          final scaleFactor = boxSize.width / canvasResolution.width;

          return Stack(
            fit: StackFit.expand,
            children: [
              // ---------- طبقة الخلفية (لا تُحرَّك مباشرة من هذه الشاشة) ----------
              backgroundFrame == null
                  ? const Center(
                      child: Icon(Icons.movie_creation_outlined,
                          color: AppColors.textSecondary, size: 48),
                    )
                  : RawImageDisplay(image: backgroundFrame!),

              // ---------- طبقات الـ Overlay، كل واحدة عنصر لمس مستقل ----------
              for (final clip in overlayClips)
                _OverlayHandle(
                  key: ValueKey(clip.id),
                  clip: clip,
                  boxSize: boxSize,
                  scaleFactor: scaleFactor,
                  isSelected: clip.id == selectedOverlayClipId,
                  currentTime: currentTime,
                  onSelected: () => onOverlaySelected(clip.id),
                  onChanged: onOverlayChanged,
                ),

              if (isProxy)
                Positioned(
                  top: 10,
                  left: 10,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Text('PROXY',
                        style: TextStyle(color: AppColors.warning, fontSize: 10, fontWeight: FontWeight.bold)),
                  ),
                ),
            ],
          );
        }),
      ),
    );
  }
}

/// عنصر Overlay واحد: يحسب موضعه/حجمه من AnimatedProperty الخاصة بالمقطع،
/// ويحدّثها مباشرة أثناء اللمس عبر setLiveValue (بلا كيفريم افتراضياً).
class _OverlayHandle extends StatefulWidget {
  final Clip clip;
  final Size boxSize;
  final double scaleFactor;
  final bool isSelected;
  final double currentTime;
  final VoidCallback onSelected;
  final VoidCallback onChanged;

  const _OverlayHandle({
    super.key,
    required this.clip,
    required this.boxSize,
    required this.scaleFactor,
    required this.isSelected,
    required this.currentTime,
    required this.onSelected,
    required this.onChanged,
  });

  @override
  State<_OverlayHandle> createState() => _OverlayHandleState();
}

class _OverlayHandleState extends State<_OverlayHandle> {
  double _gestureStartScale = 100.0;
  double _gestureStartRotation = 0.0;
  double _gestureStartX = 0.0;
  double _gestureStartY = 0.0;
  double _baseGestureScale = 1.0;
  double _baseGestureRotation = 0.0;

  @override
  Widget build(BuildContext context) {
    final clip = widget.clip;
    final t = widget.currentTime;

    final scalePercent = clip.scale.evaluate(t);
    final rotation = clip.rotation.evaluate(t) * 3.1415926535 / 180.0;
    final posX = clip.positionX.evaluate(t);
    final posY = clip.positionY.evaluate(t);

    final baseWidth = widget.boxSize.width * kOverlayBaseFraction;
    final width = baseWidth * (scalePercent / 100.0);
    final height = width * 9 / 16; // نسبة عرض/ارتفاع افتراضية لفيديو الـ Overlay

    final centerX = widget.boxSize.width / 2 + posX * widget.scaleFactor;
    final centerY = widget.boxSize.height / 2 + posY * widget.scaleFactor;

    return Positioned(
      left: centerX - width / 2,
      top: centerY - height / 2,
      width: width,
      height: height,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onScaleStart: (details) {
          widget.onSelected();
          _gestureStartScale = scalePercent;
          _gestureStartRotation = clip.rotation.evaluate(t);
          _gestureStartX = posX;
          _gestureStartY = posY;
          _baseGestureScale = 1.0;
          _baseGestureRotation = 0.0;
        },
        onScaleUpdate: (details) {
          if (details.pointerCount >= 2) {
            // إصبعان: تكبير + تدوير معاً (Pinch to Scale/Rotate)
            final newScale = (_gestureStartScale * details.scale).clamp(10.0, 400.0);
            final newRotationDeg =
                _gestureStartRotation + (details.rotation * 180 / 3.1415926535);
            clip.scale.setLiveValue(t, newScale);
            clip.rotation.setLiveValue(t, newRotationDeg);
          } else {
            // إصبع واحد: تحريك حر (Drag) داخل حدود الكانفاس
            final deltaCanvasX = details.focalPointDelta.dx / widget.scaleFactor;
            final deltaCanvasY = details.focalPointDelta.dy / widget.scaleFactor;
            final newX = clip.positionX.evaluate(t) + deltaCanvasX;
            final newY = clip.positionY.evaluate(t) + deltaCanvasY;
            clip.positionX.setLiveValue(t, newX);
            clip.positionY.setLiveValue(t, newY);
          }
          widget.onChanged();
        },
        child: Transform.rotate(
          angle: rotation,
          child: Container(
            decoration: BoxDecoration(
              border: Border.all(
                color: widget.isSelected ? AppColors.accent : Colors.white24,
                width: widget.isSelected ? 2 : 1,
              ),
              borderRadius: BorderRadius.circular(6),
            ),
            clipBehavior: Clip.antiAlias,
            child: Stack(
              fit: StackFit.expand,
              children: [
                _buildOverlayVisual(clip),
                if (widget.isSelected) _buildScaleHandleIndicator(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildOverlayVisual(Clip clip) {
    final thumb = clip.asset.thumbnailPath;
    if (thumb != null) {
      return Image.file(File(thumb), fit: BoxFit.cover);
    }
    return Container(color: AppColors.surfaceElevated);
  }

  Widget _buildScaleHandleIndicator() {
    return Positioned(
      right: 2,
      bottom: 2,
      child: Container(
        width: 16,
        height: 16,
        decoration: const BoxDecoration(color: AppColors.accent, shape: BoxShape.circle),
        child: const Icon(Icons.open_in_full_rounded, size: 10, color: Colors.white),
      ),
    );
  }
}

class RawImageDisplay extends StatelessWidget {
  final ui.Image image;
  const RawImageDisplay({super.key, required this.image});

  @override
  Widget build(BuildContext context) {
    return CustomPaint(painter: _ImagePainter(image), size: Size.infinite);
  }
}

class _ImagePainter extends CustomPainter {
  final ui.Image image;
  _ImagePainter(this.image);

  @override
  void paint(Canvas canvas, Size size) {
    final src = Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble());
    final dst = Rect.fromLTWH(0, 0, size.width, size.height);
    final paint = Paint()..filterQuality = FilterQuality.medium;
    canvas.drawImageRect(image, src, dst, paint);
  }

  @override
  bool shouldRepaint(covariant _ImagePainter oldDelegate) => oldDelegate.image != image;
}
