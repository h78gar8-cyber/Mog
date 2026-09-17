import 'package:flutter/material.dart';
import '../../theme/app_theme.dart';
import '../../../core/models/clip_model.dart';
import '../../../core/edit_operations.dart';
import 'timeline_painter.dart';

enum _TouchMode { none, scrub, moveClip, trimLeft, trimRight, zoom }

/// اللوحة التفاعلية الكاملة للتايم لاين. تدعم الآن:
/// - إصبعان (Pinch) -> تكبير/تصغير مع تثبيت النقطة الزمنية تحت اللمستين.
/// - لمس منطقة المقبض عند طرف مقطع محدد (~14dp) -> قص (Trim) بدل تحريك.
/// - لمس منتصف مقطع -> تحريكه أفقياً.
/// - لمس منطقة فارغة/المسطرة -> تحريك مؤشر التشغيل (Scrub).
/// - رأس طبقات ثابت على اليسار مع زر "طبقة +" لإضافة مسار جديد (Multi-track).
class TouchTimeline extends StatefulWidget {
  final TimelineModel timeline;
  final double playheadTime;
  final ValueChanged<double> onScrub;
  final ValueChanged<double>? onTrimPreview; // معاينة لحظية أثناء سحب مقبض القص
  final ValueChanged<bool>? onScrubbingStateChanged;
  final ValueChanged<String?>? onClipSelected;
  final VoidCallback? onTimelineChanged; // أي تعديل بنيوي (قص/تقسيم/طبقة جديدة)

  const TouchTimeline({
    super.key,
    required this.timeline,
    required this.playheadTime,
    required this.onScrub,
    this.onTrimPreview,
    this.onScrubbingStateChanged,
    this.onClipSelected,
    this.onTimelineChanged,
  });

  @override
  State<TouchTimeline> createState() => TouchTimelineState();
}

class TouchTimelineState extends State<TouchTimeline> {
  double _pixelsPerSecond = 70.0;
  static const double _minPxPerSec = 8.0;
  static const double _maxPxPerSec = 800.0;

  double _viewportStartX = 0.0;

  _TouchMode _mode = _TouchMode.none;
  Clip? _activeClip;
  double _dragClipStartOffset = 0.0;
  double _trimStartValue = 0.0; // startTime أو endTime عند بداية سحب المقبض

  double _gestureStartPxPerSec = 70.0;
  double _gestureStartViewportX = 0.0;
  Offset _gestureStartFocalLocal = Offset.zero;
  String? _selectedClipId;

  /// يُقرأ من الخارج (شاشة المحرر) لمعرفة المقطع المحدد حالياً عند الضغط على "قص".
  String? get selectedClipId => _selectedClipId;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildTrackHeaders(),
        Expanded(
          child: LayoutBuilder(builder: (context, constraints) {
            final viewportWidth = constraints.maxWidth;
            return Container(
              color: AppColors.surface,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onScaleStart: (details) => _handleScaleStart(details, viewportWidth),
                onScaleUpdate: (details) => _handleScaleUpdate(details, viewportWidth),
                onScaleEnd: (_) => _handleScaleEnd(),
                child: ClipRect(
                  child: CustomPaint(
                    size: Size(viewportWidth, _totalTracksHeight()),
                    painter: TimelinePainter(
                      timeline: widget.timeline,
                      pixelsPerSecond: _pixelsPerSecond,
                      playheadTime: widget.playheadTime,
                      viewportStartX: _viewportStartX,
                      viewportWidth: viewportWidth,
                      selectedClipId: _selectedClipId,
                      onThumbnailLoaded: () => setState(() {}),
                    ),
                  ),
                ),
              ),
            );
          }),
        ),
      ],
    );
  }

  /// عمود ثابت (لا يتحرك أفقياً مع التمرير) يعرض اسم كل طبقة وزر الإخفاء،
  /// وفي الأسفل زر "طبقة +" لإضافة مسار Overlay جديد فوق البقية مباشرة.
  Widget _buildTrackHeaders() {
    return Container(
      width: 72,
      color: AppColors.surfaceElevated,
      child: Column(
        children: [
          for (int i = 0; i < widget.timeline.layers.length; i++)
            _buildTrackHeaderTile(widget.timeline.layers[i], i),
          const SizedBox(height: 4),
          _buildAddTrackButton(),
        ],
      ),
    );
  }

  Widget _buildTrackHeaderTile(EditorLayer layer, int index) {
    final isTopOverlay = index > 0;
    return Container(
      height: kTrackHeight,
      margin: const EdgeInsets.only(bottom: kTrackSpacing),
      padding: const EdgeInsets.symmetric(horizontal: 6),
      alignment: Alignment.center,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            isTopOverlay ? Icons.picture_in_picture_alt_rounded : Icons.video_stable_rounded,
            size: 16,
            color: layer.visible ? AppColors.textPrimary : AppColors.textSecondary,
          ),
          const SizedBox(height: 2),
          GestureDetector(
            onTap: () => setState(() {
              layer.visible = !layer.visible;
              widget.onTimelineChanged?.call();
            }),
            child: Icon(
              layer.visible ? Icons.visibility_rounded : Icons.visibility_off_rounded,
              size: 14,
              color: AppColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAddTrackButton() {
    return GestureDetector(
      onTap: () {
        setState(() => widget.timeline.addLayer());
        widget.onTimelineChanged?.call();
      },
      child: Container(
        width: 44,
        height: 32,
        decoration: BoxDecoration(
          color: AppColors.accent.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppColors.accent, width: 1),
        ),
        child: const Icon(Icons.add_rounded, color: AppColors.accent, size: 18),
      ),
    );
  }

  double _totalTracksHeight() {
    final count = widget.timeline.layers.length.clamp(1, 999);
    return count * (kTrackHeight + kTrackSpacing);
  }

  // ---------------- منطق الإيماءات ----------------

  void _handleScaleStart(ScaleStartDetails details, double viewportWidth) {
    _gestureStartPxPerSec = _pixelsPerSecond;
    _gestureStartViewportX = _viewportStartX;
    _gestureStartFocalLocal = details.localFocalPoint;

    // إن كان هناك مقطع محدد بالفعل، نتحقق أولاً هل اللمس بدأ من فوق أحد
    // مقبضي القص الخاصين به (أولوية أعلى من التحريك العادي).
    final selected = _findClipById(_selectedClipId);
    if (selected != null && _isOnTrimHandle(selected, details.localFocalPoint, left: true)) {
      _mode = _TouchMode.trimLeft;
      _activeClip = selected;
      _trimStartValue = selected.startTime;
      return;
    }
    if (selected != null && _isOnTrimHandle(selected, details.localFocalPoint, left: false)) {
      _mode = _TouchMode.trimRight;
      _activeClip = selected;
      _trimStartValue = selected.endTime;
      return;
    }

    final clip = _hitTestClip(details.localFocalPoint);
    if (clip != null) {
      _mode = _TouchMode.moveClip;
      _activeClip = clip;
      _dragClipStartOffset = clip.startTime;
      setState(() => _selectedClipId = clip.id);
      widget.onClipSelected?.call(clip.id);
    } else {
      _mode = _TouchMode.scrub;
      widget.onScrubbingStateChanged?.call(true);
      _scrubToLocalX(details.localFocalPoint.dx);
    }
  }

  void _handleScaleUpdate(ScaleUpdateDetails details, double viewportWidth) {
    // ظهور إصبع ثانٍ يُلغي أي عملية قص/تحريك جارية ويحوّل فوراً لوضع الزوم،
    // لمنع تعديل غير مقصود لمقطع أثناء محاولة المستخدم تكبير التايم لاين.
    if (details.pointerCount >= 2) {
      if (_mode != _TouchMode.zoom) {
        _mode = _TouchMode.zoom;
        widget.onScrubbingStateChanged?.call(false);
      }
      _applyZoom(details);
      return;
    }

    switch (_mode) {
      case _TouchMode.scrub:
        _scrubToLocalX(details.localFocalPoint.dx);
        break;
      case _TouchMode.moveClip:
        _moveDraggedClip(details.localFocalPoint.dx);
        break;
      case _TouchMode.trimLeft:
        _applyTrimLeft(details.localFocalPoint.dx);
        break;
      case _TouchMode.trimRight:
        _applyTrimRight(details.localFocalPoint.dx);
        break;
      default:
        break;
    }
  }

  void _handleScaleEnd() {
    widget.onScrubbingStateChanged?.call(false);
    if (_mode == _TouchMode.trimLeft || _mode == _TouchMode.trimRight || _mode == _TouchMode.moveClip) {
      widget.onTimelineChanged?.call();
    }
    _mode = _TouchMode.none;
    _activeClip = null;
  }

  void _applyZoom(ScaleUpdateDetails details) {
    final newPxPerSec = (_gestureStartPxPerSec * details.scale).clamp(_minPxPerSec, _maxPxPerSec);
    final anchorTimeAtGestureStart =
        (_gestureStartViewportX + _gestureStartFocalLocal.dx) / _gestureStartPxPerSec;
    final newViewportX = anchorTimeAtGestureStart * newPxPerSec - details.localFocalPoint.dx;

    setState(() {
      _pixelsPerSecond = newPxPerSec;
      _viewportStartX = newViewportX.clamp(0.0, double.infinity);
    });
  }

  void _scrubToLocalX(double localX) {
    final t = ((_viewportStartX + localX) / _pixelsPerSecond).clamp(0.0, widget.timeline.duration);
    widget.onScrub(t);
  }

  void _moveDraggedClip(double localX) {
    final clip = _activeClip;
    if (clip == null) return;
    final deltaSeconds = (localX - _gestureStartFocalLocal.dx) / _pixelsPerSecond;
    setState(() {
      clip.startTime = (_dragClipStartOffset + deltaSeconds).clamp(0.0, double.infinity);
    });
  }

  /// ---------------- القص باللمس (Trimming) ----------------
  /// كل حركة إصبع هنا تستدعي EditOperations فقط (تعديل أرقام)، ثم فوراً
  /// تطلب معاينة الفريم عند نقطة القص الجديدة (Real-time thumbnail preview).

  void _applyTrimLeft(double localX) {
    final clip = _activeClip;
    if (clip == null) return;
    final deltaSeconds = (localX - _gestureStartFocalLocal.dx) / _pixelsPerSecond;
    final proposedStart = _trimStartValue + deltaSeconds;

    setState(() => EditOperations.trimStart(clip, proposedStart.clamp(0.0, clip.endTime)));
    widget.onTrimPreview?.call(clip.startTime); // تحديث شاشة العرض لحظياً على نقطة القص الجديدة
  }

  void _applyTrimRight(double localX) {
    final clip = _activeClip;
    if (clip == null) return;
    final deltaSeconds = (localX - _gestureStartFocalLocal.dx) / _pixelsPerSecond;
    final proposedEnd = _trimStartValue + deltaSeconds;

    setState(() => EditOperations.trimEnd(clip, proposedEnd.clamp(clip.startTime, double.infinity)));
    widget.onTrimPreview?.call(clip.endTime);
  }

  bool _isOnTrimHandle(Clip clip, Offset localPosition, {required bool left}) {
    final trackIndex = _trackIndexOf(clip);
    if (trackIndex == -1) return false;
    final trackY = trackIndex * (kTrackHeight + kTrackSpacing);
    if (localPosition.dy < trackY || localPosition.dy > trackY + kTrackHeight) return false;

    final worldX = localPosition.dx + _viewportStartX;
    final clipLeftX = clip.startTime * _pixelsPerSecond;
    final clipRightX = clip.endTime * _pixelsPerSecond;

    if (left) {
      return worldX >= clipLeftX && worldX <= clipLeftX + kTrimHandleWidth;
    } else {
      return worldX >= clipRightX - kTrimHandleWidth && worldX <= clipRightX;
    }
  }

  int _trackIndexOf(Clip clip) {
    for (int i = 0; i < widget.timeline.layers.length; i++) {
      if (widget.timeline.layers[i].clips.contains(clip)) return i;
    }
    return -1;
  }

  Clip? _findClipById(String? id) {
    if (id == null) return null;
    for (final layer in widget.timeline.layers) {
      for (final clip in layer.clips) {
        if (clip.id == id) return clip;
      }
    }
    return null;
  }

  Clip? _hitTestClip(Offset localPosition) {
    final worldX = localPosition.dx + _viewportStartX;
    final t = worldX / _pixelsPerSecond;
    final trackIndex = (localPosition.dy / (kTrackHeight + kTrackSpacing)).floor();
    if (trackIndex < 0 || trackIndex >= widget.timeline.layers.length) return null;

    final layer = widget.timeline.layers[trackIndex];
    for (final clip in layer.clips) {
      if (t >= clip.startTime && t <= clip.endTime) return clip;
    }
    return null;
  }
}
