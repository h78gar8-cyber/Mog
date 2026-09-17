import 'dart:async';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:gal/gal.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../models/clip_model.dart';
import 'export_settings.dart';
import 'filter_graph_builder.dart';

enum ExportStatus { idle, preparing, running, completed, failed, canceled }

/// حالة التصدير اللحظية — تُبَث كـ Stream ليستمع لها أي widget (شريط تقدم،
/// شاشة كاملة، أو حتى إشعار) دون ربط مباشر بواجهة معيّنة.
class ExportProgress {
  final ExportStatus status;
  final double fraction; // 0.0 .. 1.0
  final Duration elapsed;
  final Duration? estimatedRemaining;
  final String? outputPath;
  final String? errorMessage;

  const ExportProgress({
    required this.status,
    this.fraction = 0.0,
    this.elapsed = Duration.zero,
    this.estimatedRemaining,
    this.outputPath,
    this.errorMessage,
  });
}

/// ============================================================================
/// محرك التصدير: يبني الأمر عبر FilterGraphBuilder، يشغّله بالخلفية عبر
/// FFmpegKit (الذي بدوره يستخدم MediaCodec/VideoToolbox حسب المنصة)، ويدير
/// دورة حياة العملية بالكامل (تقدم، منع سكون، حفظ، إشعار).
/// ============================================================================
class ExportEngine {
  final _controller = StreamController<ExportProgress>.broadcast();
  Stream<ExportProgress> get progressStream => _controller.stream;

  DateTime? _startTime;
  double _totalDurationSeconds = 0;
  int? _activeSessionId; // لدعم الإلغاء منتصف العملية
  bool _canceled = false;

  final FlutterLocalNotificationsPlugin _notifications = FlutterLocalNotificationsPlugin();

  Future<void> _ensureNotificationsInitialized() async {
    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosInit = DarwinInitializationSettings();
    await _notifications.initialize(
      const InitializationSettings(android: androidInit, iOS: iosInit),
    );
  }

  /// نقطة الدخول الرئيسية: يُستدعى من واجهة "تصدير" ويُدير كل شيء تلقائياً.
  Future<void> exportTimeline(TimelineModel timeline, ExportSettings settings) async {
    _canceled = false;
    _startTime = DateTime.now();
    _totalDurationSeconds = timeline.duration;
    _emit(const ExportProgress(status: ExportStatus.preparing));

    // ---------- 1) منع دخول الجهاز في وضع السكون طوال مدة التصدير ----------
    // بدون هذا، قد يُطفئ نظام التشغيل الشاشة ويُعلّق أي عملية معالجة ثقيلة
    // بعد بضع دقائق من عدم التفاعل — وهذا يسبب فشل تصدير الفيديوهات الطويلة.
    await WakelockPlus.enable();
    await _ensureNotificationsInitialized();

    try {
      final outputPath = await _buildOutputPath();
      final graph = FilterGraphBuilder(timeline).build();
      final isAndroid = Platform.isAndroid;
      final command = _buildFullCommand(graph, settings, outputPath, isAndroid: isAndroid);

      // ---------- 2) تشغيل FFmpeg في مسار خلفي حقيقي (وليس Isolate Dart) ----------
      // FFmpegKit ينفّذ العملية في Thread أصلي (Native) منفصل تماماً عن كل
      // من UI Isolate وأي Isolate آخر في Dart. هذا أهم من استخدام Isolate
      // هنا تحديداً، لأن المعالجة الثقيلة (فك تشفير+ترميز) تحدث بالكامل في
      // كود C/Native لا علاقة له بجدولة Dart إطلاقاً.
      await _runFfmpegSession(command, outputPath);
    } catch (e) {
      _emit(ExportProgress(status: ExportStatus.failed, errorMessage: e.toString()));
    } finally {
      await WakelockPlus.disable();
    }
  }

  Future<void> cancel() async {
    _canceled = true;
    if (_activeSessionId != null) {
      await _cancelFfmpegSession(_activeSessionId!);
    }
  }

  /// ==========================================================================
  /// تنفيذ جلسة FFmpeg الفعلية. الاستدعاءات هنا موضّحة بالتوقيع والمنطق
  /// الدقيق لواجهة FFmpegKit؛ الحزمة الفعلية (ffmpeg_kit_flutter_new) تحتاج
  /// ربط Platform Channel وقت البناء الحقيقي على جهاز.
  /// ==========================================================================
  Future<void> _runFfmpegSession(String command, String outputPath) async {
    // FFmpegKit.executeAsync(command, onCompletion, onLog, onStatistics)
    //
    // onStatistics يصل عشرات المرات في الثانية أثناء المعالجة، ويحتوي
    // videoFrameNumber/time (الزمن المُعالَج حتى الآن بالمللي ثانية) — منه
    // نحسب النسبة المئوية والوقت المتبقي التقريبي دون أي حساب يدوي معقّد.

    await _simulateFfmpegExecution(
      command: command,
      onStatistics: (processedTimeMs) {
        if (_canceled) return;
        final processedSeconds = processedTimeMs / 1000.0;
        final fraction = (_totalDurationSeconds > 0)
            ? (processedSeconds / _totalDurationSeconds).clamp(0.0, 1.0)
            : 0.0;

        final elapsed = DateTime.now().difference(_startTime!);
        Duration? eta;
        if (fraction > 0.02) {
          final totalEstimatedSeconds = elapsed.inMilliseconds / fraction / 1000.0;
          final remainingSeconds = (totalEstimatedSeconds - elapsed.inSeconds).clamp(0, double.infinity);
          eta = Duration(seconds: remainingSeconds.round());
        }

        _emit(ExportProgress(
          status: ExportStatus.running,
          fraction: fraction,
          elapsed: elapsed,
          estimatedRemaining: eta,
        ));
      },
      onCompletion: (success, logs) async {
        if (_canceled) {
          _emit(const ExportProgress(status: ExportStatus.canceled));
          return;
        }
        if (!success) {
          _emit(ExportProgress(status: ExportStatus.failed, errorMessage: logs));
          return;
        }
        await _finalizeExport(outputPath);
      },
    );
  }

  /// حفظ الملف النهائي في معرض الجهاز + إشعار المستخدم بالنجاح.
  Future<void> _finalizeExport(String outputPath) async {
    _emit(ExportProgress(status: ExportStatus.running, fraction: 0.99, outputPath: outputPath));

    try {
      // Gal.putVideo يحفظ في "Camera Roll" (آيفون) أو MediaStore (أندرويد)
      // مباشرة، وهو ما يجعله يظهر فوراً في تطبيق الصور/المعرض الافتراضي.
      await Gal.putVideo(outputPath, album: 'MotionForge');

      _emit(ExportProgress(status: ExportStatus.completed, fraction: 1.0, outputPath: outputPath));
      await _showCompletionNotification(success: true, path: outputPath);
    } catch (e) {
      _emit(ExportProgress(status: ExportStatus.failed, errorMessage: 'فشل الحفظ في المعرض: $e'));
      await _showCompletionNotification(success: false, path: null);
    }
  }

  Future<void> _showCompletionNotification({required bool success, String? path}) async {
    const androidDetails = AndroidNotificationDetails(
      'export_channel',
      'تصدير الفيديو',
      channelDescription: 'إشعارات اكتمال تصدير المشاريع',
      importance: Importance.high,
      priority: Priority.high,
    );
    const details = NotificationDetails(android: androidDetails, iOS: DarwinNotificationDetails());

    await _notifications.show(
      0,
      success ? 'تم التصدير بنجاح 🎉' : 'فشل التصدير',
      success ? 'الفيديو محفوظ في معرض الصور' : 'حدث خطأ أثناء تصدير الفيديو',
      details,
    );
  }

  Future<String> _buildOutputPath() async {
    final dir = await getTemporaryDirectory();
    final filename = 'export_${DateTime.now().millisecondsSinceEpoch}.mp4';
    return '${dir.path}/$filename';
  }

  /// تجميع أمر FFmpeg الكامل: الإدخالات + الفلتر المركّب + الترميز + الحاوية
  String _buildFullCommand(
    FilterGraphResult graph,
    ExportSettings settings,
    String outputPath, {
    required bool isAndroid,
  }) {
    final args = <String>[];

    for (final path in graph.inputPaths) {
      args.addAll(['-i', '"$path"']);
    }

    args.addAll(['-filter_complex', '"${graph.filterComplex}"']);
    args.addAll(['-map', '"[${graph.finalVideoLabel}]"']);
    args.addAll(['-map', '"[${graph.finalAudioLabel}]"']);

    args.addAll(settings.buildVideoCodecArgs(isAndroid: isAndroid));
    args.addAll(settings.buildAudioCodecArgs());
    args.addAll(settings.buildContainerArgs());

    args.add('"$outputPath"');
    return args.join(' ');
  }

  void _emit(ExportProgress progress) {
    if (!_controller.isClosed) _controller.add(progress);
  }

  void dispose() {
    _controller.close();
  }

  // -------------------- محاكاة توضيحية لتوقيع FFmpegKit فقط --------------------
  Future<void> _simulateFfmpegExecution({
    required String command,
    required void Function(int processedTimeMs) onStatistics,
    required Future<void> Function(bool success, String? logs) onCompletion,
  }) async {
    // في البناء الفعلي، هذا الجسم بالكامل يُستبدَل بـ:
    //
    // final session = await FFmpegKit.executeAsync(
    //   command,
    //   (session) async {
    //     final returnCode = await session.getReturnCode();
    //     await onCompletion(ReturnCode.isSuccess(returnCode), await session.getAllLogsAsString());
    //   },
    //   null,
    //   (Statistics stats) => onStatistics(stats.getTime()),
    // );
    // _activeSessionId = session.getSessionId();
    await onCompletion(true, null);
  }

  Future<void> _cancelFfmpegSession(int sessionId) async {
    // FFmpegKit.cancel(sessionId);
  }
}
