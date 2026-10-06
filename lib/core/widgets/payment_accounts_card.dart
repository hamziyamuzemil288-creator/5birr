import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../theme/app_theme.dart';

/// One provider's saved payment accounts, as read for a buyer.
///
/// [readable] is deliberately separate from "the list is empty": the read is
/// server-scoped, so a failure (no network, a deployment that has not run
/// the grant yet) is NOT evidence that the seller has no account. An empty
/// list we KNOW about blocks direct purchase and offers "Contact seller"; a
/// failed read never does, because taking away the buyer's only way to pay
/// on the strength of an error is the worse mistake.
class PaymentAccounts {
  const PaymentAccounts({required this.rows, required this.readable});

  final List<Map<String, dynamic>> rows;
  final bool readable;

  static const PaymentAccounts unreadable = PaymentAccounts(
    rows: [],
    readable: false,
  );

  bool get isEmpty => rows.isEmpty;
  bool get canPay => readable && rows.isNotEmpty;

  /// The buyer's view of one provider's accounts, through the RPC that
  /// exists exactly for this: it returns active accounts only, and only for
  /// a provider whose profile is APPROVED (or for the owner/admin).
  static Future<PaymentAccounts> load(String providerId) async {
    try {
      final rows = await Supabase.instance.client.rpc(
        'provider_payment_accounts',
        params: {'p_provider_id': providerId},
      );
      if (rows is! List) return unreadable;
      return PaymentAccounts(
        rows: List<Map<String, dynamic>>.from(rows),
        readable: true,
      );
    } catch (_) {
      return unreadable;
    }
  }
}

/// Where a buyer sees the provider's account details: on the product page
/// and again on Checkout, above the payment reference field, with a copy
/// button per value and the one instruction that matters — pay the
/// provider, then upload proof.
///
/// When the provider has saved no account, the same card says so and offers
/// "Contact seller" instead of a pay-to step the buyer could not complete.
class PaymentAccountsCard extends StatelessWidget {
  const PaymentAccountsCard({
    super.key,
    required this.accounts,
    this.providerName,
    this.onContactSeller,
    this.loading = false,
  });

  final PaymentAccounts accounts;
  final String? providerName;
  final VoidCallback? onContactSeller;
  final bool loading;

  static const String payNote =
      'Pay the provider, then upload proof of payment.';

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.cardBorder),
      ),
      child: loading
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(8),
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: AppTheme.primaryGreen),
                ),
              ),
            )
          : accounts.isEmpty
              ? _noAccount(context)
              : _accounts(context),
    );
  }

  Widget _header(BuildContext context) {
    return Row(
      children: [
        const Icon(Icons.account_balance_wallet_outlined,
            size: 18, color: AppTheme.primaryGreen),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            providerName == null || providerName!.trim().isEmpty
                ? 'Pay the provider directly'
                : 'Pay ${providerName!.trim()} directly',
            style: const TextStyle(
              fontSize: 14.5,
              fontWeight: FontWeight.w700,
              color: AppTheme.textPrimary,
            ),
          ),
        ),
      ],
    );
  }

  Widget _noAccount(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _header(context),
        const SizedBox(height: 8),
        const Text(
          'This seller has not saved a payment account yet, so there is '
          'nowhere to send money and nothing to buy here right now.',
          style: TextStyle(
            fontSize: 12.5,
            height: 1.4,
            color: AppTheme.textSecondary,
          ),
        ),
        const SizedBox(height: 10),
        if (onContactSeller != null)
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: onContactSeller,
              style: FilledButton.styleFrom(
                backgroundColor: AppTheme.primaryGreen,
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
              icon: const Icon(Icons.forum_outlined, size: 18),
              label: const Text('Contact seller'),
            ),
          ),
      ],
    );
  }

  Widget _accounts(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _header(context),
        const SizedBox(height: 10),
        for (final row in accounts.rows) ...[
          _accountRow(context, row),
          const SizedBox(height: 8),
        ],
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: AppTheme.primaryGreen.withOpacity(0.07),
            borderRadius: BorderRadius.circular(8),
          ),
          child: const Text(
            payNote,
            style: TextStyle(
              fontSize: 12.5,
              height: 1.4,
              fontWeight: FontWeight.w600,
              color: AppTheme.textPrimary,
            ),
          ),
        ),
      ],
    );
  }

  Widget _accountRow(BuildContext context, Map<String, dynamic> row) {
    final name = (row['name'] as String?)?.trim() ?? '';
    final holder = (row['account_name'] as String?)?.trim() ?? '';
    final number = (row['account_number'] as String?)?.trim() ?? '';
    final instructions = (row['instructions'] as String?)?.trim() ?? '';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.creamDark,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.cardBorder, width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (name.isNotEmpty)
            Text(
              name,
              style: const TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w700,
                color: AppTheme.textPrimary,
              ),
            ),
          if (holder.isNotEmpty) ...[
            const SizedBox(height: 6),
            _valueLine(
              context,
              label: 'Account holder',
              value: holder,
            ),
          ],
          if (number.isNotEmpty) ...[
            const SizedBox(height: 6),
            _valueLine(
              context,
              label: 'Account number',
              value: number,
            ),
          ],
          if (instructions.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              instructions,
              style: const TextStyle(
                fontSize: 12,
                height: 1.35,
                color: AppTheme.textSecondary,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _valueLine(
    BuildContext context, {
    required String label,
    required String value,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: const TextStyle(
                  fontSize: 11,
                  color: AppTheme.textMuted,
                ),
              ),
              const SizedBox(height: 1),
              SelectableText(
                value,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: AppTheme.textPrimary,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        TextButton.icon(
          onPressed: () => _copy(context, value, label),
          icon: const Icon(Icons.copy_rounded, size: 15),
          label: const Text('Copy'),
          style: TextButton.styleFrom(
            foregroundColor: AppTheme.primaryGreen,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            minimumSize: const Size(0, 36),
            textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
          ),
        ),
      ],
    );
  }

  void _copy(BuildContext context, String value, String label) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('$label copied'),
        duration: const Duration(seconds: 2),
      ),
    );
  }
}
