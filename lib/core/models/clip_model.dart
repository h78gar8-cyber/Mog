import 'keyframe_model.dart';
import 'media_asset.dart';

enum EffectType { blur, colorCorrection, glow, chromaKey, none }

class EffectInstance {
  final EffectType type;
  bool enabled;
  final Map<String, double> params; // مثال: {'radius': 8.0} للـ blur

  EffectInstance({required this.type, this.enabled = true, Map<String, double>? params})
      : params = params ?? {};
}

class Clip {
  final String id;
  final MediaAsset asset; // الملف المصدر الكامل (يحمل originalPath وproxyPath وwaveformPeaks)
  double startTime; // موقعه على التايم لاين (ثواني)
  double duration;
  double inPoint;

  final AnimatedProperty positionX;
  final AnimatedProperty positionY;
  final AnimatedProperty scale;
  final AnimatedProperty rotation;
  final AnimatedProperty opacity;
  final List<EffectInstance> effects;

  Clip({
    required this.id,
    required this.asset,
    required this.startTime,
    required this.duration,
    this.inPoint = 0.0,
    List<EffectInstance>? effects,
  })  : positionX = AnimatedProperty(name: 'x', defaultValue: 0.0),
        positionY = AnimatedProperty(name: 'y', defaultValue: 0.0),
        scale = AnimatedProperty(name: 'scale', defaultValue: 100.0),
        rotation = AnimatedProperty(name: 'rotation', defaultValue: 0.0),
        opacity = AnimatedProperty(name: 'opacity', defaultValue: 100.0),
        effects = effects ?? [];

  double get endTime => startTime + duration;

  /// المسار الذي يُستخدم فعلياً أثناء الرندرة الحية على التايم لاين (Proxy
  /// إن وُجد). التصدير النهائي وحده يعتمد على asset.originalPath مباشرة.
  String get editingSourcePath => asset.editingPath;

  /// بصمة الحالة الحالية — تُستخدم لبناء مفتاح الكاش (انظر frame_cache_manager)
  String stateSignature(double t) {
    final buf = StringBuffer();
    buf.write(id);
    buf.write('|x=${positionX.evaluate(t).toStringAsFixed(2)}');
    buf.write('|y=${positionY.evaluate(t).toStringAsFixed(2)}');
    buf.write('|s=${scale.evaluate(t).toStringAsFixed(2)}');
    buf.write('|r=${rotation.evaluate(t).toStringAsFixed(2)}');
    buf.write('|o=${opacity.evaluate(t).toStringAsFixed(2)}');
    for (final fx in effects) {
      buf.write('|fx=${fx.type.name}:${fx.enabled}:${fx.params}');
    }
    return buf.toString();
  }
}

class EditorLayer {
  final String id;
  String name;
  bool visible;
  bool locked;
  final List<Clip> clips;

  EditorLayer({
    required this.id,
    required this.name,
    this.visible = true,
    this.locked = false,
    List<Clip>? clips,
  }) : clips = clips ?? [];
}

class TimelineModel {
  final List<EditorLayer> layers = [];
  double fps = 30.0;
  double duration = 10.0;
  double resolutionWidth = 1080;
  double resolutionHeight = 1920; // Portrait افتراضياً لمحتوى الموبايل (Reels/TikTok)

  /// اصطلاح الترتيب: الطبقة ذات الفهرس الأكبر (نهاية القائمة) هي "الأعلى"
  /// بصرياً (Overlay/PiP)، أما الفهرس صفر فهي الخلفية. نفس منطق طبقات AE.
  List<MapEntry<EditorLayer, Clip>> clipsAtTime(double t) {
    final result = <MapEntry<EditorLayer, Clip>>[];
    for (final layer in layers) {
      if (!layer.visible) continue;
      for (final clip in layer.clips) {
        if (clip.startTime <= t && t <= clip.endTime) {
          result.add(MapEntry(layer, clip));
        }
      }
    }
    return result;
  }

  /// كل المقاطع الظاهرة في لحظة t **باستثناء طبقة الخلفية (index 0)** —
  /// أي فقط طبقات الـ Overlay القابلة للتحريك والتكبير فوق شاشة المعاينة.
  List<Clip> overlayClipsAtTime(double t) {
    final entries = clipsAtTime(t);
    return entries.where((e) => layers.indexOf(e.key) > 0).map((e) => e.value).toList();
  }

  EditorLayer addLayer({String? name}) {
    final layer = EditorLayer(
      id: 'layer_${DateTime.now().microsecondsSinceEpoch}',
      name: name ?? 'Layer ${layers.length + 1}',
    );
    layers.add(layer);
    return layer;
  }
}
