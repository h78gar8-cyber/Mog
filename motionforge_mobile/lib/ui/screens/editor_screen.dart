import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../widgets/preview_monitor.dart';
import '../widgets/bottom_toolbar.dart';
import '../widgets/project_bin_widget.dart';
import '../widgets/timeline/timeline_widget.dart';
import '../../core/models/clip_model.dart';
import '../../core/models/keyframe_model.dart';
import '../../core/models/media_asset.dart';
import '../../core/engine/render_isolate.dart';
import '../../core/edit_operations.dart';
import '../../core/export/export_engine.dart';
import '../../core/export/export_settings.dart';
import '../widgets/export_progress_sheet.dart';

/// الشاشة الرئيسية: تخطيط طولي (Portrait) بثلاثة أقسام رأسية —
/// شاشة معاينة علوية (بها Overlays قابلة للمس المباشر)، تايم لاين
/// متعدد الطبقات وسطي، وشريط أدوات سفلي.
class EditorScreen extends StatefulWidget {
  const EditorScreen({super.key});

  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends State<EditorScreen> {
  late final TimelineModel _timeline;
  late final AsyncRenderEngine _engine;
  late final ExportEngine _exportEngine;

  // مرجع لحالة التايم لاين للوصول لـ selectedClipId عند الضغط على "تقسيم"
  final GlobalKey<TouchTimelineState> _timelineKey = GlobalKey<TouchTimelineState>();

  double _playheadTime = 0.0;
  String? _selectedClipId; // قد يكون مقطعاً على أي طبقة (خلفية أو Overlay)

  @override
  void initState() {
    super.initState();
    _timeline = _buildDemoTimeline();
    _engine = AsyncRenderEngine(fps: _timeline.fps, cacheMemoryMB: 256);
    _exportEngine = ExportEngine();
    _engine.frameStream.listen((frame) {
      if (!mounted) return;
      setState(() {}); // في التطبيق الفعلي: تحديث حالة الصورة المعروضة هنا
    });
    _requestFrame(0.0);
  }

  @override
  void dispose() {
    _engine.dispose();
    _exportEngine.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final overlays = _timeline.overlayClipsAtTime(_playheadTime);

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('مشروعي الجديد'),
        actions: [
          IconButton(icon: const Icon(Icons.undo_rounded), onPressed: () {}),
          IconButton(icon: const Icon(Icons.redo_rounded), onPressed: () {}),
          TextButton(
            onPressed: _startExport,
            child: const Text('تصدير', style: TextStyle(color: AppColors.accent)),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            // ---------- شاشة المعاينة العلوية (لمس مباشر لكل Overlay) ----------
            PreviewMonitor(
              backgroundFrame: null, // يُربط بآخر ui.Image واصل من _engine.frameStream
              isProxy: false,
              canvasResolution: Size(_timeline.resolutionWidth, _timeline.resolutionHeight),
              overlayClips: overlays,
              selectedOverlayClipId: _selectedClipId,
              currentTime: _playheadTime,
              onOverlaySelected: (id) => setState(() => _selectedClipId = id),
              onOverlayChanged: () => setState(() {}), // تحديث فوري للموضع/الحجم أثناء اللمس
            ),

            const SizedBox(height: 4),
            _buildPlaybackBar(),

            // ---------- لوحة ملفات المشروع (استيراد + معرض الملفات) ----------
            ProjectBinWidget(onAssetTap: _showAddTargetSheet),

            // ---------- التايم لاين متعدد الطبقات (قص/تحريك/زوم/طبقات) ----------
            Expanded(
              child: TouchTimeline(
                key: _timelineKey,
                timeline: _timeline,
                playheadTime: _playheadTime,
                onScrub: _requestFrame,
                onTrimPreview: _requestFrame, // معاينة لحظية للفريم أثناء سحب مقبض القص
                onScrubbingStateChanged: _engine.setLiveScrubbing,
                onClipSelected: (id) => setState(() => _selectedClipId = id),
                onTimelineChanged: () => _requestFrame(_playheadTime),
              ),
            ),

            // ---------- شريط الأدوات السفلي (Thumb-friendly) ----------
            BottomToolbar(
              items: buildDefaultToolbarItems(
                onFilters: () => _showBottomSheet('الفلاتر'),
                onText: () => _showBottomSheet('إضافة نص'),
                onSplit: _splitSelectedClip,
                onEffects: () => _showBottomSheet('المؤثرات'),
                onAudio: () => _showBottomSheet('الصوت'),
                onChromaKey: _toggleChromaKeyOnSelected,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPlaybackBar() {
    final selected = _findSelectedClip();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.play_arrow_rounded, color: AppColors.textPrimary),
            onPressed: () {},
          ),
          Text(
            '${_playheadTime.toStringAsFixed(2)}s / ${_timeline.duration.toStringAsFixed(1)}s',
            style: const TextStyle(color: AppColors.textSecondary, fontSize: 12),
          ),
          const Spacer(),
          if (selected != null)
            Chip(
              label: Text(
                _layerIndexOf(selected) > 0 ? 'Overlay: ${selected.id.substring(0, 8)}' : selected.id.substring(0, 8),
                style: const TextStyle(fontSize: 11),
              ),
              avatar: Icon(
                _hasChromaKey(selected) ? Icons.layers_clear_rounded : Icons.video_file_rounded,
                size: 16,
              ),
              backgroundColor: AppColors.surfaceElevated,
              onDeleted: () => setState(() => _selectedClipId = null),
            ),
        ],
      ),
    );
  }

  // =====================================================================
  // القص/التقسيم (Split) — لا يعالج أي بيانات فيديو، فقط أرقام على Clip
  // =====================================================================
  // =====================================================================
  // التصدير النهائي
  // =====================================================================
  void _startExport() {
    if (_timeline.layers.every((l) => l.clips.isEmpty)) {
      _showSnack('أضف مقطعاً واحداً على الأقل قبل التصدير');
      return;
    }

    showModalBottomSheet(
      context: context,
      isDismissible: false,
      enableDrag: false,
      backgroundColor: Colors.transparent,
      builder: (context) => ExportProgressSheet(
        progressStream: _exportEngine.progressStream,
        onCancel: () => _exportEngine.cancel(),
        onDone: () => Navigator.of(context).pop(),
      ),
    );

    // إعداد 1080p/60fps بالضبط كما طُلب؛ يمكن لاحقاً عرض خيارات جودة
    // إضافية للمستخدم (720p لملفات أخف، أو 30fps لتوفير الوقت والبطارية).
    _exportEngine.exportTimeline(_timeline, ExportSettings.ExportQuality1080p60);
  }

  void _splitSelectedClip() {
    final clip = _findSelectedClip();
    if (clip == null) {
      _showSnack('اختر مقطعاً على التايم لاين أولاً');
      return;
    }
    final layer = _layerOf(clip);
    if (layer == null) return;

    final newClip = EditOperations.split(layer, clip, _playheadTime);
    if (newClip == null) {
      _showSnack('المؤشر قريب جداً من طرف المقطع لتقسيمه');
      return;
    }

    setState(() => _selectedClipId = newClip.id);
    _requestFrame(_playheadTime); // التقسيم لا يغيّر الفريم المعروض فعلياً لكن نحدّث الحالة
  }

  // =====================================================================
  // إضافة طبقة Overlay فوق البقية + عزل الكروما
  // =====================================================================

  /// عند لمس ملف جاهز في لوحة المشروع، نسأل المستخدم: خلفية جديدة أم Overlay؟
  void _showAddTargetSheet(MediaAsset asset) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.video_stable_rounded, color: AppColors.accent),
              title: const Text('إضافة كطبقة أساسية', style: TextStyle(color: AppColors.textPrimary)),
              onTap: () {
                Navigator.pop(context);
                _addAssetToLayer(asset, layerIndex: 0);
              },
            ),
            ListTile(
              leading: const Icon(Icons.picture_in_picture_alt_rounded, color: AppColors.accent),
              title: const Text('إضافة كطبقة Overlay (فوق الفيديو)', style: TextStyle(color: AppColors.textPrimary)),
              onTap: () {
                Navigator.pop(context);
                _addAssetAsNewOverlay(asset);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _addAssetAsNewOverlay(MediaAsset asset) {
    final layer = _timeline.addLayer(name: 'Overlay ${_timeline.layers.length}');
    _addAssetToLayer(asset, layerIndex: _timeline.layers.indexOf(layer));
  }

  void _addAssetToLayer(MediaAsset asset, {required int layerIndex}) {
    if (_timeline.layers.isEmpty) {
      _timeline.layers.add(EditorLayer(id: 'layer_1', name: 'Layer 1'));
    }
    final layer = _timeline.layers[layerIndex.clamp(0, _timeline.layers.length - 1)];
    final lastEnd =
        layer.clips.isEmpty ? _playheadTime : layer.clips.map((c) => c.endTime).reduce((a, b) => a > b ? a : b);

    final clipDuration = asset.durationSeconds > 0 ? asset.durationSeconds : 5.0;
    final clip = Clip(
      id: 'clip_${DateTime.now().microsecondsSinceEpoch}',
      asset: asset,
      startTime: lastEnd,
      duration: clipDuration,
    );

    setState(() {
      layer.clips.add(clip);
      _timeline.duration = _timeline.layers
          .expand((l) => l.clips)
          .map((c) => c.endTime)
          .fold(_timeline.duration, (a, b) => b > a ? b : a);
      _selectedClipId = clip.id;
    });

    _requestFrame(_playheadTime);
  }

  /// تفعيل/تعطيل عزل الكروما على الـ Overlay المحدد فقط (لا معنى له لطبقة الخلفية)
  void _toggleChromaKeyOnSelected() {
    final clip = _findSelectedClip();
    if (clip == null || _layerIndexOf(clip) == 0) {
      _showSnack('اختر طبقة Overlay أولاً لتفعيل الكروما عليها');
      return;
    }
    setState(() {
      final existing = clip.effects.where((e) => e.type == EffectType.chromaKey).toList();
      if (existing.isNotEmpty) {
        clip.effects.remove(existing.first);
      } else {
        clip.effects.add(EffectInstance(
          type: EffectType.chromaKey,
          params: {'similarity': 0.4, 'smoothness': 0.15, 'keyR': 0.0, 'keyG': 1.0, 'keyB': 0.0},
        ));
      }
    });
    _requestFrame(_playheadTime);
  }

  bool _hasChromaKey(Clip clip) => clip.effects.any((e) => e.type == EffectType.chromaKey && e.enabled);

  // =====================================================================
  // مساعدات عامة
  // =====================================================================

  void _requestFrame(double t) {
    setState(() => _playheadTime = t);
    final snapshot = TimelineSnapshot(
      width: _timeline.resolutionWidth.toInt(),
      height: _timeline.resolutionHeight.toInt(),
      clipsState: _timeline
          .clipsAtTime(t)
          .map((entry) => {
                'id': entry.value.id,
                'opacity': entry.value.opacity.evaluate(t),
                'x': entry.value.positionX.evaluate(t),
                'y': entry.value.positionY.evaluate(t),
                'scale': entry.value.scale.evaluate(t),
                'effects': entry.value.effects.map((e) => e.type.name).toList(),
              })
          .toList(),
    );
    _engine.requestFrame(t, snapshot);
  }

  Clip? _findSelectedClip() {
    if (_selectedClipId == null) return null;
    for (final layer in _timeline.layers) {
      for (final clip in layer.clips) {
        if (clip.id == _selectedClipId) return clip;
      }
    }
    return null;
  }

  EditorLayer? _layerOf(Clip clip) {
    for (final layer in _timeline.layers) {
      if (layer.clips.contains(clip)) return layer;
    }
    return null;
  }

  int _layerIndexOf(Clip clip) {
    final layer = _layerOf(clip);
    return layer == null ? -1 : _timeline.layers.indexOf(layer);
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: AppColors.surfaceElevated),
    );
  }

  void _showBottomSheet(String title) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (context) => SizedBox(
        height: 260,
        child: Center(child: Text(title, style: const TextStyle(color: AppColors.textPrimary, fontSize: 16))),
      ),
    );
  }

  TimelineModel _buildDemoTimeline() {
    final model = TimelineModel();
    final baseLayer = EditorLayer(id: 'layer_1', name: 'Video 1');

    final demoAsset = MediaAsset(
      id: 'demo_asset',
      originalPath: '',
      type: MediaAssetType.video,
      status: MediaProcessingStatus.ready,
      durationSeconds: 12.0,
    );
    final clip = Clip(id: 'clip_1', asset: demoAsset, startTime: 0.0, duration: 6.0);
    clip.opacity.addKeyframe(const Keyframe(time: 0.0, value: 0.0));
    clip.opacity.addKeyframe(const Keyframe(time: 1.0, value: 100.0));
    baseLayer.clips.add(clip);
    model.layers.add(baseLayer);

    // طبقة Overlay تجريبية لعرض ميزة PiP فور فتح التطبيق
    final overlayLayer = model.addLayer(name: 'Overlay 1');
    final overlayAsset = MediaAsset(
      id: 'demo_overlay_asset',
      originalPath: '',
      type: MediaAssetType.video,
      status: MediaProcessingStatus.ready,
      durationSeconds: 6.0,
    );
    final overlayClip = Clip(id: 'clip_overlay_1', asset: overlayAsset, startTime: 1.0, duration: 4.0);
    overlayLayer.clips.add(overlayClip);

    model.duration = 6.0;
    return model;
  }
}
