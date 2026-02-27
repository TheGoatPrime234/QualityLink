import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:google_fonts/google_fonts.dart';

import '../controllers/file_vault_controller.dart'; // 🔥 Importiert unsere neue Logik-Datei
import 'file_viewer_screen.dart';
import '../ui/theme_constants.dart';
import '../ui/tech_card.dart';
import '../ui/parallelogram_button.dart';
import '../ui/global_topbar.dart';
import '../widgets/video_thumbnail_widget.dart';

// =============================================================================
// FRONTEND: FILE VAULT UI
// =============================================================================

class NetworkStorageScreen extends StatelessWidget {
  final String myClientId;
  final String myDeviceName;
  
  const NetworkStorageScreen({
    super.key, 
    required this.myClientId, 
    required this.myDeviceName
  });

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) {
        final controller = FileVaultController();
        controller.init(myClientId, myDeviceName); 
        return controller;
      },
      child: const _FileVaultView(),
    );
  }
}

class _FileVaultView extends StatelessWidget {
  const _FileVaultView();

  @override
  Widget build(BuildContext context) {
    final controller = Provider.of<FileVaultController>(context);
    
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        final shouldClose = controller.handleBackPress();
        if (shouldClose && context.mounted) {
           Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        backgroundColor: Colors.transparent, 
        body: SafeArea( 
          child: Stack(
            children: [
              Column(
                children: [
                  _buildHeader(context, controller),
                  
                  if (controller.isLoading)
                    const LinearProgressIndicator(
                      backgroundColor: AppColors.background,
                      color: AppColors.primary,
                      minHeight: 2,
                    ),

                  if (controller.errorMessage != null)
                     Container(
                       padding: const EdgeInsets.all(8),
                       color: AppColors.warning.withValues(alpha: 0.2), 
                       width: double.infinity,
                       child: Text(
                         controller.errorMessage!, 
                         style: const TextStyle(color: AppColors.warning),
                         textAlign: TextAlign.center,
                       ),
                     ),

                  Expanded(
                    child: controller.displayFiles.isEmpty && !controller.isLoading && controller.errorMessage == null
                      ? Center(
                          child: Text(
                            controller.searchQuery.isEmpty ? "NO DATA STREAM" : "NO MATCH FOUND", 
                            style: const TextStyle(color: AppColors.textDim, letterSpacing: 2)
                          )
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.only(top: 8, bottom: 100),
                          itemCount: controller.displayFiles.length,
                          itemBuilder: (context, index) {
                            return _buildFileItem(context, controller, controller.displayFiles[index]);
                          },
                        ),
                  ),
                ],
              ),
              
              AnimatedPositioned(
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeOutExpo,
                bottom: (controller.isSelectionMode || controller.canPaste) ? 20 : -100,
                left: 20,
                right: 20,
                child: _buildActionBar(context, controller),
              ),
            ],
          ),
        ),
      ),
    );
  }

Widget _buildHeader(BuildContext context, FileVaultController controller) {
    if (controller.isSearching) {
      return _buildSearchBar(context, controller);
    }

    List<Widget> breadcrumbs = [];
    breadcrumbs.add(
      Padding(
        padding: const EdgeInsets.only(right: 4),
        child: ParallelogramButton(
          text: "NET",
          icon: Icons.hub,
          skew: 0.2,
          color: controller.currentPath == "ROOT" ? AppColors.primary : Colors.grey,
          onTap: () => controller.loadRoot(),
        ),
      )
    );
    if (controller.currentPath != "ROOT") {
       breadcrumbs.add(
        Padding(
          padding: const EdgeInsets.only(right: 4),
          child: ParallelogramButton(
            text: "BACK", 
            skew: 0.2,
            color: AppColors.accent,
            onTap: () => controller.navigateUp(),
          ),
        )
      );
    }

    return Container(
      padding: const EdgeInsets.only(bottom: 10),
      color: AppColors.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GlobalTopbar(
            title: "FILEVAULT",
            statusColor: controller.errorMessage == null ? AppColors.primary : AppColors.warning,
            subtitle1: "NETWORK STORAGE",
            subtitle2: "TAP GEAR FOR ECO MODE",
            onSettingsTap: () {
              showModalBottomSheet(
                context: context,
                backgroundColor: AppColors.card,
                shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
                builder: (ctx) => Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text("VAULT SETTINGS", style: TextStyle(color: AppColors.primary, fontWeight: FontWeight.bold, fontSize: 16)),
                      const SizedBox(height: 20),
                      SwitchListTile(
                        title: const Text("Load Image Thumbnails", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                        subtitle: const Text("Turn off to save mobile data & battery", style: TextStyle(color: AppColors.textDim, fontSize: 12)),
                        activeColor: AppColors.primary,
                        value: controller.showThumbnails,
                        onChanged: (val) {
                          controller.toggleThumbnails();
                          Navigator.pop(ctx);
                        },
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(children: breadcrumbs),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.create_new_folder, color: AppColors.accent),
                      onPressed: () => _showCreateFolderDialog(context, controller),
                      tooltip: "NEW FOLDER",
                    ),
                    IconButton(
                      icon: const Icon(Icons.upload_file, color: AppColors.primary),
                      onPressed: () => controller.uploadFile(),
                      tooltip: "UPLOAD HERE",
                    ),
                    IconButton(
                      icon: const Icon(Icons.sort, color: AppColors.accent),
                      onPressed: () => _showSortMenu(context, controller),
                    ),
                    IconButton(
                      icon: const Icon(Icons.search, color: AppColors.primary),
                      onPressed: () => controller.toggleSearch(),
                    ),
                    const SizedBox(width: 60),
                  ],
                ),
                
                const SizedBox(height: 10),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      "${controller.files.length} NODES • ${controller.currentPath}",
                      style: const TextStyle(color: AppColors.textDim, fontSize: 10, letterSpacing: 1.5),
                    ),
                    if (controller.isSelectionMode)
                      Text(
                        "${controller.selectedNodes.length} SELECTED",
                        style: const TextStyle(color: AppColors.primary, fontSize: 10, fontWeight: FontWeight.bold),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchBar(BuildContext context, FileVaultController controller) {
    final filters = [
      {'type': VfsNodeType.image, 'label': 'IMG', 'icon': Icons.image},
      {'type': VfsNodeType.video, 'label': 'MOV', 'icon': Icons.movie},
      {'type': VfsNodeType.audio, 'label': 'AUD', 'icon': Icons.graphic_eq},
      {'type': VfsNodeType.document, 'label': 'DOC', 'icon': Icons.description},
      {'type': VfsNodeType.code, 'label': 'DEV', 'icon': Icons.code},
      {'type': VfsNodeType.archive, 'label': 'ZIP', 'icon': Icons.inventory_2},
    ];

    return Container(
      padding: const EdgeInsets.only(top: 10, bottom: 10, left: 16, right: 16),
      color: AppColors.card.withValues(alpha: 0.9),
      child: Column(
        children: [
          TechCard(
            borderColor: controller.isDeepSearchActive ? AppColors.warning : AppColors.primary,
            child: Row(
              children: [
                Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: Icon(
                    controller.isDeepSearchActive ? Icons.travel_explore : Icons.search, 
                    color: controller.isDeepSearchActive ? AppColors.warning : AppColors.primary
                  ),
                ),
                Expanded(
                  child: TextField(
                    autofocus: true,
                    style: GoogleFonts.rajdhani(color: Colors.white, fontSize: 18),
                    cursorColor: AppColors.primary,
                    textInputAction: TextInputAction.search,
                    decoration: InputDecoration(
                      hintText: controller.isDeepSearchActive ? "DEEP SCAN ACTIVE..." : "TYPE TO FILTER / ENTER TO SCAN",
                      hintStyle: const TextStyle(color: AppColors.textDim, fontSize: 12),
                      border: InputBorder.none,
                      isDense: true,
                    ),
                    onChanged: (value) => controller.updateSearchQuery(value),
                    onSubmitted: (value) => controller.performDeepSearch(value),
                  ),
                ),
                if (controller.isDeepSearchActive)
                   IconButton(
                    icon: const Icon(Icons.refresh, color: AppColors.warning),
                    onPressed: () => controller.performDeepSearch(controller.searchQuery),
                   ),
                
                IconButton(
                  icon: const Icon(Icons.sort, color: AppColors.accent),
                  onPressed: () => _showSortMenu(context, controller),
                ),

                IconButton(
                  icon: const Icon(Icons.close, color: AppColors.warning),
                  onPressed: () => controller.toggleSearch(),
                ),
                const SizedBox(width: 60),
              ],
            ),
          ),
          
          const SizedBox(height: 10),
          SizedBox(
            height: 32,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: filters.length,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (context, index) {
                final f = filters[index];
                final type = f['type'] as VfsNodeType;
                final isActive = controller.activeFilter == type;
                final color = isActive ? AppColors.accent : Colors.grey;

                return GestureDetector(
                  onTap: () => controller.setFilter(type),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
                    decoration: BoxDecoration(
                      color: isActive ? AppColors.accent.withValues(alpha: 0.2) : Colors.transparent,
                      border: Border.all(
                        color: isActive ? AppColors.accent : Colors.grey.withValues(alpha: 0.3)
                      ),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Row(
                      children: [
                        Icon(f['icon'] as IconData, size: 14, color: color),
                        const SizedBox(width: 6),
                        Text(
                          f['label'] as String,
                          style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),

          const SizedBox(height: 8),
          
          Align(
            alignment: Alignment.centerRight,
            child: Text(
              "${controller.displayFiles.length} NODES FOUND",
              style: TextStyle(
                color: controller.activeFilter != null ? AppColors.accent : AppColors.primary, 
                fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 1.5
              ),
            ),
          ),
        ],
      ),
    );
  }

Widget _buildFileItem(BuildContext context, FileVaultController controller, VfsNode node) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: TechCard(
        borderColor: node.isSelected 
            ? AppColors.primary 
            : node.type == VfsNodeType.folder 
                ? AppColors.accent.withValues(alpha: 0.3) 
                : Colors.white.withValues(alpha: 0.05),
        
        onTap: () {
          if (controller.isSelectionMode) {
            controller.toggleSelection(node);
          } else {
            if (node.isDirectory) {
              controller.open(node);
            } else {
              Navigator.push(
                context, 
                MaterialPageRoute(builder: (_) => FileViewerScreen(node: node))
              );
            }
          }
        },
        onLongPress: () => controller.toggleSelection(node),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: node.color.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: node.color.withValues(alpha: 0.3)),
              ),
              child: controller.showThumbnails 
                  ? (node.type == VfsNodeType.image && node.downloadUrl != null)
                      ? ClipRRect(
                          borderRadius: BorderRadius.circular(3),
                          child: Image.network(
                            node.downloadUrl!, fit: BoxFit.cover, cacheWidth: 120,
                            errorBuilder: (ctx, err, stack) => Icon(node.icon, color: node.color, size: 20),
                          ),
                        )
                      : (node.type == VfsNodeType.video && node.downloadUrl != null)
                          ? VideoThumbnailWidget(videoUrl: node.downloadUrl!, fallbackIcon: node.icon, color: node.color)
                          : Icon(node.icon, color: node.color, size: 20)
                  : Icon(node.icon, color: node.color, size: 20),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _getDisplayName(node.name), // 🔥 FIX: Hier wendest du deine Funktion an!
                    style: GoogleFonts.rajdhani(
                      color: node.isSelected ? AppColors.primary : Colors.white,
                      fontSize: 16, fontWeight: FontWeight.w600,
                    ),
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                  ),
                  if (controller.isDeepSearchActive)
                    Text(
                      "PATH: ${node.path}", 
                      style: const TextStyle(color: AppColors.accent, fontSize: 10),
                      maxLines: 1, overflow: TextOverflow.ellipsis,
                    )
                  else if (node.type != VfsNodeType.folder && node.type != VfsNodeType.drive)
                    Text(
                      "${(node.size/1024).toStringAsFixed(1)} KB",
                      style: const TextStyle(color: Colors.grey, fontSize: 11),
                    ),
                ],
              ),
            ),
            if (controller.isSelectionMode)
              Icon(node.isSelected ? Icons.check_box : Icons.check_box_outline_blank, color: node.isSelected ? AppColors.primary : Colors.grey)
            else if (node.isDirectory)
              const Icon(Icons.chevron_right, color: Colors.grey),
          ],
        ),
      ),
    );
  }

  Widget _buildActionBar(BuildContext context, FileVaultController controller) {
    if (controller.canPaste && !controller.isSelectionMode) {
       return TechCard(
        borderColor: AppColors.accent,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _buildActionButton(Icons.close, "CLEAR CLIPBOARD", () => controller.copySelection(), isDanger: true),
            _buildActionButton(Icons.content_paste, "PASTE HERE", () => controller.pasteFiles()),
          ],
        ),
      );
    }

    return TechCard(
      borderColor: AppColors.primary,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _buildActionButton(Icons.close, "CANCEL", () => controller.clearSelection()),
            
            // 🔥 NEU: Der Rename-Button (nur sichtbar, wenn genau 1 Element markiert ist)
            if (controller.selectedNodes.length == 1)
              _buildActionButton(Icons.edit, "RENAME", () => _showRenameDialog(context, controller, controller.selectedNodes.first)),
              
            _buildActionButton(Icons.copy, "COPY", () => controller.copySelection()),
            _buildActionButton(Icons.drive_file_move, "MOVE", () => controller.cutSelection()),
            _buildActionButton(Icons.download, "GET", () => controller.downloadSelection()),
            _buildActionButton(Icons.delete, "DEL", () => controller.deleteNodes(), isDanger: true),
          ],
        ),
      ),
    );
  }

  Widget _buildActionButton(IconData icon, String label, VoidCallback onTap, {bool isDanger = false}) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(8.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: isDanger ? AppColors.warning : Colors.white),
            const SizedBox(height: 4),
            Text(label, style: TextStyle(color: isDanger ? AppColors.warning : Colors.white, fontSize: 10, fontWeight: FontWeight.bold)),
          ],
        ),
      ),
    );
  }

  void _showSortMenu(BuildContext context, FileVaultController controller) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: AppColors.card.withValues(alpha: 0.95),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          border: Border(top: BorderSide(color: AppColors.primary.withValues(alpha: 0.5))),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text("SORT SYSTEM NODES", style: TextStyle(color: AppColors.primary, fontWeight: FontWeight.bold, letterSpacing: 2)),
            const SizedBox(height: 20),
            _buildSortOption(ctx, controller, "NAME (A-Z)", SortOption.name, Icons.sort_by_alpha),
            _buildSortOption(ctx, controller, "DATE (TIME)", SortOption.date, Icons.calendar_today),
            _buildSortOption(ctx, controller, "SIZE (BYTES)", SortOption.size, Icons.data_usage),
            _buildSortOption(ctx, controller, "TYPE (FORMAT)", SortOption.type, Icons.category),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }

  Widget _buildSortOption(BuildContext ctx, FileVaultController ctrl, String label, SortOption opt, IconData icon) {
    final isSelected = ctrl.currentSort == opt;
    return ListTile(
      leading: Icon(icon, color: isSelected ? AppColors.accent : Colors.grey),
      title: Text(label, style: TextStyle(color: isSelected ? Colors.white : Colors.grey, fontFamily: 'Rajdhani', fontWeight: FontWeight.bold)),
      trailing: isSelected ? Icon(ctrl.sortAscending ? Icons.arrow_upward : Icons.arrow_downward, color: AppColors.accent) : null,
      onTap: () {
        ctrl.changeSort(opt);
        Navigator.pop(ctx);
      },
    );
  }
  void _showCreateFolderDialog(BuildContext context, FileVaultController controller) {
    if (controller.currentPath == "ROOT" || controller.currentPath == "Drives") {
       ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Select a drive/folder first", style: TextStyle(color: Colors.white)), backgroundColor: AppColors.warning));
       return;
    }
    final TextEditingController textCtrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.card,
        title: const Text("NEW FOLDER", style: TextStyle(color: AppColors.primary, fontWeight: FontWeight.bold, letterSpacing: 1.5)),
        content: TextField(
          controller: textCtrl,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            hintText: "Folder Name",
            hintStyle: TextStyle(color: AppColors.textDim),
            enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: AppColors.primary)),
            focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: AppColors.accent)),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("CANCEL", style: TextStyle(color: Colors.grey))),
          TextButton(
            onPressed: () {
              if (textCtrl.text.trim().isNotEmpty) {
                controller.createFolder(textCtrl.text.trim());
                Navigator.pop(ctx);
              }
            }, 
            child: const Text("CREATE", style: TextStyle(color: AppColors.primary, fontWeight: FontWeight.bold))
          ),
        ],
      )
    );
  }

  void _showRenameDialog(BuildContext context, FileVaultController controller, VfsNode node) {
    final TextEditingController textCtrl = TextEditingController(text: node.name);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.card,
        title: const Text("RENAME NODE", style: TextStyle(color: AppColors.accent, fontWeight: FontWeight.bold, letterSpacing: 1.5)),
        content: TextField(
          controller: textCtrl,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            hintText: "New Name",
            hintStyle: TextStyle(color: AppColors.textDim),
            enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: AppColors.accent)),
            focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: AppColors.primary)),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("CANCEL", style: TextStyle(color: Colors.grey))),
          TextButton(
            onPressed: () {
              if (textCtrl.text.trim().isNotEmpty && textCtrl.text.trim() != node.name) {
                controller.renameNode(node, textCtrl.text.trim());
                controller.clearSelection(); 
                Navigator.pop(ctx);
              }
            }, 
            child: const Text("RENAME", style: TextStyle(color: AppColors.accent, fontWeight: FontWeight.bold))
          ),
        ],
      )
    );
  }
  // 🔥 NEU: Schneidet lange C:/ Pfade ab und zeigt nur den echten Ordnernamen
  String _getDisplayName(String rawName) {
    // Standard-Namen wie "HDD Storage" in Ruhe lassen
    if (rawName == "ROOT" || rawName == "Drives" || rawName == "HDD Storage") {
      return rawName;
    }
    
    // Zerschneidet den Text bei jedem "/" oder "\" und nimmt das allerletzte Wort
    final parts = rawName.split(RegExp(r'[/\\]')).where((s) => s.trim().isNotEmpty).toList();
    if (parts.isNotEmpty) {
      return parts.last;
    }
    
    return rawName;
  }
}