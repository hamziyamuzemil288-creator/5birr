import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/friendly_error.dart';
import '../../core/widgets/load_error_view.dart';

/// The slips for one order or one ride.
///
/// `transaction_documents` is written by a trigger on the status-history
/// tables, so this list is not assembled from anything the client did: every
/// status change the platform allowed produced one of these, with both
/// parties' names and phone numbers as they were at the moment, the amount,
/// and the platform fee read from the ledger rather than recomputed.
///
/// Shown to the two parties and to administrators, and to nobody else — the
/// server decides, and it says yes only when the caller is the customer, the
/// provider, or an admin.
class TransactionDocumentsScreen extends StatefulWidget {
  const TransactionDocumentsScreen({
    super.key,
    required this.subjectType,
    required this.subjectId,
    this.title = 'Documents',
  });

  /// 'ORDER' or 'RIDE'.
  final String subjectType;
  final String subjectId;
  final String title;

  @override
  State<TransactionDocumentsScreen> createState() =>
      _TransactionDocumentsScreenState();
}

class _TransactionDocumentsScreenState
    extends State<TransactionDocumentsScreen> {
  List<Map<String, dynamic>> _docs = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final rows = await Supabase.instance.client.rpc(
        'my_transaction_documents',
        params: {
          'p_subject_type': widget.subjectType,
          'p_subject_id': widget.subjectId,
          'p_limit': 200,
        },
      );
      if (!mounted) return;
      setState(() {
        _docs = List<Map<String, dynamic>>.from(rows as List);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = friendlyError(e, context: 'Could not load the documents');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          IconButton(
            tooltip: 'Reload',
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: AppTheme.primaryGreen))
          : _error != null
              ? LoadErrorView(message: _error!, onRetry: _load)
              : _docs.isEmpty
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(32),
                        child: Text(
                          'No documents yet. A slip is written every time this '
                          'transaction changes state.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              fontSize: 13, color: AppTheme.textMuted),
                        ),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
                      itemCount: _docs.length,
                      itemBuilder: (_, i) => Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: _card(_docs[i]),
                      ),
                    ),
    );
  }

  Widget _card(Map<String, dynamic> d) {
    final snapshot =
        (d['subject_snapshot'] as Map?)?.cast<String, dynamic>() ?? const {};
    final total = _num(d['total']);
    final fee = _num(d['platform_fee']);
    final issued = (d['issued_at'] as String? ?? '').replaceAll('T', ' ');

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: AppTheme.primaryGreen.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  d['scenario'] as String? ?? '',
                  style: const TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.primaryGreenDark,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  d['document_number'] as String? ?? '',
                  style: const TextStyle(
                      fontSize: 11.5, color: AppTheme.textMuted),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _party('Customer', d['customer_name'], d['customer_phone']),
          _party('Provider', d['provider_name'], d['provider_phone']),
          if ((d['city'] as String? ?? '').isNotEmpty)
            _line('City', d['city'] as String),
          if ((snapshot['pickup_text'] as String? ?? '').isNotEmpty)
            _line('Pickup', snapshot['pickup_text'] as String),
          if ((snapshot['destination_text'] as String? ?? '').isNotEmpty)
            _line('Destination', snapshot['destination_text'] as String),
          if ((snapshot['note'] as String? ?? '').isNotEmpty)
            _line('Note', snapshot['note'] as String),
          const Divider(height: 18),
          Row(
            children: [
              _money('Total', total, AppTheme.textPrimary, bold: true),
              const SizedBox(width: 18),
              _money('Platform fee', fee, AppTheme.textMuted),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'issued ${issued.substring(0, issued.length < 16 ? issued.length : 16)}',
            style: const TextStyle(fontSize: 10.5, color: AppTheme.textMuted),
          ),
        ],
      ),
    );
  }

  Widget _party(String label, Object? name, Object? phone) {
    final n = (name as String? ?? '').trim();
    final p = (phone as String? ?? '').trim();
    if (n.isEmpty && p.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 68,
            child: Text(label,
                style: const TextStyle(fontSize: 11, color: AppTheme.textMuted)),
          ),
          Expanded(
            child: Text(
              p.isEmpty ? n : '$n · $p',
              style: const TextStyle(fontSize: 12.5),
            ),
          ),
        ],
      ),
    );
  }

  Widget _line(String label, String value) {
    if (value.trim().isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 68,
            child: Text(label,
                style: const TextStyle(fontSize: 11, color: AppTheme.textMuted)),
          ),
          Expanded(
            child: Text(value, style: const TextStyle(fontSize: 12.5)),
          ),
        ],
      ),
    );
  }

  Widget _money(String label, double value, Color color, {bool bold = false}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: const TextStyle(fontSize: 10.5, color: AppTheme.textMuted)),
        Text(
          'ETB ${value.toStringAsFixed(2)}',
          style: TextStyle(
            fontSize: bold ? 15 : 12.5,
            fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
            color: color,
          ),
        ),
      ],
    );
  }

  /// PostgREST returns a JSON number as int when it has no fractional part, so
  /// this is a `num` -- and `toStringAsFixed` is on `double`, not `num`.
  static double _num(Object? v) => v is num ? v.toDouble() : 0;
}