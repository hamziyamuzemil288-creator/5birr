import 'package:supabase_flutter/supabase_flutter.dart';

class PaymentMethodsService {
  PaymentMethodsService._();
  static final instance = PaymentMethodsService._();
  final _client = Supabase.instance.client;

  /// Every call this screen makes is bounded.
  ///
  /// The endless spinner this screen had was this file: four sequential
  /// reads with no deadline, one of them per-row screenshot signing — on a
  /// flaky connection any of them could hang forever and the screen would
  /// sit on its spinner with no error, no code and no retry. A timeout
  /// turns "hangs" into an error state the screen already knows how to
  /// render.
  static const Duration kTimeout = Duration(seconds: 12);

  /// Get provider payment methods (self-service).
  Future<List<Map<String, dynamic>>> getProviderMethods(String providerId) async {
    final data = await _client
        .from('provider_payment_methods')
        .select()
        .eq('provider_id', providerId)
        .order('sort_order')
        .timeout(kTimeout);
    return List<Map<String, dynamic>>.from(data as List);
  }

  /// The admin-editable banks table — the only place account-number length
  /// and prefix rules live.
  Future<List<Map<String, dynamic>>> getBanks() async {
    final data = await _client
        .from('banks')
        .select()
        .order('name')
        .timeout(kTimeout);
    return List<Map<String, dynamic>>.from(data as List);
  }

  /// Create a provider payment method.
  Future<Map<String, dynamic>> createProviderMethod({
    required String name,
    String? accountName,
    String? accountNumber,
    String? instructions,
    required String providerId,
    String? bankId,
    bool isDefault = false,
    int sortOrder = 0,
  }) async {
    final data = await _client.from('provider_payment_methods').insert({
      'name': name,
      'account_name': accountName,
      'account_number': accountNumber,
      'instructions': instructions,
      'provider_id': providerId,
      'bank_id': bankId,
      'is_default': isDefault,
      'sort_order': sortOrder,
      'created_by': _client.auth.currentUser?.id,
    }).select()
        .single()
        .timeout(kTimeout);
    return data;
  }

  /// Update a provider payment method.
  Future<Map<String, dynamic>> updateProviderMethod({
    required String id,
    String? name,
    String? accountName,
    String? accountNumber,
    String? instructions,
    bool? isActive,
    bool? isDefault,
    String? bankId,
    int? sortOrder,
  }) async {
    final updates = <String, dynamic>{};
    if (name != null) updates['name'] = name;
    if (accountName != null) updates['account_name'] = accountName;
    if (accountNumber != null) updates['account_number'] = accountNumber;
    if (instructions != null) updates['instructions'] = instructions;
    if (isActive != null) updates['is_active'] = isActive;
    if (isDefault != null) updates['is_default'] = isDefault;
    if (bankId != null) updates['bank_id'] = bankId;
    if (sortOrder != null) updates['sort_order'] = sortOrder;
    final data = await _client
        .from('provider_payment_methods')
        .update(updates)
        .eq('id', id)
        .select()
        .single()
        .timeout(kTimeout);
    return data;
  }

  /// Delete a provider payment method.
  Future<void> deleteProviderMethod(String id) async {
    await _client
        .from('provider_payment_methods')
        .delete()
        .eq('id', id)
        .timeout(kTimeout);
  }

  /// Get active payment methods for the platform (admin settings).
  Future<List<Map<String, dynamic>>> getActiveMethods() async {
    final data = await _client
        .from('payment_methods')
        .select()
        .eq('is_active', true)
        .order('sort_order');
    return List<Map<String, dynamic>>.from(data as List);
  }

  /// Get all payment methods (admin settings).
  Future<List<Map<String, dynamic>>> getAllMethods() async {
    final data = await _client
        .from('payment_methods')
        .select()
        .order('sort_order');
    return List<Map<String, dynamic>>.from(data as List);
  }

  /// Create payment method (admin).
  Future<Map<String, dynamic>> createMethod({
    required String name,
    String? accountName,
    String? accountNumber,
    String? instructions,
    int sortOrder = 0,
  }) async {
    final data = await _client.from('payment_methods').insert({
      'name': name,
      'account_name': accountName,
      'account_number': accountNumber,
      'instructions': instructions,
      'sort_order': sortOrder,
      'created_by': _client.auth.currentUser?.id,
    }).select().single();
    return data;
  }

  /// Update payment method (admin).
  Future<Map<String, dynamic>> updateMethod({
    required String id,
    String? name,
    String? accountName,
    String? accountNumber,
    String? instructions,
    bool? isActive,
    int? sortOrder,
  }) async {
    final updates = <String, dynamic>{};
    if (name != null) updates['name'] = name;
    if (accountName != null) updates['account_name'] = accountName;
    if (accountNumber != null) updates['account_number'] = accountNumber;
    if (instructions != null) updates['instructions'] = instructions;
    if (isActive != null) updates['is_active'] = isActive;
    if (sortOrder != null) updates['sort_order'] = sortOrder;
    final data = await _client
        .from('payment_methods')
        .update(updates)
        .eq('id', id)
        .select()
        .single();
    return data;
  }

  /// Delete payment method (admin).
  Future<void> deleteMethod(String id) async {
    await _client.from('payment_methods').delete().eq('id', id);
  }
}
