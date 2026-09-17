import 'dart:collection';
import 'dart:typed_data';
import 'dart:ui' as ui;

/// عنصر مخزَّن في الكاش: صورة الفريم الجاهزة + حجمها بالبايت لإدارة الميزانية.
class CacheEntry {
  final ui.Image image;
  final int sizeBytes;
  final bool isProxy;
  CacheEntry({required this.image, required this.sizeBytes, this.isProxy = false});
}

/// كاش LRU مبني على حد أقصى بالميجابايت (وليس عدد عناصر)، لأن حجم فريم
/// 1080x1920 يختلف جذرياً عن حجم فريم Proxy 270x480.
///
/// الأهمية على الجوال تحديدًا: كل فريم مُعاد رندرته = استهلاك GPU/CPU إضافي
/// = حرارة أعلى + استنزاف بطارية أسرع. تفادي إعادة الرندرة غير الضرورية
/// هو أهم عامل وحيد لإبقاء الجهاز بارداً وسلساً أثناء تصفح التايم لاين.
class FrameCacheManager {
  final int maxBytes;
  int _currentBytes = 0;
  final LinkedHashMap<String, CacheEntry> _store = LinkedHashMap();

  FrameCacheManager({int maxMemoryMB = 256}) : maxBytes = maxMemoryMB * 1024 * 1024;

  static String buildKey(int frameNumber, String compositionSignature) {
    // hash خفيف وسريع (لا نحتاج تشفير Cryptographic هنا، فقط تمييز سريع)
    return '$frameNumber:${compositionSignature.hashCode}';
  }

  CacheEntry? get(String key) {
    final entry = _store.remove(key);
    if (entry != null) {
      _store[key] = entry; // إعادة الإدراج في النهاية = "الأحدث استخدامًا"
    }
    return entry;
  }

  void put(String key, ui.Image image, {bool isProxy = false}) {
    final approxSize = (image.width * image.height * 4); // RGBA تقريبي
    _evictUntilFits(approxSize);
    _store[key] = CacheEntry(image: image, sizeBytes: approxSize, isProxy: isProxy);
    _currentBytes += approxSize;
  }

  void _evictUntilFits(int incoming) {
    while (_currentBytes + incoming > maxBytes && _store.isNotEmpty) {
      final oldestKey = _store.keys.first;
      final removed = _store.remove(oldestKey);
      if (removed != null) {
        removed.image.dispose(); // تحرير فوري لذاكرة GPU الخاصة بالصورة
        _currentBytes -= removed.sizeBytes;
      }
    }
  }

  void invalidateFrame(int frameNumber) {
    final keysToRemove = _store.keys.where((k) => k.startsWith('$frameNumber:')).toList();
    for (final k in keysToRemove) {
      _store.remove(k)?.image.dispose();
    }
  }

  void clear() {
    for (final entry in _store.values) {
      entry.image.dispose();
    }
    _store.clear();
    _currentBytes = 0;
  }

  double get usageRatio => maxBytes == 0 ? 0 : _currentBytes / maxBytes;
}
