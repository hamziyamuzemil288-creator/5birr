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

  /// Permanently remove a staff member: the staff row, everything cascading
  /// off it, and their auth account.
  ///
  /// Goes through the Edge Function rather than a direct RPC because the RPC
  /// is service_role-only and because deleting an auth.users row needs a
  /// privilege a client must never hold.
  ///
  /// This is NOT [revokeStaff]'s safe counterpart — prefer revoking unless
  /// the person is genuinely being removed. Throws with a readable message so
  /// the caller can show it verbatim.
  Future<void> deletePermanently(String staffId) async {
    final response = await Supabase.instance.client.functions.invoke(
      'staff-delete-gateway',
      body: {'staff_id': staffId},
    );
    if (response.status != 200) {
      final data = response.data is Map ? response.data as Map : const {};
      final code = data['error'] as String? ?? 'delete_failed';
      throw Exception(_describeDeleteError(code));
    }
  }

  String _describeDeleteError(String code) {
    switch (code) {
      case 'cannot_delete_ceo':
        return 'The CEO account cannot be deleted.';
      case 'only_ceo_can_delete_staff':
        return 'Only the CEO can delete a staff member.';
      case 'staff_not_found':
        return 'That staff member no longer exists.';
      case 'auth_user_delete_failed':
        // The staff record is already gone; only the login lingers.
        return 'The staff record was deleted, but their login could not be '
            'removed. It can be cleaned up in the Supabase dashboard.';
      default:
        return 'Could not delete the staff member. Please try again.';
    }
  }
}
