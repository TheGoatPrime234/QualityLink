import 'package:flutter/material.dart';
import 'theme_constants.dart';

class GlobalTopbar extends StatelessWidget {
  final String title;
  final Color statusColor;
  final String subtitle1;
  final String subtitle2;
  
  // Wenn diese Liste gefüllt wird, wird der Titel anklickbar (Dropdown)
  final List<PopupMenuEntry<String>>? menuItems;
  final Function(String)? onMenuItemSelected;
  
  // Optionaler Klick auf das Zahnrad
  final VoidCallback? onSettingsTap;

  const GlobalTopbar({
    super.key,
    required this.title,
    required this.statusColor,
    required this.subtitle1,
    required this.subtitle2,
    this.menuItems,
    this.onMenuItemSelected,
    this.onSettingsTap,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      color: AppColors.surface, // Bleibt dunkel
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start, // Damit Titel oben ist
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // TITEL + STATUS DOT + OPTIONALES DROPDOWN
                Row(
                  children: [
                    if (menuItems != null && menuItems!.isNotEmpty)
                      Theme(
                        data: Theme.of(context).copyWith(
                          splashColor: Colors.transparent,
                          highlightColor: Colors.transparent,
                        ),
                        child: PopupMenuButton<String>(
                          color: AppColors.card,
                          offset: const Offset(0, 30), // Leicht nach unten versetzt
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                            side: BorderSide(color: AppColors.primary.withValues(alpha: 0.3)),
                          ),
                          onSelected: onMenuItemSelected,
                          itemBuilder: (BuildContext context) => menuItems!,
                          child: Row(
                            children: [
                              Text(title, style: const TextStyle(color: AppColors.primary, fontSize: 18, fontWeight: FontWeight.bold)),
                              const SizedBox(width: 4),
                              const Icon(Icons.arrow_drop_down, color: AppColors.primary, size: 20),
                            ],
                          ),
                        ),
                      )
                    else
                      Text(title, style: const TextStyle(color: AppColors.primary, fontSize: 18, fontWeight: FontWeight.bold)),
                    
                    const SizedBox(width: 12),
                    
                    // STATUS DOT
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: statusColor,
                        shape: BoxShape.circle,
                        boxShadow: statusColor == AppColors.primary 
                            ? [BoxShadow(color: AppColors.primary.withValues(alpha: 0.5), blurRadius: 8, spreadRadius: 2)] 
                            : null,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                // SUBTITLES
                Text(subtitle1, style: const TextStyle(color: AppColors.textDim, fontSize: 10)),
                Text(subtitle2, style: const TextStyle(color: AppColors.textDim, fontSize: 10)),
              ],
            ),
          ),
          
          // SETTINGS ICON (Immer rechts)
          InkWell(
            onTap: onSettingsTap,
            borderRadius: BorderRadius.circular(8),
            child: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.5),
                border: Border.all(color: AppColors.accent.withValues(alpha: 0.5)),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(Icons.settings, color: AppColors.accent, size: 20),
            ),
          ),
        ],
      ),
    );
  }
}