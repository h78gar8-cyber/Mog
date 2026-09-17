import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'frame_cache_manager.dart';

/// ==========================================================================
/// لماذا Isolate وليس مجرد async/await؟
/// ==========================================================================
/// async/await في Dart لا يعني تعدد المعالجة الحقيقي؛ كل الكود ما زال يعمل
/// على نفس الـ Isolate (نفس الـ Thread) وأي عملية ثقيلة (فك تشفير فيديو،
/// تطبيق فلتر على مصفوفة بكسلات ضخمة) ستُجمّد رسم الواجهة رغم استخدام await.
///
/// الحل: Isolate.spawn ينشئ Thread حقيقي منفصل بذاكرته الخاصة بالكامل،
/// فلا يمكن لأي عملية رندرة ثقيلة أن "تسرق" وقت المعالج من UI Isolate
/// المسؤول عن اللمس والانتقالات الحركية.
/// ==========================================================================

class _RenderRequest {
  final int frameNumber;
  final double time;
  final int width;
  final int height;
  final bool isProxy;
  final List<Map<String, dynamic>> clipsState;
  final SendPort replyPort;

  _RenderRequest({
    required this.frameNumber,
    required this.time,
    required this.width,
    required this.height,
    required this.isProxy,
    required this.clipsState,
    required this.replyPort,
  });
}

class _RenderResult {
  final int frameNumber;
  final bool isProxy;
  final int width;
  final int height;
  final TransferableTypedData pixels; // نقل الذاكرة بدون نسخ (Zero-copy)

  _RenderResult({
    required this.frameNumber,
    required this.isProxy,
    required this.width,
    required this.height,
    required this.pixels,
  });
}

/// نقطة الدخول التي تعمل بالكامل داخل الـ Isolate المعزول.
void _renderIsolateEntryPoint(SendPort mainSendPort) {
  final commandPort = ReceivePort();
  mainSendPort.send(commandPort.sendPort);

  commandPort.listen((message) {
    if (message is _RenderRequest) {
      final pixels = _compositeFrame(message);
      final result = _RenderResult(
        frameNumber: message.frameNumber,
        isProxy: message.isProxy,
        width: message.width,
        height: message.height,
        pixels: TransferableTypedData.fromList([pixels]),
      );
      message.replyPort.send(result);
    }
  });
}

/// تركيب الفريم الفعلي: في التطبيق الكامل هذه الدالة تستدعي FFmpeg (عبر
/// ffmpeg_kit_flutter) لفك تشفير الفريم من الفيديو المصدر عند الزمن t،
/// ثم تطبّق Shaders الفلاتر (Blur/Glow/Color) على البكسلات، ثم تركّب كل
/// الطبقات فوق بعضها حسب opacity/position/scale المُقيَّمة من الـ Keyframes.
Uint8List _compositeFrame(_RenderRequest req) {
  final buffer = Uint8List(req.width * req.height * 4);
  // Placeholder: تعبئة تدرج بسيط لتوضيح تدفق العمل فقط (بدون فك تشفير فعلي هنا)
  for (final clipState in req.clipsState) {
    final opacity = (clipState['opacity'] as num?)?.toDouble() ?? 100.0;
    final alpha = (opacity / 100.0 * 255).clamp(0, 255).toInt();
    for (int i = 3; i < buffer.length; i += 4) {
      buffer[i] = alpha;
    }
  }
  return buffer;
}

/// الواجهة العامة (Facade) التي تستخدمها شاشات الـ UI للتعامل مع المحرك،
/// وتُخفي كل تعقيد إدارة الـ Isolate والتواصل معه.
class AsyncRenderEngine {
  final FrameCacheManager cache;
  final double fps;

  Isolate? _isolate;
  SendPort? _isolateSendPort;
  final _readyCompleter = Completer<void>();

  final _frameStreamController = StreamController<_DecodedFrame>.broadcast();
  Stream<_DecodedFrame> get frameStream => _frameStreamController.stream;

  bool _liveScrubbing = false;
  static const int _proxyThresholdPixels = 1080 * 1920;

  AsyncRenderEngine({required this.fps, int cacheMemoryMB = 256})
      : cache = FrameCacheManager(maxMemoryMB: cacheMemoryMB) {
    _spawnIsolate();
  }

  Future<void> get ready => _readyCompleter.future;

  Future<void> _spawnIsolate() async {
    final mainReceivePort = ReceivePort();
    _isolate = await Isolate.spawn(_renderIsolateEntryPoint, mainReceivePort.sendPort);

    mainReceivePort.listen((message) {
      if (message is SendPort) {
        _isolateSendPort = message;
        if (!_readyCompleter.isCompleted) _readyCompleter.complete();
      } else if (message is _RenderResult) {
        _handleRenderResult(message);
      }
    });
  }

  void setLiveScrubbing(bool active) => _liveScrubbing = active;

  /// طلب فريم لزمن معيّن. غير محظور (Non-blocking) بالكامل:
  /// يُعاد فوراً من الكاش إن وُجد، وإلا يُرسَل الطلب للـ Isolate وتصل
  /// النتيجة لاحقاً عبر frameStream دون تجميد أي إطار حركي في الواجهة.
  Future<void> requestFrame(double time, TimelineSnapshot snapshot) async {
    await ready;
    final frameNumber = (time * fps).round();
    final signature = snapshot.clipsState.map((c) => c.toString()).join('|');
    final key = FrameCacheManager.buildKey(frameNumber, signature);

    final cached = cache.get(key);
    if (cached != null) {
      _frameStreamController.add(_DecodedFrame(frameNumber, cached.image, cached.isProxy));
      return;
    }

    final useProxy = _liveScrubbing &&
        (snapshot.width * snapshot.height) > _proxyThresholdPixels;
    final w = useProxy ? (snapshot.width * 0.35).round() : snapshot.width;
    final h = useProxy ? (snapshot.height * 0.35).round() : snapshot.height;

    final responsePort = ReceivePort();
    _isolateSendPort!.send(_RenderRequest(
      frameNumber: frameNumber,
      time: time,
      width: w,
      height: h,
      isProxy: useProxy,
      clipsState: snapshot.clipsState,
      replyPort: responsePort.sendPort,
    ));

    final result = await responsePort.first as _RenderResult;
    responsePort.close();

    final bytes = result.pixels.materialize().asUint8List();
    final image = await _decodeToImage(bytes, result.width, result.height);

    cache.put(key, image, isProxy: result.isProxy);
    _frameStreamController.add(_DecodedFrame(result.frameNumber, image, result.isProxy));
  }

  Future<ui.Image> _decodeToImage(Uint8List bytes, int width, int height) {
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(bytes, width, height, ui.PixelFormat.rgba8888, (img) {
      completer.complete(img);
    });
    return completer.future;
  }

  void _handleRenderResult(_RenderResult result) {
    // تُستخدم فقط في حال وصلت نتائج غير مرتبطة بطلب Future مباشر (بث حي مستقبلي)
  }

  void dispose() {
    cache.clear();
    _isolate?.kill(priority: Isolate.immediate);
    _frameStreamController.close();
  }
}

class _DecodedFrame {
  final int frameNumber;
  final ui.Image image;
  final bool isProxy;
  _DecodedFrame(this.frameNumber, this.image, this.isProxy);
}

/// لقطة مبسّطة وقابلة للإرسال عبر الـ Isolate (بيانات خام فقط، بلا كائنات معقّدة)
class TimelineSnapshot {
  final int width;
  final int height;
  final List<Map<String, dynamic>> clipsState;
  TimelineSnapshot({required this.width, required this.height, required this.clipsState});
}
