/// نظام Keyframes + Easing، مطابق منطقياً لنسخة سطح المكتب، لكن مُحسَّن
/// لِـ Dart بحيث يعمل بأمان داخل Isolate منفصل (لا يعتمد على أي حالة عامة).
library keyframe_model;

enum InterpolationType { linear, bezier, hold }

class BezierHandle {
  final double influenceX;
  final double influenceY;
  const BezierHandle({this.influenceX = 0.33, this.influenceY = 0.0});
}

class Keyframe {
  final double time; // بالثواني
  final double value;
  final InterpolationType interpolation;
  final BezierHandle outHandle;
  final BezierHandle inHandle;

  const Keyframe({
    required this.time,
    required this.value,
    this.interpolation = InterpolationType.bezier,
    this.outHandle = const BezierHandle(influenceX: 0.33, influenceY: 0.0),
    this.inHandle = const BezierHandle(influenceX: 0.33, influenceY: 1.0),
  });
}

/// خاصية متحركة (opacity, scale, x, y...) مع تقييم سريع O(log n)
class AnimatedProperty {
  final String name;
  double defaultValue; // غير final عمداً: التلاعب المباشر باللمس (سحب/تكبير Overlay) يُحدّثها فوراً
  final List<Keyframe> keyframes;

  AnimatedProperty({required this.name, this.defaultValue = 0.0})
      : keyframes = [];

  /// تحديث "القيمة الحالية" نتيجة لمس مباشر من المستخدم (Drag/Pinch).
  /// إن لم تكن هناك كيفريمات بعد، نُحرّك القيمة الافتراضية للطبقة كلها ببساطة
  /// (وهذا يكفي تماماً لتموضع Overlay ثابت طوال مدة ظهوره). إن كانت هناك
  /// كيفريمات فعلاً، نُدرج/نُحدّث كيفريم عند نفس اللحظة الزمنية بدل كسر الحركة
  /// المبرمجة مسبقاً في باقي المقطع.
  void setLiveValue(double t, double value) {
    if (keyframes.isEmpty) {
      defaultValue = value;
      return;
    }
    final existingIndex = keyframes.indexWhere((k) => (k.time - t).abs() < 1e-3);
    if (existingIndex != -1) {
      keyframes[existingIndex] = Keyframe(
        time: t,
        value: value,
        interpolation: keyframes[existingIndex].interpolation,
      );
    } else {
      addKeyframe(Keyframe(time: t, value: value));
    }
  }

  void addKeyframe(Keyframe kf) {
    // إدراج مرتب زمنياً (بحث ثنائي بسيط لتفادي sort كامل مع كل إضافة)
    int lo = 0, hi = keyframes.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (keyframes[mid].time <= kf.time) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    keyframes.insert(lo, kf);
  }

  double evaluate(double t) {
    if (keyframes.isEmpty) return defaultValue;
    if (t <= keyframes.first.time) return keyframes.first.value;
    if (t >= keyframes.last.time) return keyframes.last.value;

    int idx = 0;
    for (int i = 0; i < keyframes.length - 1; i++) {
      if (keyframes[i].time <= t && t <= keyframes[i + 1].time) {
        idx = i;
        break;
      }
    }
    final k0 = keyframes[idx];
    final k1 = keyframes[idx + 1];

    if (k0.interpolation == InterpolationType.hold) return k0.value;

    final duration = k1.time - k0.time;
    final localT = duration > 0 ? (t - k0.time) / duration : 0.0;

    if (k0.interpolation == InterpolationType.linear) {
      return k0.value + (k1.value - k0.value) * localT;
    }

    final eased = _cubicBezierEase(
      localT,
      k0.outHandle.influenceX,
      k0.outHandle.influenceY,
      k1.inHandle.influenceX,
      k1.inHandle.influenceY,
    );
    return k0.value + (k1.value - k0.value) * eased;
  }

  double _cubicBezierEase(double t, double x1, double y1, double x2, double y2,
      {int iterations = 8}) {
    double bezier(double tt, double a, double b) =>
        (3 * (1 - tt) * (1 - tt) * tt * a) +
        (3 * (1 - tt) * tt * tt * b) +
        (tt * tt * tt);

    double guess = t;
    for (int i = 0; i < iterations; i++) {
      final x = bezier(guess, x1, x2);
      final dx = x - t;
      if (dx.abs() < 1e-4) break;
      final slope = 3 * (1 - guess) * (1 - guess) * x1 +
          6 * (1 - guess) * guess * (x2 - x1) +
          3 * guess * guess * (1 - x2);
      final safeSlope = slope.abs() > 1e-6 ? slope : 1e-6;
      guess -= dx / safeSlope;
      guess = guess.clamp(0.0, 1.0);
    }
    return bezier(guess, y1, y2);
  }
}
