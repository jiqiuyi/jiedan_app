import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api_client.dart';
import '../theme.dart';

/// 管理后台（仅管理员角色可见）。
/// Tab 划分：待确认 / 抽查 / 返现 / 待打款 / 收款配置 / 服务状态 / 操作日志。
class AdminPage extends StatefulWidget {
  const AdminPage({super.key});

  @override
  State<AdminPage> createState() => _AdminPageState();
}

class _AdminPageState extends State<AdminPage> {
  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 7,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('管理后台'),
          bottom: const TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: [
              Tab(text: '待确认'),
              Tab(text: '抽查'),
              Tab(text: '返现'),
              Tab(text: '待打款'),
              Tab(text: '收款配置'),
              Tab(text: '服务状态'),
              Tab(text: '操作日志'),
            ],
          ),
        ),
        body: const TabBarView(
          children: [
            _ConfirmingTab(),
            _SpotcheckTab(),
            _RebateTab(),
            _PayoutTab(),
            _QrcodeTab(),
            _ListenerTab(),
            _LogTab(),
          ],
        ),
      ),
    );
  }
}

// ==================== 待确认订单 ====================

class _ConfirmingTab extends StatefulWidget {
  const _ConfirmingTab();
  @override
  State<_ConfirmingTab> createState() => _ConfirmingTabState();
}

class _ConfirmingTabState extends State<_ConfirmingTab> {
  List<Map<String, dynamic>> _orders = [];
  bool _loading = true;
  String? _error;

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final orders = await ApiClient.instance.adminOrders('confirming');
      if (!mounted) return;
      setState(() {
        _orders = orders;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    }
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(child: Text(_error!));
    }
    if (_orders.isEmpty) {
      return const Center(
          child: Text('暂无待确认订单', style: TextStyle(color: AppTheme.textSub)));
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        itemCount: _orders.length,
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (c, i) {
          final o = _orders[i];
          return ListTile(
            title: Text('订单号 ${o['orderNo'] ?? ''}'),
            subtitle: Text(
                '金额 ¥${(o['amount'] as num?)?.toStringAsFixed(2) ?? '-'} · '
                '${_uidLabel(o['userId'])}'),
            trailing: const Text('待核实',
                style: TextStyle(color: AppTheme.warn, fontSize: 12)),
          );
        },
      ),
    );
  }

  String _uidLabel(dynamic id) => '用户#$id';
}

// ==================== 抽查 ====================

class _SpotcheckTab extends StatefulWidget {
  const _SpotcheckTab();
  @override
  State<_SpotcheckTab> createState() => _SpotcheckTabState();
}

class _SpotcheckTabState extends State<_SpotcheckTab> {
  List<Map<String, dynamic>> _items = [];
  bool _loading = true;
  String? _error;

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await ApiClient.instance.adminSpotchecks();
      if (!mounted) return;
      setState(() {
        _items = list;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    }
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _review(Map<String, dynamic> item, String action) async {
    try {
      await ApiClient.instance
          .adminSpotcheckReview((item['id'] as num).toInt(), action);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(action == 'approve' ? '已通过' : '已驳回')));
      _load();
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(child: Text(_error!));
    }
    if (_items.isEmpty) {
      return const Center(
          child: Text('暂无抽查单', style: TextStyle(color: AppTheme.textSub)));
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        itemCount: _items.length,
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (c, i) {
          final it = _items[i];
          final order = it['order'] is Map
              ? (it['order'] as Map).cast<String, dynamic>()
              : <String, dynamic>{};
          return ListTile(
            title: Text('抽查 #${it['id']} · '
                '¥${(order['amount'] as num?)?.toStringAsFixed(2) ?? '-'}'),
            subtitle: Text(
                '${it['reason'] ?? ''}\n上报金额 ${_fmt(it['reportedAmount'])} · '
                '时间 ${_fmt(it['reportedAt'])}'),
            isThreeLine: true,
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: const Icon(Icons.check_circle,
                      color: Color(0xFF07C160)),
                  tooltip: '通过',
                  onPressed: () => _review(it, 'approve'),
                ),
                IconButton(
                  icon: const Icon(Icons.cancel, color: AppTheme.danger),
                  tooltip: '驳回',
                  onPressed: () => _review(it, 'reject'),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  String _fmt(dynamic v) {
    if (v == null) return '-';
    if (v is num) {
      if (v > 1e12) {
        return DateTime.fromMillisecondsSinceEpoch(v.toInt()).toString();
      }
      return v.toStringAsFixed(2);
    }
    return '$v';
  }
}

// ==================== 返现明细 ====================

class _RebateTab extends StatefulWidget {
  const _RebateTab();
  @override
  State<_RebateTab> createState() => _RebateTabState();
}

class _RebateTabState extends State<_RebateTab> {
  List<Map<String, dynamic>> _details = [];
  Map<String, dynamic> _totals = const {};
  bool _loading = true;

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final res = await ApiClient.instance.adminRebates();
      if (!mounted) return;
      setState(() {
        _details = (res['details'] as List<dynamic>? ?? [])
            .cast<Map<String, dynamic>>();
        _totals = (res['totals'] is Map)
            ? (res['totals'] as Map).cast<String, dynamic>()
            : const {};
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _details = [];
        _totals = {'error': e.message};
        _loading = false;
      });
    }
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    return ListView(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            '累计返现 ¥${_num(_totals['totalRebate']).toStringAsFixed(2)} · '
            '待打款 ¥${_num(_totals['totalPayout']).toStringAsFixed(2)}',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
        ..._details.map((d) => ListTile(
              title: Text('返现 ¥${_num(d['rebate']).toStringAsFixed(2)}'),
              subtitle:
                  Text('来自 ${d['fromNickname'] ?? d['fromPhone'] ?? '-'}'),
            )),
      ],
    );
  }

  double _num(dynamic v) => v is num ? v.toDouble() : 0;
}

// ==================== 待打款 ====================

class _PayoutTab extends StatefulWidget {
  const _PayoutTab();
  @override
  State<_PayoutTab> createState() => _PayoutTabState();
}

class _PayoutTabState extends State<_PayoutTab> {
  List<Map<String, dynamic>> _payouts = [];
  bool _loading = true;
  double _total = 0;

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final res = await ApiClient.instance.adminPayouts();
      if (!mounted) return;
      setState(() {
        _payouts = (res['payouts'] as List<dynamic>? ?? [])
            .cast<Map<String, dynamic>>();
        _total = res['totalRebate'] is num
            ? (res['totalRebate'] as num).toDouble()
            : 0;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _payouts = [];
        _total = 0;
        _loading = false;
      });
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_payouts.isEmpty) {
      return const Center(
          child: Text('暂无可打款返现',
              style: TextStyle(color: AppTheme.textSub)));
    }
    return ListView(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Text('待打款合计 ¥${_total.toStringAsFixed(2)}',
              style: const TextStyle(fontWeight: FontWeight.w600)),
        ),
        ..._payouts.map((p) => ListTile(
              title: Text(
                  '${p['nickname'] ?? p['phone'] ?? '-'} · '
                  '¥${_num(p['rebate']).toStringAsFixed(2)}'),
              subtitle: Text('可提现 ¥${_num(p['available']).toStringAsFixed(2)}'),
            )),
        const Padding(
          padding: EdgeInsets.all(16),
          child: Text('返现由推广方可随时在钱包提现，此处仅作汇总参考。',
              style: TextStyle(color: AppTheme.textSub, fontSize: 12)),
        ),
      ],
    );
  }

  double _num(dynamic v) => v is num ? v.toDouble() : 0;
}

// ==================== 收款码配置 ====================

class _QrcodeTab extends StatefulWidget {
  const _QrcodeTab();
  @override
  State<_QrcodeTab> createState() => _QrcodeTabState();
}

class _QrcodeTabState extends State<_QrcodeTab> {
  final _wechat = TextEditingController();
  final _alipay = TextEditingController();
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final res = await ApiClient.instance.adminQrcodeGet();
      if (!mounted) return;
      setState(() {
        _wechat.text = (res['wechat'] ?? '').toString();
        _alipay.text = (res['alipay'] ?? '').toString();
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await ApiClient.instance.adminQrcode(
        wechat: _wechat.text.trim(),
        alipay: _alipay.text.trim(),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('收款方式已更新')));
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  void dispose() {
    _wechat.dispose();
    _alipay.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text('收款方式链接（App 端点一下直接拉起对应支付）：',
            style: TextStyle(fontSize: 13, color: AppTheme.textSub)),
        const SizedBox(height: 12),
        TextField(
          controller: _wechat,
          decoration: const InputDecoration(
            labelText: '微信收款链接',
            hintText: '如 weixin://... 或小程序码链接',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _alipay,
          decoration: const InputDecoration(
            labelText: '支付宝收款链接',
            hintText: '如 alipays://... 或收款页 https://...',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 8),
        const Text('留空表示未配置该渠道；未配置的渠道在 App 端会提示联系商家。',
            style: TextStyle(fontSize: 12, color: AppTheme.textSub)),
        const SizedBox(height: 20),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: Text(_saving ? '保存中…' : '保存配置'),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          icon: const Icon(Icons.copy, size: 16),
          label: const Text('复制收款码链接'),
          onPressed: () async {
            final link = _wechat.text.trim().isNotEmpty
                ? _wechat.text.trim()
                : _alipay.text.trim();
            if (link.isEmpty) return;
            await Clipboard.setData(ClipboardData(text: link));
            if (!mounted) return;
            ScaffoldMessenger.of(this.context).showSnackBar(
                const SnackBar(content: Text('已复制到剪贴板')));
          },
        ),
      ],
    );
  }
}

// ==================== 服务状态 ====================

class _ListenerTab extends StatefulWidget {
  const _ListenerTab();
  @override
  State<_ListenerTab> createState() => _ListenerTabState();
}

class _ListenerTabState extends State<_ListenerTab> {
  Map<String, dynamic> _data = const {};
  bool _loading = true;

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final res = await ApiClient.instance.adminListener();
      if (!mounted) return;
      setState(() {
        _data = res;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _data = {'error': e.message};
        _loading = false;
      });
    }
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    final items = <(String, dynamic)>[
      ('今日上报', _data['todayReports'] ?? 0),
      ('今日匹配成功', _data['todayMatched'] ?? 0),
      ('今日进入抽查', _data['todaySpotcheck'] ?? 0),
      ('收码配置', _data['qrcodeConfigured'] == true ? '已配置' : '未配置'),
      ('累计上报', _data['totalReports'] ?? 0),
    ];
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        children: items
            .map((e) => ListTile(
                  title: Text(e.$1),
                  trailing: Text('${e.$2}',
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                ))
            .toList(),
      ),
    );
  }
}

// ==================== 操作日志 ====================

class _LogTab extends StatefulWidget {
  const _LogTab();
  @override
  State<_LogTab> createState() => _LogTabState();
}

class _LogTabState extends State<_LogTab> {
  List<Map<String, dynamic>> _logs = [];
  bool _loading = true;

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final logs = await ApiClient.instance.adminLogs();
      if (!mounted) return;
      setState(() {
        _logs = logs;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _logs = [];
        _loading = false;
      });
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_logs.isEmpty) {
      return const Center(
          child: Text('暂无操作日志', style: TextStyle(color: AppTheme.textSub)));
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        itemCount: _logs.length,
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (c, i) {
          final l = _logs[i];
          return ListTile(
            title: Text('${l['action'] ?? ''} · ${_uidLabel(l['adminId'])}'),
            subtitle: Text(
                '${l['detail'] ?? ''}\n${_time(l['at'])}',
                maxLines: 3,
                overflow: TextOverflow.ellipsis),
            isThreeLine: true,
          );
        },
      ),
    );
  }

  String _uidLabel(dynamic id) => '操作人#$id';
  String? _time(dynamic v) {
    if (v is! num) return null;
    final dt = DateTime.fromMillisecondsSinceEpoch(v.toInt());
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-'
        '${dt.day.toString().padLeft(2, '0')} '
        '${dt.hour.toString().padLeft(2, '0')}:'
        '${dt.minute.toString().padLeft(2, '0')}';
  }
}
