import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../../core/export/export_engine.dart';

/// لوحة سفلية غير قابلة للإغلاق بالسحب أثناء التصدير الفعلي (لتفادي إلغاء
/// غير مقصود)، تعرض شريط تقدم حقيقي + الوقت المتبقي التقريبي + زر إلغاء صريح.
class ExportProgressSheet extends StatelessWidget {
  final Stream<ExportProgress> progressStream;
  final VoidCallback onCancel;
  final VoidCallback onDone;

  const ExportProgressSheet({
    super.key,
    required this.progressStream,
    required this.onCancel,
    required this.onDone,
  });

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<ExportProgress>(
      stream: progressStream,
      builder: (context, snapshot) {
        final progress = snapshot.data ?? const ExportProgress(status: ExportStatus.preparing);

        return Container(
          padding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
          decoration: const BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildIcon(progress.status),
              const SizedBox(height: 16),
              Text(_titleFor(progress.status), style: const TextStyle(color: AppColors.textPrimary, fontSize: 16, fontWeight: FontWeight.bold)),
              const SizedBox(height: 20),

              if (progress.status == ExportStatus.preparing || progress.status == ExportStatus.running) ...[
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: LinearProgressIndicator(
                    value: progress.status == ExportStatus.preparing ? null : progress.fraction,
                    minHeight: 10,
                    backgroundColor: AppColors.surfaceElevated,
                    valueColor: const AlwaysStoppedAnimation(AppColors.accent),
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('${(progress.fraction * 100).toStringAsFixed(0)}%',
                        style: const TextStyle(color: AppColors.textPrimary, fontSize: 13)),
                    if (progress.estimatedRemaining != null)
                      Text(
                        'متبقٍ تقريباً: ${_formatDuration(progress.estimatedRemaining!)}',
                        style: const TextStyle(color: AppColors.textSecondary, fontSize: 12),
                      ),
                  ],
                ),
                const SizedBox(height: 20),
                OutlinedButton(
                  onPressed: onCancel,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.redAccent,
                    side: const BorderSide(color: Colors.redAccent),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: const Text('إلغاء التصدير'),
                ),
              ],

              if (progress.status == ExportStatus.completed) ...[
                const Text('تم حفظ الفيديو في معرض الصور', style: TextStyle(color: AppColors.textSecondary, fontSize: 13)),
                const SizedBox(height: 20),
                ElevatedButton(onPressed: onDone, child: const Text('تم')),
              ],

              if (progress.status == ExportStatus.failed) ...[
                Text(progress.errorMessage ?? 'حدث خطأ غير متوقع',
                    style: const TextStyle(color: Colors.redAccent, fontSize: 12), textAlign: TextAlign.center),
                const SizedBox(height: 20),
                ElevatedButton(onPressed: onDone, child: const Text('إغلاق')),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _buildIcon(ExportStatus status) {
    switch (status) {
      case ExportStatus.completed:
        return const Icon(Icons.check_circle_rounded, color: Colors.greenAccent, size: 42);
      case ExportStatus.failed:
        return const Icon(Icons.error_rounded, color: Colors.redAccent, size: 42);
      default:
        return const Icon(Icons.movie_filter_rounded, color: AppColors.accent, size: 42);
    }
  }

  String _titleFor(ExportStatus status) {
    switch (status) {
      case ExportStatus.preparing:
        return 'جاري تجهيز التصدير...';
      case ExportStatus.running:
        return 'جاري تصدير الفيديو...';
      case ExportStatus.completed:
        return 'اكتمل التصدير بنجاح 🎉';
      case ExportStatus.failed:
        return 'فشل التصدير';
      case ExportStatus.canceled:
        return 'تم إلغاء التصدير';
      case ExportStatus.idle:
        return '';
    }
  }

  String _formatDuration(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds.remainder(60);
    return m > 0 ? '$m:${s.toString().padLeft(2, '0')} دقيقة' : '$s ثانية';
  }
}
