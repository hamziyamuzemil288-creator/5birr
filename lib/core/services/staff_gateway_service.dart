import 'package:realtime_client/realtime_client.dart';
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

  /// Live updates for the task feed.
  ///
  /// WHY A CHANNEL AND NOT A POLL
  /// ---------------------------
  /// staff_task_feed() is derived from five tables, all of which migration
  /// 20260927000033 put in the supabase_realtime publication. Subscribing to
  /// them means the moment work lands in this person's queue the card is
  /// already on screen, which is the whole point — a staff member watching the
  /// screen used to see nothing until they remembered the refresh button.
  ///
  /// Polling would look identical from the outside and cost a request every few
  /// seconds forever, on a screen people leave open all day.
  ///
  /// `onChange` fires for any row-level event on any of the five tables. It
  /// deliberately does NOT try to patch the list from the payload: the feed is
  /// a UNION across five sources with permission and category scoping applied
  /// in SQL, so the only correct answer to "something changed" is to re-ask
  /// the database. A partial patch computed in Dart is how the list and the
  /// server drift apart.
  RealtimeChannel subscribeToTaskFeed(void Function() onChange) {
    final client = Supabase.instance.client;
    // onPostgresChanges takes ONE table per call, so the channel is built by
    // chaining. An unknown table name in this list fails the whole channel
    // silently — which is why assert_staff_task_sources_are_live exists in CI
    // to fail the build instead of shipping a screen that never updates.
    var channel = client.channel('staff-task-feed');
    for (final table in const [
      'approval_requests',
      'support_tickets',
      'appeal_cases',
      'wallet_recharge_requests',
      'payment_proofs',
    ]) {
      channel = channel.onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: table,
        callback: (_) => onChange(),
      );
    }
    return channel;
  }

  /// Sends a warning to a staff member. CEO / Super Admin only, server-side.
  Future<void> warn({
    required String staffId,
    required String reason,
    String severity = 'WARNING',
  }) async {
    try {
      await Supabase.instance.client.rpc(
        'warn_staff',
        params: {
          'p_staff_id': staffId,
          'p_reason': reason,
          'p_severity': severity,
        },
      );
    } catch (e) {
      // PostgREST raises, so the stable RAISE code is inside the message text.
      // Mapping it here is what turns "PostgrestException(code: P0001, ...)"
      // into something a manager can act on.
      final raw = e.toString();
      for (final code in const [
        'ONLY_ADMINISTRATORS_CAN_WARN_STAFF',
        'WARNING_REASON_REQUIRED',
        'INVALID_WARNING_SEVERITY',
        'STAFF_NOT_FOUND_OR_INACTIVE',
        'CANNOT_WARN_THE_CEO',
      ]) {
        if (raw.contains(code)) throw Exception(_describeWarnError(code));
      }
      rethrow;
    }
  }

  /// Every active staff member with their open-warning count, worst first.
  Future<List<Map<String, dynamic>>> warningSummary() async {
    final rows = await Supabase.instance.client.rpc('staff_warning_summary');
    return (rows as List)
        .map((r) => Map<String, dynamic>.from(r as Map))
        .toList();
  }

  /// Warnings addressed to the signed-in staff member, newest first.
  Future<List<Map<String, dynamic>>> myWarnings() async {
    final uid = Supabase.instance.client.auth.currentUser?.id;
    if (uid == null) return const [];
    final rows = await Supabase.instance.client
        .from('staff_warnings')
        .select('id, reason, severity, warned_by_name, created_at, '
            'acknowledged_at, acknowledged_note')
        .order('created_at', descending: true)
        .limit(20);
    return (rows as List)
        .map((r) => Map<String, dynamic>.from(r as Map))
        .toList();
  }

  /// Marks a warning as seen. Only the person it was sent to can do this —
  /// server-side, because a manager clicking it would make the timestamp prove
  /// nothing.
  Future<void> acknowledge(String warningId, {String? note}) async {
    await Supabase.instance.client.rpc(
      'acknowledge_staff_warning',
      params: {'p_warning_id': warningId, 'p_note': note},
    );
  }

  String _describeWarnError(String code) {
    switch (code) {
      case 'ONLY_ADMINISTRATORS_CAN_WARN_STAFF':
        return 'Only the CEO or a super admin can send warnings.';
      case 'WARNING_REASON_REQUIRED':
        return 'Write what the problem is — a warning with no reason is not a '
            'warning.';
      case 'INVALID_WARNING_SEVERITY':
        return 'Pick either a warning or a serious warning.';
      case 'STAFF_NOT_FOUND_OR_INACTIVE':
        return 'That staff member no longer exists, or their access is already '
            'revoked.';
      case 'CANNOT_WARN_THE_CEO':
        return 'The CEO account cannot be sent warnings.';
      default:
        return 'Could not send the warning.';
    }
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
