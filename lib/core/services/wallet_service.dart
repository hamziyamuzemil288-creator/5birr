import 'dart:io';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:storage_client/storage_client.dart' show FileOptions;

class WalletService {
  WalletService._();
  static final instance = WalletService._();
  final _client = Supabase.instance.client;

  /// Get wallet for a provider.
  Future<Map<String, dynamic>?> getWallet(String providerId) async {
    final data = await _client
        .from('wallets')
        .select()
        .eq('provider_id', providerId)
        .maybeSingle();
    return data;
  }

  /// Get current user's wallet.
  Future<Map<String, dynamic>?> getMyWallet() async {
    final userId = _client.auth.currentUser?.id;
    if (userId == null) return null;
    final prov = await _client
        .from('provider_profiles')
        .select('id')
        .eq('user_id', userId)
        .maybeSingle();
    if (prov == null) return null;
    return getWallet(prov['id']);
  }

  /// Get wallet transactions.
  Future<List<Map<String, dynamic>>> getTransactions({
    required String providerId,
    String? type,
    int limit = 50,
    int offset = 0,
  }) async {
    var q = _client
        .from('wallet_transactions')
        .select()
        .eq('provider_id', providerId);
    if (type != null) q = q.eq('transaction_type', type);
    final data = await q
        .order('created_at', ascending: false)
        .range(offset, offset + limit - 1);
    return List<Map<String, dynamic>>.from(data as List);
  }

  /// Get my wallet transactions.
  Future<List<Map<String, dynamic>>> getMyTransactions({
    String? type,
    int limit = 50,
    int offset = 0,
  }) async {
    final userId = _client.auth.currentUser?.id;
    if (userId == null) return [];
    final prov = await _client
        .from('provider_profiles')
        .select('id')
        .eq('user_id', userId)
        .maybeSingle();
    if (prov == null) return [];
    return getTransactions(
        providerId: prov['id'], type: type, limit: limit, offset: offset);
  }

  /// Submit a wallet-funding request from one of the provider's OWN payment
  /// methods. The wallet is credited only when an admin approves the request
  /// (see `approve_wallet_recharge`). This is deliberately NOT credited on
  /// submit.
  //
  // Uses the RPC `submit_provider_wallet_funding` (not a direct insert) so
  // the server can verify that the chosen payment method actually belongs to
  // this provider and is active. A direct insert through RLS would only check
  // that the provider owns the request's provider_id, not that they own the
  // payment method they named.
  Future<Map<String, dynamic>> submitProviderWalletFundingRequest({
    required String providerId,
    required String walletId,
    required String paymentMethodId,
    required double amount,
    String? paymentReference,
    String? screenshotStoragePath,
  }) async {
    final data = await _client.rpc('submit_provider_wallet_funding', params: {
      'p_provider_id': providerId,
      'p_wallet_id': walletId,
      'p_payment_method_id': paymentMethodId,
      'p_amount': amount,
      'p_payment_reference': paymentReference,
      'p_screenshot_storage_path': screenshotStoragePath,
    });
    return data as Map<String, dynamic>;
  }

  /// Submit a recharge request.
  Future<Map<String, dynamic>> submitRecharge({
    required String providerId,
    required String walletId,
    required String paymentMethodId,
    required double amount,
    String? paymentReference,
    String? screenshotPath,
  }) async {
    final data = await _client
        .from('wallet_recharge_requests')
        .insert({
          'provider_id': providerId,
          'wallet_id': walletId,
          'payment_method_id': paymentMethodId,
          'amount': amount,
          'payment_reference': paymentReference,
          'screenshot_storage_path': screenshotPath,
        })
        .select()
        .single();
    return data;
  }

  /// Get provider-funded recharge requests that have not yet been approved
  /// or rejected. Used by the provider's own payment-methods screen to show
  /// what they have submitted toward their wallet.
  Future<List<Map<String, dynamic>>> getMyProviderWalletFundingRequests() async {
    final userId = _client.auth.currentUser?.id;
    if (userId == null) return [];
    final prov = await _client
        .from('provider_profiles')
        .select('id')
        .eq('user_id', userId)
        .maybeSingle();
    if (prov == null) return [];
    final providerId = prov['id'] as String;
    return _getProviderWalletFundingRequests(providerId);
  }

  /// Get every wallet-funding request from a provider's own payment methods,
  /// as the provider would see it.
  Future<List<Map<String, dynamic>>> _getProviderWalletFundingRequests(
      String providerId) async {
    final data = await _client
        .from('wallet_recharge_requests')
        .select('*, payment_methods(name)')
        .eq('provider_id', providerId)
        .eq('source', 'PROVIDER_PAYMENT_METHOD')
        .order('created_at', ascending: false);
    return List<Map<String, dynamic>>.from(data as List);
  }

  /// Get my recharge requests.
  Future<List<Map<String, dynamic>>> getMyRechargeRequests() async {
    final userId = _client.auth.currentUser?.id;
    if (userId == null) return [];
    final prov = await _client
        .from('provider_profiles')
        .select('id')
        .eq('user_id', userId)
        .maybeSingle();
    if (prov == null) return [];
    final providerId = prov['id'] as String;
    final data = await _client
        .from('wallet_recharge_requests')
        .select('*, payment_methods(name)')
        .eq('provider_id', providerId)
        .order('created_at', ascending: false);
    return List<Map<String, dynamic>>.from(data as List);
  }

  /// The provider's own provider-funded wallet-funding requests, as returned
  /// by `provider_wallet_funding_summary(provider_id)`.
  ///
  /// This is the authoritative read for the provider's "awaiting admin review"
  /// list: it returns the payment-method name alongside each request, and it
  /// is provider-scoped (the RPC refuses a non-owner).
  Future<List<Map<String, dynamic>>> getMyWalletFundingSummary() async {
    final userId = _client.auth.currentUser?.id;
    if (userId == null) return [];
    final prov = await _client
        .from('provider_profiles')
        .select('id')
        .eq('user_id', userId)
        .maybeSingle();
    if (prov == null) return [];
    final providerId = prov['id'] as String;
    return getProviderWalletFundingSummary(providerId);
  }

  /// Provider-scoped funding-summary read.
  Future<List<Map<String, dynamic>>> getProviderWalletFundingSummary(
      String providerId) async {
    final data = await _client
        .rpc('provider_wallet_funding_summary', params: {'p_provider_id': providerId});
    return List<Map<String, dynamic>>.from(data as List);
  }

  /// Upload payment screenshot.
  ///
  /// `payment-screenshots` is capped at 5MB and accepts image/jpeg, png and
  /// webp only (migration 20260927000096). The size is checked HERE rather
  /// than left to storage, because storage's refusal arrives as a raw
  /// InvalidPayload the caller has to decode; a caller that forgets to
  /// downscale — which is exactly what the recharge screen did — gets a
  /// sentence instead of a driver string. The mime types cannot be checked
  /// without sniffing content, which is why every picker in this app
  /// re-encodes to JPEG with maxWidth/maxHeight instead.
  Future<String> uploadScreenshot(String filePath, String providerId) async {
    // Path convention MUST start with the caller's auth uid, with NO bucket
    // prefix: storage policies match the object NAME inside the bucket, and
    // the 'payment-screenshots' INSERT policy (0033) only allows
    // name LIKE auth.uid() || '/%'. Keeping 'payment-screenshots/' in the
    // path put the bucket name inside the object name, which failed that
    // check with StorageException 403 (row-level security).
    final uid = _client.auth.currentUser?.id;
    if (uid == null) {
      throw Exception('Not authenticated — cannot upload payment screenshot');
    }
    final fileName =
        '${providerId}_${DateTime.now().millisecondsSinceEpoch}.jpg';
    final path = '$uid/$fileName';
    final file = File(filePath);
    // 5MB, the bucket's file_size_limit. Checked before the upload so the
    // failure names the limit instead of surfacing as an HTTP error.
    if (file.existsSync() && await file.length() > 5 * 1024 * 1024) {
      throw Exception(
          'PAYMENT_SCREENSHOT_TOO_LARGE: the screenshot must be under 5 MB');
    }
    await _client.storage.from('payment-screenshots').upload(
        path, file,
        fileOptions: const FileOptions(upsert: true));
    return path;
  }

  /// Get signed URL for payment screenshot.
  Future<String> getScreenshotUrl(String path) async {
    return _client.storage
        .from('payment-screenshots')
        .createSignedUrl(path, 3600);
  }

  /// Get low balance threshold from system settings.
  Future<double> getLowBalanceThreshold() async {
    final data = await _client
        .from('system_settings')
        .select('value')
        .eq('key', 'low_wallet_threshold')
        .single();
    return (data['value'] as num).toDouble();
  }
}
