import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/order_number_format.dart';
import '../user/user_order_detail_screen.dart' show orderStatusColor;

class ProviderOrdersScreen extends ConsumerStatefulWidget {
  const ProviderOrdersScreen({super.key});
  @override
  ConsumerState<ProviderOrdersScreen> createState() =>
      _ProviderOrdersScreenState();
}

class _ProviderOrdersScreenState extends ConsumerState<ProviderOrdersScreen> {
  static const _filters = [
    'All',
    'Pending',
    'In Progress',
    'Completed',
    'Cancelled',
  ];

  List<Map<String, dynamic>> _orders = [];
  Map<String, String> _userNames = {};
  String _filter = 'All';
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final client = Supabase.instance.client;
      final userId = client.auth.currentUser?.id;
      if (userId == null) return;
      final prov = await client
          .from('provider_profiles')
          .select('id')
          .eq('user_id', userId)
          .eq('provider_type', 'SERVICE_PROVIDER')
          .maybeSingle();
      if (prov == null) {
        if (mounted) setState(() => _loading = false);
        return;
      }
      final data = await client
          .from('orders')
          .select('*, order_items(count)')
          .eq('provider_id', prov['id'])
          .order('created_at', ascending: false)
          .limit(200);
      final orders = List<Map<String, dynamic>>.from(data as List);

      // Resolve customer names (best-effort).
      final names = <String, String>{};
      try {
        final userIds = orders
            .map((o) => o['user_id'] as String?)
            .whereType<String>()
            .toSet()
            .toList();
        if (userIds.isNotEmpty) {
          final profiles = await client
              .from('profiles')
              .select('id, full_name')
              .inFilter('id', userIds);
          for (final p in profiles as List) {
            names[p['id'] as String] = p['full_name'] as String? ?? '';
          }
        }
      } catch (_) {}

      if (mounted) {
        setState(() {
          _orders = orders;
          _userNames = names;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Sensible grouping of the order_status values for filtering.
  List<Map<String, dynamic>> get _filtered {
    switch (_filter) {
      case 'Pending':
        return _orders
            .where((o) => const {
                  'CREATED',
                  'PENDING_PROVIDER',
                  'ACCEPTED',
                  'PAYMENT_PENDING',
                  'PAYMENT_VERIFICATION',
                }.contains(o['status']))
            .toList();
      case 'In Progress':
        return _orders
            .where((o) => const {
                  'APPROVED',
                  'STARTED',
                  'DISPUTED',
                }.contains(o['status']))
            .toList();
      case 'Completed':
        return _orders
            .where((o) => o['status'] == 'COMPLETED')
            .toList();
      case 'Cancelled':
        return _orders
            .where((o) => const {
                  'CANCELLED',
                  'REJECTED',
                  'REFUNDED',
                }.contains(o['status']))
            .toList();
      default:
        return _orders;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('My Orders')),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: AppTheme.primaryGreen))
          : _orders.isEmpty
              ? const Center(
                  child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.receipt_long_outlined,
                        size: 64, color: AppTheme.textMuted),
                    SizedBox(height: 16),
                    Text('No orders yet',
                        style: TextStyle(color: AppTheme.textMuted)),
                  ],
                ))
              : Column(
                  children: [
                    _filterBar(),
                    Expanded(
                      child: RefreshIndicator(
                        onRefresh: _load,
                        child: _filtered.isEmpty
                            ? const Center(
                                child: Text('No orders in this status',
                                    style: TextStyle(
                                        color: AppTheme.textMuted)))
                            : ListView.builder(
                                padding: const EdgeInsets.all(16),
                                itemCount: _filtered.length,
                                itemBuilder: (_, i) =>
                                    _orderCard(_filtered[i]),
                              ),
                      ),
                    ),
                  ],
                ),
    );
  }

  Widget _filterBar() {
    return SizedBox(
      height: 48,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        itemCount: _filters.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (_, i) {
          final f = _filters[i];
          return ChoiceChip(
            label: Text(f, style: const TextStyle(fontSize: 12)),
            selected: _filter == f,
            onSelected: (_) => setState(() => _filter = f),
            selectedColor: AppTheme.primaryGreen.withOpacity(0.15),
            labelStyle: TextStyle(
                color: _filter == f ? AppTheme.primaryGreen : null,
                fontWeight:
                    _filter == f ? FontWeight.w600 : FontWeight.w400),
          );
        },
      ),
    );
  }

  Widget _orderCard(Map<String, dynamic> o) {
    final status = (o['status'] as String?) ?? 'UNKNOWN';
    final currency = o['currency'] as String? ?? 'ETB';
    final itemCount = _itemCount(o);
    final userName = _userNames[o['user_id']] ?? '';
    final shortId = orderLabel(o);
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ListTile(
        onTap: () async {
          await context.push('/user/orders/${o['id']}', extra: 'provider');
          if (mounted) _load();
        },
        title: Row(
          children: [
            Expanded(
              child: Text(shortId,
                  style: const TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w600)),
            ),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: orderStatusColor(status).withOpacity(0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(status.replaceAll('_', ' '),
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: orderStatusColor(status))),
            ),
          ],
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (userName.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(userName,
                    style: const TextStyle(fontSize: 13)),
              ),
            Text(
                '$itemCount ${itemCount == 1 ? 'item' : 'items'} • '
                '${_fmtDate(DateTime.parse(o['created_at'] as String))}',
                style: const TextStyle(
                    fontSize: 12, color: AppTheme.textMuted)),
          ],
        ),
        trailing: Text(
          '${(o['total_amount'] as num).toDouble().toStringAsFixed(2)} '
          '$currency',
          style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: AppTheme.primaryGreen),
        ),
      ),
    );
  }

  int _itemCount(Map<String, dynamic> o) {
    final items = (o['order_items'] as List?) ?? const [];
    if (items.isEmpty) return 0;
    final first = items.first as Map<String, dynamic>;
    return (first['count'] as num?)?.toInt() ?? items.length;
  }

  String _fmtDate(DateTime dt) {
    final l = dt.toLocal();
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    String two(int v) => v.toString().padLeft(2, '0');
    return '${months[l.month - 1]} ${l.day}, ${l.year} '
        '${two(l.hour)}:${two(l.minute)}';
  }
}