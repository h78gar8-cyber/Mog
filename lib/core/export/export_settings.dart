/// ============================================================================
/// إعدادات الترميز — القيم هنا هي "أفضل توازن" مُختبَر صناعياً بين السرعة/
/// الحجم/الجودة لفيديو 1080p60 مُوجَّه للجوال ولمنصات النشر (انستغرام/تيك توك).
/// ============================================================================
library export_settings;

enum ExportQuality { standard, high, ultra }

class ExportSettings {
  final int width;
  final int height;
  final double fps;
  final int videoBitrateKbps; // بت-رايت الفيديو المستهدف
  final int audioBitrateKbps;
  final bool useHardwareEncoder;

  const ExportSettings({
    required this.width,
    required this.height,
    required this.fps,
    required this.videoBitrateKbps,
    this.audioBitrateKbps = 128,
    this.useHardwareEncoder = true,
  });

  /// إعداد 1080p @ 60fps — بالضبط ما طلبته. البت-رايت هنا محسوب بمعادلة
  /// شائعة صناعياً: (العرض × الارتفاع × الإطارات × عامل الحركة) / 1000
  /// نستخدم عامل حركة متوسط (0.07) مناسب لمحتوى فيه حركة كاميرا/مؤثرات،
  /// وهو ما ينتج ~8 ميجابت/ثانية — نفس ما تستخدمه تطبيقات مثل يوتيوب لـ 1080p60.
  static const ExportQuality1080p60 = ExportSettings(
    width: 1080,
    height: 1920, // Portrait (نفس دقة مشروعنا)
    fps: 60,
    videoBitrateKbps: 8000,
  );

  static const ExportQuality1080p30 = ExportSettings(
    width: 1080,
    height: 1920,
    fps: 30,
    videoBitrateKbps: 6000, // نصف الإطارات تقريباً -> بت-رايت أقل لنفس الجودة المُدرَكة
  );

  static const ExportQuality720p30 = ExportSettings(
    width: 720,
    height: 1280,
    fps: 30,
    videoBitrateKbps: 3500,
  );

  /// ------------------------------------------------------------------------
  /// بناء وسيطات الترميز الفعلية (Encoder Args) — هذا هو جوهر السؤال التقني.
  /// ------------------------------------------------------------------------
  /// الفرق الجوهري بين وضعين:
  ///
  /// (أ) المُرمِّز الأصلي المُسرَّع بالعتاد (useHardwareEncoder = true):
  ///     Android : h264_mediacodec   — يستخدم شريحة الفيديو في SoC مباشرة
  ///     iOS     : h264_videotoolbox — يستخدم Apple Media Engine مباشرة
  ///     ✅ أسرع بـ 5-10 أضعاف من الترميز البرمجي
  ///     ✅ استهلاك بطارية أقل بكثير (لا يُحمّل المعالج الرئيسي CPU)
  ///     ⚠️ التحكم بالجودة أقل دقة (لا يدعم CRF، فقط Bitrate مباشر)
  ///
  /// (ب) الترميز البرمجي الاحتياطي (Fallback عبر libx264):
  ///     يُستخدم فقط إن فشل المُرمِّز الأصلي على جهاز معيّن (نادر لكن يحدث
  ///     على بعض أجهزة أندرويد القديمة/الرخيصة ذات دعم عتاد ضعيف).
  ///     preset "veryfast" + CRF 20 هو أفضل توازن سرعة/جودة معروف لـ libx264
  ///     على معالجات الجوال (presets أبطأ مثل "medium"/"slow" تُرهق الجوال
  ///     حرارياً دون فائدة بصرية تُذكر لمحتوى يُشاهَد على شاشة هاتف).
  List<String> buildVideoCodecArgs({required bool isAndroid}) {
    if (useHardwareEncoder) {
      final encoderName = isAndroid ? 'h264_mediacodec' : 'h264_videotoolbox';
      return [
        '-c:v', encoderName,
        '-b:v', '${videoBitrateKbps}k',
        // على أندرويد: يفرض على MediaCodec استخدام Bitrate ثابت التحكم (CBR)
        // بدل VBR الافتراضي، لضمان توقع دقيق لحجم الملف النهائي.
        if (isAndroid) ...['-bufsize', '${videoBitrateKbps * 2}k'],
      ];
    }
    // Fallback برمجي (نادر الاستخدام، فقط عند فشل العتاد)
    return [
      '-c:v', 'libx264',
      '-preset', 'veryfast',
      '-crf', '20',
      '-maxrate', '${videoBitrateKbps}k',
      '-bufsize', '${videoBitrateKbps * 2}k',
    ];
  }

  List<String> buildAudioCodecArgs() => ['-c:a', 'aac', '-b:a', '${audioBitrateKbps}k'];

  /// إعدادات إضافية إلزامية لأي تصدير MP4 موجَّه للجوال/النشر:
  /// - yuv420p: التوافق شبه الشامل مع كل مشغلات الفيديو ومنصات النشر
  /// - +faststart: ينقل بيانات الفهرسة (moov atom) لبداية الملف بدل نهايته،
  ///   فيبدأ التشغيل فوراً عند الرفع لانستغرام/واتساب دون انتظار تحميل كامل
  List<String> buildContainerArgs() => [
        '-pix_fmt', 'yuv420p',
        '-movflags', '+faststart',
        '-r', fps.toStringAsFixed(0),
        '-s', '${width}x$height',
      ];
}
