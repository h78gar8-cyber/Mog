import 'package:flutter/material.dart';
import 'dart:io';
import '../theme/app_theme.dart';
import '../../core/models/media_asset.dart';
import '../../core/engine/media_import_service.dart';

/// لوحة ملفات المشروع: شريط أفقي قابل للتمرير، أول عنصر فيه زر "+" كبير
/// وواضح لفتح المعرض. كل عنصر يعكس حالته الحقيقية لحظياً (قيد التحميل،
/// جاهز، فشل) دون أي تجميد للتمرير أثناء تحديث العناصر الأخرى.
class ProjectBinWidget extends StatefulWidget {
  final void Function(MediaAsset asset) onAssetTap; // مثال: إضافته للتايم لاين
  const ProjectBinWidget({super.key, required this.onAssetTap});

  @override
  State<ProjectBinWidget> createState() => _ProjectBinWidgetState();
}

class _ProjectBinWidgetState extends State<ProjectBinWidget> {
  late final MediaImportService _importService;
  final List<MediaAsset> _assets = [];

  @override
  void initState() {
    super.initState();
    _importService = MediaImportService(
      onAssetAdded: (asset) => setState(() => _assets.add(asset)),
      onAssetUpdated: (asset) {
        // تحديث محلي فقط للعنصر المتغيّر؛ setState هنا خفيفة لأن القائمة
        // ذاتها لا تُعاد بناؤها بالكامل بفضل استخدام keys ثابتة لكل بطاقة.
        final index = _assets.indexWhere((a) => a.id == asset.id);
        if (index != -1) setState(() => _assets[index] = asset);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 110,
      color: AppColors.surface,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        itemCount: _assets.length + 1,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          if (index == 0) return _buildImportButton();
          return _AssetCard(
            key: ValueKey(_assets[index - 1].id),
            asset: _assets[index - 1],
            onTap: () => widget.onAssetTap(_assets[index - 1]),
          );
        },
      ),
    );
  }

  Widget _buildImportButton() {
    return GestureDetector(
      onTap: () => _importService.pickAndImportMedia(),
      child: Container(
        width: 78,
        decoration: BoxDecoration(
          color: AppColors.surfaceElevated,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.accent.withValues(alpha: 0.5), width: 1.5),
        ),
        child: const Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.add_rounded, color: AppColors.accent, size: 30),
            SizedBox(height: 4),
            Text('استيراد', style: TextStyle(color: AppColors.accent, fontSize: 11)),
          ],
        ),
      ),
    );
  }
}

class _AssetCard extends StatelessWidget {
  final MediaAsset asset;
  final VoidCallback onTap;
  const _AssetCard({super.key, required this.asset, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: asset.status == MediaProcessingStatus.ready ? onTap : null,
      child: Container(
        width: 78,
        decoration: BoxDecoration(
          color: Colors.black,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.divider),
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          fit: StackFit.expand,
          children: [
            _buildThumbnailOrPlaceholder(),
            if (asset.type == MediaAssetType.video && asset.status == MediaProcessingStatus.ready)
              Positioned(
                bottom: 4,
                right: 4,
                child: Text(
                  _formatDuration(asset.durationSeconds),
                  style: const TextStyle(color: Colors.white, fontSize: 9, shadows: [
                    Shadow(blurRadius: 2, color: Colors.black),
                  ]),
                ),
              ),
            if (asset.status == MediaProcessingStatus.processing)
              const Center(
                child: SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.accent),
                ),
              ),
            if (asset.status == MediaProcessingStatus.failed)
              const Center(child: Icon(Icons.error_outline_rounded, color: Colors.redAccent, size: 22)),
          ],
        ),
      ),
    );
  }

  Widget _buildThumbnailOrPlaceholder() {
    // طالما الصورة المصغّرة غير جاهزة بعد، نعرض خلفية رمادية بسيطة بدل
    // ترك مساحة فارغة، لإحساس فوري بأن "شيئاً ما يحدث" دون انتظار المعالجة.
    if (asset.thumbnailPath == null) {
      return Container(color: AppColors.surfaceElevated);
    }
    return Image.file(
      File(asset.thumbnailPath!),
      fit: BoxFit.cover,
      errorBuilder: (_, __, ___) => Container(color: AppColors.surfaceElevated),
    );
  }

  String _formatDuration(double seconds) {
    final d = Duration(seconds: seconds.round());
    final m = d.inMinutes.remainder(60).toString().padLeft(1, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}
