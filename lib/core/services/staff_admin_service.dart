import 'package:supabase_flutter/supabase_flutter.dart';

class StaffAdminService {
  const StaffAdminService();

  Future<void> createGateway({
    required String name,
    required String staffCode,
    required String username,
    required String password,
    required String confirmPassword,
    required List<String> permissions,
    required double salesTarget,
    required bool isSuperAdmin,
    required String branch,
    required List<String> assignedCategories,
  }) async {
    final response = await Supabase.instance.client.functions.invoke(
      'staff-create-gateway',
      body: {
        'name': name,
        'staff_code': staffCode,
        'username': username,
        'password': password,
        'confirm_password': confirmPassword,
        'permissions': permissions,
        'sales_target': salesTarget,
        'is_super_admin': isSuperAdmin,
        'branch': branch,
        'assigned_categories': assignedCategories,
      },
    );
    if (response.status != 201) {
      final data = response.data is Map ? response.data as Map : const {};
      throw Exception(data['error'] ?? 'staff_gateway_creation_failed');
    }
  }
}
