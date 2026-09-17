import '../models/clip_model.dart';

/// ============================================================================
/// بناء filter_complex الخاص بـ FFmpeg — هذا هو "التركيب" الفعلي لكل الطبقات.
///
/// لماذا filter_complex وليس معالجة كل طبقة بأمر منفصل؟
/// لأن أمر FFmpeg واحد بفلتر مركّب واحد يعني أن الفيديو يُقرأ ويُرمَّز **مرة
/// واحدة فقط** (Single-pass) — كل الطبقات (قص + تراكب + كروما + نص + مؤثرات)
/// تُطبَّق داخل نفس خط أنابيب المعالجة الداخلي لـ FFmpeg فريماً بفريم، دون
/// كتابة ملفات وسيطة على القرص بين كل خطوة (وهذا ما يجعله سريعاً وموفراً
/// للذاكرة في آنٍ واحد).
/// ============================================================================
class FilterGraphBuilder {
  final TimelineModel timeline;
  FilterGraphBuilder(this.timeline);

  /// يُرجع: (قائمة مسارات الإدخال بالترتيب، سلسلة filter_complex الكاملة،
  /// اسم مخرَج الفيديو النهائي، اسم مخرَج الصوت النهائي)
  FilterGraphResult build() {
    final inputPaths = <String>[];
    final filterLines = <String>[];
    int inputIndex = 0;

    // كل مقطع = إدخال FFmpeg منفصل (-i)، مقصوصاً زمنياً بدقة عبر trim/atrim
    // (Virtual Cut حقيقي هنا أيضاً: -ss/-t على مستوى الفلتر لا يعيد ترميز شيء)
    final layerVideoLabels = <String>[];
    String? mixedAudioLabel;
    final audioLabelsToMix = <String>[];

    for (int layerIndex = 0; layerIndex < timeline.layers.length; layerIndex++) {
      final layer = timeline.layers[layerIndex];
      if (!layer.visible) continue;

      for (final clip in layer.clips) {
        final path = clip.asset.originalPath; // التصدير النهائي يعتمد دائماً على الأصلي، لا الـ Proxy
        inputPaths.add(path);
        final myIndex = inputIndex++;

        // ---------- 1) القص الافتراضي (Trim) عند مستوى كل مقطع ----------
        final vLabel = 'v$myIndex';
        final aLabel = 'a$myIndex';
        filterLines.add(
          '[$myIndex:v]trim=start=${clip.inPoint.toStringAsFixed(3)}:duration=${clip.duration.toStringAsFixed(3)},'
          'setpts=PTS-STARTPTS+${clip.startTime.toStringAsFixed(3)}/TB[$vLabel]',
        );
        filterLines.add(
          '[$myIndex:a]atrim=start=${clip.inPoint.toStringAsFixed(3)}:duration=${clip.duration.toStringAsFixed(3)},'
          'asetpts=PTS-STARTPTS+${clip.startTime.toStringAsFixed(3)}/TB[$aLabel]',
        );

        // ---------- 2) تطبيق التأثيرات المفعّلة على هذا المقطع تحديداً ----------
        String currentVideoLabel = vLabel;
        for (int fxIndex = 0; fxIndex < clip.effects.length; fxIndex++) {
          final fx = clip.effects[fxIndex];
          if (!fx.enabled) continue;
          final nextLabel = '${vLabel}_fx$fxIndex';
          filterLines.add(_buildEffectFilter(fx, currentVideoLabel, nextLabel));
          currentVideoLabel = nextLabel;
        }

        // طبقات الـ Overlay (index > 0) لا تُدمَج هنا مباشرة، بل تُراكَم
        // لتُركَّب فوق الطبقة الأساسية في الخطوة التالية عبر overlay= مع
        // توقيت enable='between(t,start,end)' لضبط ظهورها زمنياً بدقة.
        layerVideoLabels.add(currentVideoLabel);
        audioLabelsToMix.add(aLabel);
      }
    }

    if (layerVideoLabels.isEmpty) {
      throw StateError('لا توجد مقاطع صالحة للتصدير');
    }

    // ---------- 3) تركيب الطبقات فوق بعضها بالترتيب (الأولى = خلفية) ----------
    String compositeLabel = layerVideoLabels.first;
    for (int i = 1; i < layerVideoLabels.length; i++) {
      final overlayLabel = layerVideoLabels[i];
      final outLabel = 'comp$i';
      final clip = _clipForLabelIndex(i);
      // enable=between(...) يجعل الـ Overlay يظهر فقط بين startTime وendTime
      // الخاصين به، رغم أن التركيب يمر على كل فريمات الفيديو النهائي.
      filterLines.add(
        '[$compositeLabel][$overlayLabel]overlay='
        'x=${_overlayExprX(clip)}:y=${_overlayExprY(clip)}:'
        "enable='between(t,${clip.startTime.toStringAsFixed(3)},${clip.endTime.toStringAsFixed(3)})'"
        '[$outLabel]',
      );
      compositeLabel = outLabel;
    }

    // ---------- 4) دمج كل مسارات الصوت معاً (Audio Mixdown) ----------
    if (audioLabelsToMix.length > 1) {
      final audioInputs = audioLabelsToMix.map((l) => '[$l]').join();
      filterLines.add(
        '$audioInputs' 'amix=inputs=${audioLabelsToMix.length}:duration=longest:dropout_transition=2[aout]',
      );
      mixedAudioLabel = 'aout';
    } else {
      mixedAudioLabel = audioLabelsToMix.first;
    }

    return FilterGraphResult(
      inputPaths: inputPaths,
      filterComplex: filterLines.join(';'),
      finalVideoLabel: compositeLabel,
      finalAudioLabel: mixedAudioLabel,
    );
  }

  /// موضع الـ Overlay مُعبَّراً عنه بصيغة تعبير FFmpeg (نص رياضي)، مبني من
  /// نفس القيم (positionX/positionY) التي حرّكها المستخدم بإصبعه في المعاينة.
  /// main_w/main_h متاحتان تلقائياً داخل تعبيرات overlay في FFmpeg.
  String _overlayExprX(Clip clip) {
    final px = clip.positionX.evaluate(clip.startTime);
    return '(main_w/2)+($px)-(overlay_w/2)';
  }

  String _overlayExprY(Clip clip) {
    final py = clip.positionY.evaluate(clip.startTime);
    return '(main_h/2)+($py)-(overlay_h/2)';
  }

  Clip _clipForLabelIndex(int i) => _flatClips()[i];

  List<Clip> _flatClips() {
    final all = <Clip>[];
    for (final layer in timeline.layers) {
      if (!layer.visible) continue;
      all.addAll(layer.clips);
    }
    return all;
  }

  /// تحويل تأثير واحد من نموذج البيانات إلى فلتر FFmpeg مكافئ.
  /// ملاحظة: هذه فلاتر FFmpeg البرمجية القياسية للتصدير النهائي (تعمل على
  /// المعالج)، وهي منفصلة تماماً عن Shaders الـ GPU المستخدمة أثناء
  /// *المعاينة الحية* داخل التطبيق (تلك سريعة لكن للعرض فقط، لا للتصدير).
  String _buildEffectFilter(EffectInstance fx, String inLabel, String outLabel) {
    switch (fx.type) {
      case EffectType.blur:
        final radius = fx.params['radius'] ?? 8.0;
        return '[$inLabel]gblur=sigma=${radius.toStringAsFixed(2)}[$outLabel]';

      case EffectType.colorCorrection:
        final brightness = fx.params['brightness'] ?? 0.0;
        final contrast = fx.params['contrast'] ?? 1.0;
        final saturation = fx.params['saturation'] ?? 1.0;
        return '[$inLabel]eq=brightness=${brightness.toStringAsFixed(2)}:'
            'contrast=${contrast.toStringAsFixed(2)}:'
            'saturation=${saturation.toStringAsFixed(2)}[$outLabel]';

      case EffectType.glow:
        // محاكاة توهج بسيطة: نسخة مموّهة تُمزَج فوق الأصل بشفافية جزئية
        final intensity = fx.params['intensity'] ?? 1.0;
        return '[$inLabel]split[${outLabel}_a][${outLabel}_b];'
            '[${outLabel}_b]gblur=sigma=12,eq=brightness=${(0.3 * intensity).toStringAsFixed(2)}[${outLabel}_glow];'
            '[${outLabel}_a][${outLabel}_glow]blend=all_mode=screen[$outLabel]';

      case EffectType.chromaKey:
        final similarity = fx.params['similarity'] ?? 0.4;
        final smoothness = fx.params['smoothness'] ?? 0.15;
        // colorkey يُنتج شفافية (alpha) حيث يتطابق اللون؛ يجب أن يكون تنسيق
        // الفيديو داعماً لقناة alpha (نضيف format=yuva420p قبله لضمان ذلك)
        return '[$inLabel]format=yuva420p,'
            'colorkey=color=0x00FF00:similarity=${similarity.toStringAsFixed(2)}:blend=${smoothness.toStringAsFixed(2)}'
            '[$outLabel]';

      case EffectType.none:
        return '[$inLabel]null[$outLabel]';
    }
  }
}

class FilterGraphResult {
  final List<String> inputPaths;
  final String filterComplex;
  final String finalVideoLabel;
  final String finalAudioLabel;

  FilterGraphResult({
    required this.inputPaths,
    required this.filterComplex,
    required this.finalVideoLabel,
    required this.finalAudioLabel,
  });
}
