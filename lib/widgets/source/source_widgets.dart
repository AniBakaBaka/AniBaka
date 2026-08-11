import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:baka/services/source/rule_repository_service.dart';
import 'package:baka/theme.dart';
import 'package:baka/utils/toast_utils.dart';

class SourceIcon extends StatelessWidget {
  final String name;
  final String? iconUrl;
  final String? baseUrl;
  final bool enabled;
  final double size;
  final double radius;

  const SourceIcon({
    required this.name,
    this.iconUrl,
    this.baseUrl,
    this.enabled = true,
    this.size = 44,
    this.radius = 12,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final url = sourceWebsiteIconUrl(iconUrl: iconUrl, baseUrl: baseUrl);
    if (url != null && url.isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: CachedNetworkImage(
          imageUrl: url,
          width: size,
          height: size,
          fit: BoxFit.cover,
          placeholder: (context, _) => _buildFallback(context),
          errorWidget: (_, _, _) => _buildFallback(context),
        ),
      );
    }
    return _buildFallback(context);
  }

  Widget _buildFallback(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final initial = name.isNotEmpty ? name[0].toUpperCase() : '?';

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: enabled
            ? (isDark
                  ? Colors.white.withValues(alpha: 0.1)
                  : Colors.black.withValues(alpha: 0.05))
            : (isDark
                  ? Colors.white.withValues(alpha: 0.05)
                  : Colors.black.withValues(alpha: 0.02)),
        borderRadius: BorderRadius.circular(radius),
      ),
      child: Center(
        child: Text(
          initial,
          style: TextStyle(
            color: enabled
                ? (isDark ? Colors.white : Colors.black)
                : (isDark ? Colors.white54 : Colors.black45),
            fontSize: size * 0.45,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

String? sourceWebsiteIconUrl({String? iconUrl, String? baseUrl}) {
  final explicit = Uri.tryParse(iconUrl?.trim() ?? '');
  if (explicit != null &&
      (explicit.scheme == 'http' || explicit.scheme == 'https') &&
      explicit.host.isNotEmpty) {
    return explicit.toString();
  }

  final site = Uri.tryParse(baseUrl?.trim() ?? '');
  if (site == null ||
      (site.scheme != 'http' && site.scheme != 'https') ||
      site.host.isEmpty) {
    return null;
  }
  return site.resolve('/favicon.ico').toString();
}

Future<T?> showSourceDialog<T>({
  required BuildContext context,
  required String title,
  required Widget content,
  List<Widget>? actions,
}) {
  final isDark = Theme.of(context).brightness == Brightness.dark;
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Dismiss',
    pageBuilder: (context, animation, _) => ScaleTransition(
      scale: CurvedAnimation(parent: animation, curve: Curves.easeOutBack),
      child: AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        backgroundColor: isDark ? const Color(0xFF1C1C1E) : Colors.white,
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
        content: content,
        actions: actions,
      ),
    ),
  );
}

Future<bool> showSourceConfirmDialog({
  required BuildContext context,
  required String title,
  required String content,
  String cancelText = '取消',
  String confirmText = '确定',
  bool isDestructive = false,
}) async {
  final result = await showSourceDialog<bool>(
    context: context,
    title: title,
    content: Text(content),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context, false),
        child: Text(cancelText, style: TextStyle(color: Colors.grey[600])),
      ),
      TextButton(
        onPressed: () => Navigator.pop(context, true),
        child: Text(
          confirmText,
          style: TextStyle(
            color: isDestructive ? Colors.red : null,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    ],
  );
  return result == true;
}

class SourceGridCard extends StatelessWidget {
  final Widget icon;
  final String title;
  final String subtitle;
  final String badge;
  final String buttonLabel;
  final bool installed;
  final bool enabled;
  final bool hasUpdate;
  final bool busy;
  final VoidCallback? onTap;
  final VoidCallback? onButtonPressed;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;

  const SourceGridCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.badge,
    required this.buttonLabel,
    required this.installed,
    required this.enabled,
    this.hasUpdate = false,
    this.busy = false,
    this.onTap,
    this.onButtonPressed,
    this.onEdit,
    this.onDelete,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final active = installed && enabled;
    final emphasized = active || hasUpdate;
    final primary = context.primaryColor;
    final hint = context.theme.hintColor;
    final buttonAction = busy ? null : (onButtonPressed ?? onTap);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: active ? primary.withValues(alpha: 0.05) : context.cardColor,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: emphasized
              ? primary.withValues(alpha: 0.3)
              : context.theme.dividerColor.withValues(alpha: 0.1),
          width: emphasized ? 1.5 : 1,
        ),
      ),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: busy ? null : onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  icon,
                  const Spacer(),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: emphasized
                          ? primary.withValues(alpha: 0.1)
                          : context.theme.dividerColor.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      badge,
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        color: emphasized ? primary : hint,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                            letterSpacing: -0.3,
                            color: active || !installed
                                ? context.theme.textTheme.bodyLarge?.color
                                : hint,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 11, color: hint),
                        ),
                      ],
                    ),
                  ),
                  if (onEdit != null || onDelete != null)
                    SizedBox.square(
                      dimension: 28,
                      child: PopupMenuButton<String>(
                        padding: EdgeInsets.zero,
                        icon: Icon(
                          Icons.more_vert_rounded,
                          size: 18,
                          color: hint,
                        ),
                        color: context.cardColor,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        onSelected: (value) {
                          if (value == 'edit') onEdit?.call();
                          if (value == 'delete') onDelete?.call();
                        },
                        itemBuilder: (_) => [
                          if (onEdit != null)
                            const PopupMenuItem(
                              value: 'edit',
                              child: Text('编辑'),
                            ),
                          if (onEdit != null && onDelete != null)
                            const PopupMenuDivider(),
                          if (onDelete != null)
                            PopupMenuItem(
                              value: 'delete',
                              child: Text(
                                '删除',
                                style: TextStyle(
                                  color: context.colorScheme.error,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                ],
              ),
              const Spacer(),
              SizedBox(
                width: double.infinity,
                height: 32,
                child: FilledButton(
                  onPressed: buttonAction,
                  style: FilledButton.styleFrom(
                    elevation: 0,
                    padding: EdgeInsets.zero,
                    backgroundColor: emphasized
                        ? primary
                        : context.theme.dividerColor.withValues(alpha: 0.1),
                    foregroundColor: emphasized ? Colors.white : hint,
                    disabledBackgroundColor: context.theme.dividerColor
                        .withValues(alpha: 0.08),
                    disabledForegroundColor: hint,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  child: busy
                      ? const SizedBox.square(
                          dimension: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(
                          buttonLabel,
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class SourceReorderSection<T> extends StatelessWidget {
  final String title;
  final List<T> items;
  final String Function(T item) keyOf;
  final Widget Function(T item) iconBuilder;
  final String Function(T item) titleOf;
  final String Function(T item) subtitleOf;
  final Future<void> Function(int oldIndex, int newIndex) onReorder;

  const SourceReorderSection({
    required this.title,
    required this.items,
    required this.keyOf,
    required this.iconBuilder,
    required this.titleOf,
    required this.subtitleOf,
    required this.onReorder,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Text(
              title.toUpperCase(),
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: context.theme.hintColor,
                letterSpacing: 0.5,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: context.cardColor,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: context.theme.dividerColor.withValues(alpha: 0.1),
                ),
              ),
              child: ReorderableListView.builder(
                shrinkWrap: true,
                primary: false,
                buildDefaultDragHandles: false,
                physics: const NeverScrollableScrollPhysics(),
                padding: EdgeInsets.zero,
                itemCount: items.length,
                onReorderItem: (oldIndex, newIndex) async {
                  HapticFeedback.lightImpact();
                  await onReorder(oldIndex, newIndex);
                },
                itemBuilder: (context, index) {
                  final item = items[index];
                  final subtitle = subtitleOf(item);
                  return ReorderableDelayedDragStartListener(
                    key: ValueKey(keyOf(item)),
                    index: index,
                    child: Column(
                      children: [
                        ListTile(
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 2,
                          ),
                          leading: SizedBox.square(
                            dimension: 32,
                            child: Center(child: iconBuilder(item)),
                          ),
                          title: Text(
                            titleOf(item),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          subtitle: subtitle.isEmpty
                              ? null
                              : Text(
                                  subtitle,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: context.theme.hintColor,
                                  ),
                                ),
                          trailing: Icon(
                            Icons.drag_handle_rounded,
                            color: context.theme.dividerColor,
                          ),
                        ),
                        if (index < items.length - 1)
                          Padding(
                            padding: const EdgeInsets.only(left: 60),
                            child: Divider(
                              height: 0.5,
                              thickness: 0.5,
                              color: context.theme.dividerColor,
                            ),
                          ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class SourceSubscriptionSheet extends StatelessWidget {
  final RuleRepositoryService repo;

  const SourceSubscriptionSheet({required this.repo, super.key});

  Future<void> _add(BuildContext context) async {
    final controller = TextEditingController();
    final confirmed = await showSourceDialog<bool>(
      context: context,
      title: '添加订阅',
      content: TextField(
        controller: controller,
        autofocus: true,
        style: const TextStyle(fontSize: 13, fontFamily: 'monospace'),
        decoration: const InputDecoration(
          labelText: 'index.json 地址',
          hintText: 'https://...',
          border: OutlineInputBorder(),
          fillColor: Colors.transparent,
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('添加'),
        ),
      ],
    );

    final url = controller.text;
    controller.dispose();
    if (confirmed != true || url.trim().isEmpty) return;

    final added = await repo.addSubscription(url);
    if (!context.mounted) return;
    showSnackBar(added ? '已添加订阅' : '地址无效或已存在', isError: !added);
  }

  Future<void> _remove(String url) => repo.removeSubscription(url);

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: repo,
      builder: (context, _) => _buildContent(context, repo.subscriptions),
    );
  }

  Widget _buildContent(BuildContext context, List<String> subscriptions) {
    return Container(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      decoration: BoxDecoration(
        color: context.cardColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 12),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: context.theme.hintColor,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 12, 4),
              child: Row(
                children: [
                  const Text(
                    '订阅管理',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                  ),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: () => _add(context),
                    icon: const Icon(Icons.add_rounded, size: 18),
                    label: const Text('添加'),
                  ),
                ],
              ),
            ),
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height * 0.5,
              ),
              child: ListView.separated(
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                itemCount: subscriptions.length,
                separatorBuilder: (_, _) => const SizedBox(height: 8),
                itemBuilder: (context, index) {
                  final url = subscriptions[index];
                  final isDefault =
                      url == RuleRepositoryService.defaultSubscription;
                  return ListTile(
                    tileColor: context.theme.dividerColor.withValues(
                      alpha: 0.1,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    title: Text(
                      url,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        fontFamily: 'monospace',
                      ),
                    ),
                    trailing: isDefault
                        ? Text(
                            '默认',
                            style: TextStyle(
                              fontSize: 12,
                              color: context.theme.hintColor,
                            ),
                          )
                        : IconButton(
                            onPressed: () => _remove(url),
                            icon: Icon(
                              Icons.delete_outline_rounded,
                              color: context.colorScheme.error,
                            ),
                          ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
