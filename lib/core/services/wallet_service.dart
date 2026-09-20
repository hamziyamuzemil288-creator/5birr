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

  /// Upload payment screenshot.
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
    await _client.storage.from('payment-screenshots').upload(
        path, File(filePath),
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
