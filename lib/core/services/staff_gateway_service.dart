import 'package:supabase_flutter/supabase_flutter.dart';

class StaffGatewayService {
  const StaffGatewayService();

  Future<void> signIn({
    required String username,
    required String password,
  }) async {
    final client = Supabase.instance.client;
    final response = await client.functions.invoke(
      'staff-login',
      body: {'username': username.trim().toLowerCase(), 'password': password},
    );
    if (response.status != 200) {
      final data = response.data is Map ? response.data as Map : const {};
      throw Exception(data['error'] ?? 'invalid_credentials');
    }
    final data = Map<String, dynamic>.from(response.data as Map);
    final accessToken = data['access_token'] as String?;
    final refreshToken = data['refresh_token'] as String?;
    if (accessToken == null || refreshToken == null) {
      throw Exception('invalid_session');
    }
    await client.auth.setSession(refreshToken, accessToken: accessToken);
  }

  Future<List<Map<String, dynamic>>> taskFeed() async {
    final rows = await Supabase.instance.client.rpc('staff_task_feed');
    return (rows as List)
        .map((row) => Map<String, dynamic>.from(row as Map))
        .toList();
  }

  Future<void> markDone(String taskKey) async {
    await Supabase.instance.client.rpc(
      'staff_mark_task_done',
      params: {'p_task_key': taskKey},
    );
  }

  Future<Map<String, dynamic>> progress() async {
    final rows = await Supabase.instance.client.rpc('staff_progress');
    if ((rows as List).isEmpty) return const {};
    return Map<String, dynamic>.from(rows.first as Map);
  }

  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    final response = await Supabase.instance.client.functions.invoke(
      'staff-change-password',
      body: {
        'current_password': currentPassword,
        'new_password': newPassword,
      },
    );
    if (response.status != 200) {
      final data = response.data is Map ? response.data as Map : const {};
      throw Exception(data['error'] ?? 'password_change_failed');
    }
  }
}
