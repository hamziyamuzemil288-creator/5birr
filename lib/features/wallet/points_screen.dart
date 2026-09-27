import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/services/points_service.dart';
import '../../core/services/rank_service.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/friendly_error.dart';
import '../../core/widgets/birr_text_field.dart';
import '../../core/widgets/load_error_view.dart';
import '../../core/widgets/primary_button.dart';
import '../../core/widgets/rank_badge.dart';

/// One balance of points, and whether it can be spent yet.
class _Balance {
  final String subjectType;
  final String label;
  final String? subjectId;
  final int points;
  final RankProgress? progress;
  final bool convertible;
  final String? blockedReason;

  const _Balance({
    required this.subjectType,
    required this.label,
    this.subjectId,
    this.points = 0,
    this.progress,
    this.convertible = false,
    this.blockedReason,
  });
}

/// Points, rank and the conversion into wallet credit.
///
/// The two balances are shown separately because they are genuinely separate:
/// points earned as a customer (USER) and points earned as a business
/// (PROVIDER) are different subjects in the ledger. A wallet belongs to a
/// provider profile, so conversion credits that wallet — an account with no
/// provider profile sees why it cannot convert yet rather than a button that
/// fails.
class PointsScreen extends StatefulWidget {
  const PointsScreen({super.key});

  @override
  State<PointsScreen> createState() => _PointsScreenState();
}

class _PointsScreenState extends State<PointsScreen> {
  List<_Balance> _balances = [];
  List<Map<String, dynamic>> _ledger = [];
  List<RankTier> _ladder = [];
  String? _providerId;
  bool _loading = true;
  String? _error;
  String? _expanded = 'USER';
  bool _converting = false;

  double _rate = 0;
  int _minimum = 0;

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
      final client = Supabase.instance.client;
      final userId = client.auth.currentUser?.id;
      if (userId == null) {
        if (mounted) {
          setState(() {
            _loading = false;
            _error = 'You need to be signed in to see your points.';
          });
        }
        return;
      }

      // Business rules, read live: the CEO can change the rate or the minimum
      // from the admin settings screen and this screen reflects it without an
      // app release.
      final rateRow = await client
          .from('system_settings')
          .select('key, value')
          .inFilter('key', ['points_to_birr_rate', 'points_conversion_minimum']);
      for (final row in rateRow as List) {
        final value = (row['value'] as num?)?.toDouble();
        if (row['key'] == 'points_to_birr_rate') _rate = value ?? 0;
        if (row['key'] == 'points_conversion_minimum') {
          _minimum = value?.toInt() ?? 0;
        }
      }

      final ladder = await RankService.instance.tiers();
      final providerId = await PointsService.instance.currentProviderProfileId();

      final personal = await PointsService.instance.getMyPoints();
      var business = 0;
      if (providerId != null) {
        business = await PointsService.instance.getProviderPoints(providerId);
      }

      final balances = <_Balance>[
        _Balance(
          subjectType: 'USER',
          label: 'Personal',
          subjectId: userId,
          points: personal,
          progress: RankService.instance.progressFor(personal, ladder),
          convertible: providerId != null,
          blockedReason: providerId == null
              ? 'Convert once you have a business account'
              : null,
        ),
        if (providerId != null)
          _Balance(
            subjectType: 'PROVIDER',
            label: 'Business',
            subjectId: providerId,
            points: business,
            progress: RankService.instance.progressFor(business, ladder),
            convertible: true,
          ),
      ];

      final ledgerSubject = _expanded == 'PROVIDER' && providerId != null
          ? providerId
          : userId;
      final ledger = await PointsService.instance.getLedger(
        subjectType: _expanded == 'PROVIDER' && providerId != null
            ? 'PROVIDER'
            : 'USER',
        subjectId: ledgerSubject,
      );

      if (mounted) {
        setState(() {
          _providerId = providerId;
          _ladder = ladder;
          _balances = balances;
          _ledger = ledger;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = friendlyError(e, context: 'Could not load your points');
        });
      }
    }
  }

  Future<void> _reloadLedger(String subjectType) async {
    final userId = Supabase.instance.client.auth.currentUser?.id;
    final subjectId = subjectType == 'PROVIDER' ? _providerId : userId;
    if (subjectId == null) return;
    try {
      final rows = await PointsService.instance.getLedger(
        subjectType: subjectType,
        subjectId: subjectId,
      );
      if (mounted) setState(() => _ledger = rows);
    } catch (_) {
      // The list is supplementary; the balances above already loaded.
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Points & Rank')),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: AppTheme.primaryGreen))
          : _error != null
              ? LoadErrorView(message: _error!, onRetry: _load)
              : RefreshIndicator(
                  onRefresh: _load,
                  color: AppTheme.primaryGreen,
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      for (final balance in _balances) ...[
                        _balanceCard(balance),
                        const SizedBox(height: 12),
                      ],
                      if (_providerId == null) _noWalletNote(),
                      const SizedBox(height: 4),
                      _sectionTitle('Recent points activity'),
                      const SizedBox(height: 8),
                      _ledgerList(),
                      const SizedBox(height: 20),
                      _sectionTitle('Ranks'),
                      const SizedBox(height: 4),
                      const Text(
                        'Ranks are a trust signal — they unlock nothing and '
                        'restrict nothing.',
                        style: TextStyle(
                            fontSize: 12, color: AppTheme.textMuted),
                      ),
                      const SizedBox(height: 10),
                      _ladderList(),
                    ],
                  ),
                ),
    );
  }

  Widget _sectionTitle(String text) => Text(
        text,
        style: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w700,
            color: AppTheme.textPrimary),
      );

  Widget _balanceCard(_Balance balance) {
    final isExpanded = _expanded == balance.subjectType;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        RankProgressCard(
          points: balance.points,
          progress: balance.progress,
          subjectLabel: balance.label,
          onTap: () {
            setState(() => _expanded = balance.subjectType);
            _reloadLedger(balance.subjectType);
          },
        ),
        const SizedBox(height: 8),
        if (balance.convertible)
          PrimaryButton(
            label: 'Convert points to wallet',
            icon: Icons.swap_horiz_rounded,
            isOutlined: true,
            onPressed: _converting ? null : () => _openConvertDialog(balance),
          )
        else
          Row(
            children: [
              const Icon(Icons.info_outline,
                  size: 15, color: AppTheme.textMuted),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  balance.blockedReason ??
                      'This balance cannot be converted yet.',
                  style: const TextStyle(
                      fontSize: 12, color: AppTheme.textMuted),
                ),
              ),
              TextButton(
                onPressed: () => context.push('/become-partner'),
                child: const Text('Become a Partner'),
              ),
            ],
          ),
        if (isExpanded && _balances.length > 1)
          const Padding(
            padding: EdgeInsets.only(top: 4),
            child: Text('Showing this balance in the activity below',
                style: TextStyle(fontSize: 11, color: AppTheme.textMuted)),
          ),
      ],
    );
  }

  Widget _noWalletNote() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.warning.withOpacity(0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.warning.withOpacity(0.3)),
      ),
      child: const Text(
        'Points convert into wallet credit, and a wallet belongs to a '
        'business account. Your points keep accruing until you have one.',
        style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
      ),
    );
  }

  Widget _ledgerList() {
    if (_ledger.isEmpty) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppTheme.surfaceVariant,
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Text(
          'No points yet. Complete an order or a ride to start earning.',
          style: TextStyle(fontSize: 13, color: AppTheme.textMuted),
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.cardBorder),
      ),
      child: Column(
        children: [
          for (var i = 0; i < _ledger.length; i++) ...[
            if (i > 0) const Divider(height: 1, color: AppTheme.cardBorder),
            _ledgerRow(_ledger[i]),
          ],
        ],
      ),
    );
  }

  Widget _ledgerRow(Map<String, dynamic> row) {
    final points = (row['points'] as num?)?.toInt() ?? 0;
    final earned = points > 0;
    final createdAt = row['created_at'] != null
        ? DateTime.tryParse(row['created_at'] as String)
        : null;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          Icon(
            earned ? Icons.add_circle_outline : Icons.remove_circle_outline,
            size: 18,
            color: earned ? AppTheme.success : AppTheme.textMuted,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  (row['reason'] as String?)?.trim().isNotEmpty == true
                      ? row['reason'] as String
                      : (row['source_type'] as String? ?? 'Points'),
                  style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.textPrimary),
                ),
                if (createdAt != null)
                  Text(
                    DateFormat('d MMM yyyy').format(createdAt.toLocal()),
                    style: const TextStyle(
                        fontSize: 11, color: AppTheme.textMuted),
                  ),
              ],
            ),
          ),
          Text(
            '${earned ? '+' : ''}${NumberFormat.decimalPattern().format(points)}',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: earned ? AppTheme.success : AppTheme.textSecondary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _ladderList() {
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.cardBorder),
      ),
      child: Column(
        children: [
          for (var i = 0; i < _ladder.length; i++) ...[
            if (i > 0) const Divider(height: 1, color: AppTheme.cardBorder),
            _ladderRow(_ladder[i]),
          ],
        ],
      ),
    );
  }

  Widget _ladderRow(RankTier tier) {
    final isCurrent = _balances.isNotEmpty &&
        _balances.any((b) => b.progress?.current?.code == tier.code);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: tier.color.withOpacity(0.14),
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.workspace_premium_rounded,
                size: 17, color: tier.color),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              tier.name,
              style: TextStyle(
                fontSize: 14,
                fontWeight: isCurrent ? FontWeight.w700 : FontWeight.w600,
                color: AppTheme.textPrimary,
              ),
            ),
          ),
          Text(
            '${NumberFormat.decimalPattern().format(tier.minPoints)} pts',
            style: const TextStyle(fontSize: 12, color: AppTheme.textMuted),
          ),
          if (isCurrent) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: tier.color.withOpacity(0.12),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text('You',
                  style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      color: tier.color)),
            ),
          ],
        ],
      ),
    );
  }

  /// The conversion dialog.
  ///
  /// It shows the birr the points are worth at the current rate as a
  /// convenience, but the amount that actually lands is the one the server
  /// computes — the client never sends it.
  Future<void> _openConvertDialog(_Balance balance) async {
    final controller = TextEditingController();
    final formKey = GlobalKey<FormState>();
    final maxPoints = balance.points;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text('Convert ${balance.label.toLowerCase()} points'),
          content: Form(
            key: formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'You have ${NumberFormat.decimalPattern().format(maxPoints)} '
                  'points. Each one is worth '
                  '${_rate.toStringAsFixed(4)} ETB at the current rate.',
                  style: const TextStyle(fontSize: 12),
                ),
                const SizedBox(height: 12),
                BirrTextField(
                  label: 'Points to convert',
                  hint: _minimum > 0 ? 'Minimum $_minimum' : 'e.g. 500',
                  controller: controller,
                  keyboardType: TextInputType.number,
                  validator: (value) {
                    final parsed = int.tryParse((value ?? '').trim());
                    if (parsed == null || parsed <= 0) {
                      return 'Enter how many points to convert';
                    }
                    if (_minimum > 0 && parsed < _minimum) {
                      return 'The minimum is $_minimum points';
                    }
                    if (parsed > maxPoints) {
                      return 'You only have $maxPoints points';
                    }
                    if ((parsed * _rate) < 0.01) {
                      return 'That rounds to less than 0.01 ETB';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 8),
                const Text(
                  'The wallet credit is calculated on the server from the '
                  'current rate.',
                  style: TextStyle(fontSize: 11, color: AppTheme.textMuted),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () {
                if (formKey.currentState?.validate() ?? false) {
                  Navigator.of(dialogContext).pop(true);
                }
              },
              child: const Text('Convert'),
            ),
          ],
        );
      },
    );

    if (confirmed != true) return;

    final points = int.tryParse(controller.text.trim()) ?? 0;
    if (points <= 0) return;

    setState(() => _converting = true);
    try {
      final result = await PointsService.instance.convertToWallet(
        subjectType: balance.subjectType,
        points: points,
        providerId: _providerId,
      );
      if (!mounted) return;
      final credited = (result['birr_credited'] as num?)?.toDouble() ?? 0;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
            '${NumberFormat.decimalPattern().format(points)} points converted — '
            '${credited.toStringAsFixed(2)} ETB added to your wallet.'),
        backgroundColor: AppTheme.success,
      ));
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(friendlyError(e, context: 'Could not convert your points')),
        backgroundColor: AppTheme.error,
      ));
    } finally {
      if (mounted) setState(() => _converting = false);
    }
  }
}
