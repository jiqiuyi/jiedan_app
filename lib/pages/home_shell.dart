import 'package:flutter/material.dart';
import '../l10n/l10n.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../constants.dart';
import '../database.dart';
import '../models.dart';
import '../theme.dart';
import '../services/error_reporter.dart';
import '../services/update_service.dart';

import 'dashboard_page.dart';
import 'projects_page.dart';
import 'customers_page.dart';
import 'quote_page.dart';
import 'settings_page.dart';

/// App 主壳：底部五栏导航
class HomeShell extends StatefulWidget {
const   HomeShell({super.key});

  @override
  State<HomeShell> createState() => HomeShellState();
}

class HomeShellState extends State<HomeShell> {
  int _index = 0;

  // ---- 悬浮球可拖动（v1.46.3）----
  static const double _fabSize = 56; // FloatingActionButton 默认尺寸
  static const double _edgeMargin = 8; // 左右最小边距
  static const double _dragThreshold = 10; // 超过该位移视为拖动，否则视为点击
  static const double _navBarHeight = 80; // Material3 NavigationBar 默认高度
  static const String _prefFabDx = 'fab_dx_ratio';
  static const String _prefFabDy = 'fab_dy_ratio';

  double _fabDx = 0; // 悬浮球 left（未恢复前为默认右下）
  double _fabDy = 0; // 悬浮球 top
  bool _fabLoaded = false; // 是否已从本地恢复位置
  Offset? _dragStart; // 拖动起点（fab 当前位置）
  Offset? _pointerStart; // 指针按下位置（fab 本地坐标）
  bool _fabDragging = false; // 本次手势是否已判定为拖动

  @override
  void initState() {
    super.initState();
    // 启动后稍等片刻自动检查更新（非强制，网络失败静默）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Future.delayed(Duration(milliseconds: 1500), () {
        if (!mounted) return;
        // 三星等机型存储/平台偶发异常若冒泡会触发全局兜底弹窗，
        // 这里一律降级为留日志静默（用户可在「设置-检查更新」手动触发）。
        try {
          UpdateService.instance.checkAuto(context);
        } catch (e, st) {
          ErrorReporter.instance.logError('update_check_auto', e, st);
        }
      });
    });
    // 异步恢复上次保存的悬浮球位置（await 后已过首帧，MediaQuery 可用）
    _loadFabPosition();
  }

  /// 从 SharedPreferences 恢复悬浮球位置（比例值），无历史值时保持默认右下。
  /// 读取失败（三星等机型存储偶发异常）静默保持默认位置，绝不冒泡到全局兜底。
  Future<void> _loadFabPosition() async {
    double? rx;
    double? ry;
    try {
      final prefs = await SharedPreferences.getInstance();
      rx = prefs.getDouble(_prefFabDx);
      ry = prefs.getDouble(_prefFabDy);
    } catch (_) {
      // 恢复失败保持默认位置，不影响主界面。
    }
    if (!mounted) return;
    if (rx != null && ry != null) {
      final rxv = rx;
      final ryv = ry;
      final bound = _fabBounds();
      setState(() {
        _fabDx = _edgeMargin + rxv * (bound.maxX - _edgeMargin);
        _fabDy = bound.minY + ryv * (bound.maxY - bound.minY);
        _fabLoaded = true;
      });
    } else {
      setState(() => _fabLoaded = true);
    }
  }

  /// 悬浮球可活动边界：左右留 8px、上方留状态栏高度、下方避开 NavigationBar。
  ({double minX, double maxX, double minY, double maxY}) _fabBounds() {
    final size = MediaQuery.of(context).size;
    final top = MediaQuery.of(context).padding.top;
    final minX = _edgeMargin;
    final maxX = size.width - _fabSize - _edgeMargin;
    final minY = top + _edgeMargin;
    final maxY = size.height - _navBarHeight - _fabSize - _edgeMargin;
    return (minX: minX, maxX: maxX, minY: minY, maxY: maxY);
  }

  /// 拖动结束保存位置（比例值，便于不同分辨率适配）。
  /// 保存失败（三星等机型存储偶发异常）只留日志，不影响本次拖动。
  Future<void> _saveFabPosition() async {
    try {
      final b = _fabBounds();
      final rx = ((_fabDx - b.minX) / (b.maxX - b.minX)).clamp(0.0, 1.0);
      final ry = ((_fabDy - b.minY) / (b.maxY - b.minY)).clamp(0.0, 1.0);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_prefFabDx, rx);
      await prefs.setDouble(_prefFabDy, ry);
    } catch (e, st) {
      ErrorReporter.instance.logError('fab_save_pos', e, st);
    }
  }

  /// 悬浮球 Widget：可拖动，未拖动时 onPanEnd 触发点击（打开极速记账）。
  Widget _buildFab(BuildContext context) {
    final b = _fabBounds();
    // 未恢复前使用默认右下位置（距右 16、距底部 NavigationBar 上缘 16）
    var dx = _fabLoaded ? _fabDx : b.maxX - 16 + 8; // 右侧 16px 视觉边距
    var dy = _fabLoaded ? _fabDy : b.maxY - 16;
    dx = dx.clamp(b.minX, b.maxX).toDouble();
    dy = dy.clamp(b.minY, b.maxY).toDouble();

    return Positioned(
      left: dx,
      top: dy,
      child: GestureDetector(
        onPanDown: (d) {
          _dragStart = Offset(_fabDx, _fabDy);
          _pointerStart = d.localPosition;
          _fabDragging = false;
        },
        onPanUpdate: (d) {
          final start = _dragStart;
          final ptr = _pointerStart;
          if (start == null || ptr == null) return;
          final delta = d.localPosition - ptr;
          if (delta.distance > _dragThreshold) _fabDragging = true;
          if (_fabDragging) {
            setState(() {
              _fabDx = (start.dx + delta.dx).clamp(b.minX, b.maxX);
              _fabDy = (start.dy + delta.dy).clamp(b.minY, b.maxY);
            });
          }
        },
        onPanEnd: (_) {
          if (_fabDragging) {
            _saveFabPosition();
          } else {
            // 未达到拖动阈值，视为点击：打开极速记账
            openQuickLedger();
          }
        },
        child: FloatingActionButton(
          onPressed: openQuickLedger,
          backgroundColor: AppTheme.accent,
          foregroundColor: Colors.white,
          tooltip: L10n.instance.t('home_quick_ledger'),
          child: Icon(Icons.edit_note, size: 30),
        ),
      ),
    );
  }

  static const _pages = [
    DashboardPage(),
    ProjectsPage(),
    CustomersPage(),
    QuotePage(),
    SettingsPage(),
  ];

  /// 极速记账：保存成功返回 true，由调用方 toast「已记账」。
  /// 由全局悬浮球调用；桌面小组件「记一笔」（QUICK_LEDGER）也会经
  /// HomeShellState 直接拉起同一面板，不经过首页。
  Future<void> openQuickLedger() async {
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => QuickLedgerSheet(),
    );
    if (saved == true && mounted) {
      ScaffoldMessenger.of(context)
        ..removeCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(L10n.instance.t('home_logged'))));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          IndexedStack(index: _index, children: _pages),
          _buildFab(context),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: [
          NavigationDestination(icon: Icon(Icons.dashboard_outlined), selectedIcon: Icon(Icons.dashboard), label: L10n.instance.t('home_tab_home')),
          NavigationDestination(icon: Icon(Icons.work_outline), selectedIcon: Icon(Icons.work), label: L10n.instance.t('common_project')),
          NavigationDestination(icon: Icon(Icons.people_outline), selectedIcon: Icon(Icons.people), label: L10n.instance.t('common_customer')),
          NavigationDestination(icon: Icon(Icons.receipt_long_outlined), selectedIcon: Icon(Icons.receipt_long), label: L10n.instance.t('common_quote')),
          NavigationDestination(icon: Icon(Icons.person_outline), selectedIcon: Icon(Icons.person), label: L10n.instance.t('settings_title')),
        ],
      ),
    );
  }
}

/// 极速记账面板（全局悬浮球/桌面小组件「记一笔」弹出）：分类 chip + 大号金额 + 快捷金额 + 备注 + 保存。
/// 保存成功 `Navigator.pop(context, true)`，由 HomeShell toast「已记账」。
class QuickLedgerSheet extends StatefulWidget {
const   QuickLedgerSheet({super.key});

  @override
  State<QuickLedgerSheet> createState() => QuickLedgerSheetState();
}

class QuickLedgerSheetState extends State<QuickLedgerSheet> {
  static const _quickAmounts = [10, 20, 30, 50, 100];

  final AppDb _db = AppDb.instance;
  final TextEditingController _amountCtrl = TextEditingController();
  final TextEditingController _noteCtrl = TextEditingController();
  String _category = AppConfig.LEDGER_CATEGORIES.first;
  bool _saving = false;

  @override
  void dispose() {
    _amountCtrl.dispose();
    _noteCtrl.dispose();
    super.dispose();
  }

  void _setAmount(int yuan) {
    setState(() => _amountCtrl.text = yuan.toString());
  }

  Future<void> _save() async {
    final v = double.tryParse(_amountCtrl.text.trim());
    if (v == null || v <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(L10n.instance.t('home_amount_hint'))));
      return;
    }
    if (_saving) return;
    setState(() => _saving = true);
    final fen = (v * 100).round();
    final now = DateTime.now();
    final day = DateTime(now.year, now.month, now.day);
    await _db.insertLedgerEntry(LedgerEntry(
      amount: fen,
      kind: 0, // 极速记账默认支出
      category: _category,
      note: _noteCtrl.text.trim(),
      projectId: 0,
      entryDate: day.millisecondsSinceEpoch,
      createdAt: now.millisecondsSinceEpoch,
      updatedAt: now.millisecondsSinceEpoch,
    ));
    if (!mounted) return;
    Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: Material(
        color: Colors.white,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        clipBehavior: Clip.antiAlias,
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(L10n.instance.t('home_quick_ledger'),
                        style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
                    IconButton(
                      onPressed: () => Navigator.pop(context),
                      icon: Icon(Icons.close),
                      visualDensity: VisualDensity.compact,
                    ),
                  ],
                ),
                // 分类 chips（LEDGER_CATEGORIES 全 9 类：前 8 常用 + 其他）
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: AppConfig.LEDGER_CATEGORIES.map((c) {
                    final selected = _category == c;
                    return ChoiceChip(
                      label: Text(L10n.instance.t(AppConfig.ledgerCatKey(c))),
                      selected: selected,
                      onSelected: (_) => setState(() => _category = c),
                      selectedColor: AppTheme.accent.withValues(alpha: 0.14),
                      labelStyle: TextStyle(
                        color: selected ? AppTheme.accent : AppTheme.textMain,
                        fontWeight:
                            selected ? FontWeight.w600 : FontWeight.normal,
                        fontSize: 13,
                      ),
                    );
                  }).toList(),
                ),
                SizedBox(height: 14),
                // 大号金额输入框
                TextField(
                  controller: _amountCtrl,
                  autofocus: true,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                  ],
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 38, fontWeight: FontWeight.w700),
                  decoration: InputDecoration(
                    hintText: '0.00',
                    prefixText: '¥ ',
                    prefixStyle: TextStyle(fontSize: 22),
                    filled: true,
                    fillColor: AppTheme.bgCard,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
                SizedBox(height: 10),
                // 快捷金额 chips
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: _quickAmounts.map((y) {
                    final selected = _amountCtrl.text == y.toString();
                    return ActionChip(
                      label: Text(L10n.instance.t('home_yuan', args: {'y':'$y'})),
                      onPressed: () => _setAmount(y),
                      backgroundColor:
                          selected ? AppTheme.accent.withValues(alpha: 0.14) : AppTheme.bgCard,
                      side: BorderSide.none,
                      labelStyle: TextStyle(
                        color: selected ? AppTheme.accent : AppTheme.textMain,
                        fontWeight: FontWeight.w600,
                      ),
                    );
                  }).toList(),
                ),
                SizedBox(height: 10),
                // 备注（单行可选）
                TextField(
                  controller: _noteCtrl,
                  maxLength: 50,
                  decoration: InputDecoration(
                    hintText: L10n.instance.t('common_note_optional'),
                    counterText: '',
                    isDense: true,
                    filled: true,
                    fillColor: AppTheme.bgCard,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.all(Radius.circular(14)),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
                SizedBox(height: 12),
                // 保存主按钮
                SizedBox(
                  height: 50,
                  child: FilledButton(
                    onPressed: _save,
                    style: FilledButton.styleFrom(
                      backgroundColor: AppTheme.accent,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14)),
                    ),
                    child: _saving
                        ? SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white))
                        : Text(L10n.instance.t('common_save'),
                            style: TextStyle(
                                fontSize: 16, fontWeight: FontWeight.w700)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
