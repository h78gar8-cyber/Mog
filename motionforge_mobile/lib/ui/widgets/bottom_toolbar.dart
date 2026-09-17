import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

class ToolbarItem {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const ToolbarItem({required this.icon, required this.label, required this.onTap});
}

/// شريط أدوات سفلي أفقي قابل للتمرير، بعناصر كبيرة بما يكفي لضغطة إبهام
/// مريحة بيد واحدة أثناء حمل الهاتف (منطقة لمس لا تقل عن 48dp).
class BottomToolbar extends StatelessWidget {
  final List<ToolbarItem> items;
  const BottomToolbar({super.key, required this.items});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 84,
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(top: BorderSide(color: AppColors.divider, width: 1)),
      ),
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        scrollDirection: Axis.horizontal,
        itemCount: items.length,
        separatorBuilder: (_, __) => const SizedBox(width: 6),
        itemBuilder: (context, index) {
          final item = items[index];
          return _ToolbarButton(item: item);
        },
      ),
    );
  }
}

class _ToolbarButton extends StatelessWidget {
  final ToolbarItem item;
  const _ToolbarButton({required this.item});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: item.onTap,
        child: Container(
          width: 68,
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: AppColors.surfaceElevated,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(item.icon, size: 22, color: AppColors.textPrimary),
              ),
              const SizedBox(height: 4),
              Text(
                item.label,
                style: const TextStyle(fontSize: 10, color: AppColors.textSecondary),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// عناصر الشريط الافتراضية المطلوبة: الفلاتر، النصوص، التقسيم، المؤثرات، الكروما
List<ToolbarItem> buildDefaultToolbarItems({
  required VoidCallback onFilters,
  required VoidCallback onText,
  required VoidCallback onSplit,
  required VoidCallback onEffects,
  required VoidCallback onAudio,
  required VoidCallback onChromaKey,
}) {
  return [
    ToolbarItem(icon: Icons.content_cut_rounded, label: 'تقسيم', onTap: onSplit),
    ToolbarItem(icon: Icons.auto_awesome_rounded, label: 'مؤثرات', onTap: onEffects),
    ToolbarItem(icon: Icons.filter_vintage_rounded, label: 'فلاتر', onTap: onFilters),
    ToolbarItem(icon: Icons.layers_rounded, label: 'كروما', onTap: onChromaKey),
    ToolbarItem(icon: Icons.title_rounded, label: 'نص', onTap: onText),
    ToolbarItem(icon: Icons.music_note_rounded, label: 'صوت', onTap: onAudio),
  ];
}
