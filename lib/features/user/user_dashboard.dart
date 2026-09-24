import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/providers/auth_provider.dart';
import '../../core/widgets/birr_bottom_nav.dart';
import '../../core/widgets/verification_notice.dart';
import 'user_home_screen.dart';
import 'user_search_screen.dart';
import 'user_orders_screen.dart';
import 'user_notifications_screen.dart';
import 'user_profile_screen.dart';

class UserDashboard extends ConsumerStatefulWidget {
  const UserDashboard({super.key});
  @override
  ConsumerState<UserDashboard> createState() => _UserDashboardState();
}

class _UserDashboardState extends ConsumerState<UserDashboard> {
  int _navIndex = 0;
  bool _initFromRoute = false;

  // Each tab gets its own Material ancestor: tabs are hosted inside an
  // IndexedStack in the Scaffold body, which does NOT provide Material —
  // and text fields (UserSearchScreen) crash without it.
  final _screens = const [
    Material(child: UserHomeScreen()),
    Material(child: UserSearchScreen()),
    Material(child: UserOrdersScreen()),
    Material(child: UserNotificationsScreen()),
    Material(child: UserProfileScreen()),
  ];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Optional ?tab=N query param lets flows (e.g. checkout success) open a
    // specific tab. Defaults to 0 (Home) for all existing navigation.
    if (!_initFromRoute) {
      _initFromRoute = true;
      final tab = GoRouterState.of(context).uri.queryParameters['tab'];
      if (tab != null) {
        final parsed = int.tryParse(tab);
        if (parsed != null && parsed >= 0 && parsed < _screens.length) {
          _navIndex = parsed;
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // Task 13 item 3: brief non-blocking "Verify your account" notice
      // after registration (auto-dismisses; the persistent menu entry lives
      // in Profile → Verify Document). Pure UI — the Task 9 gate is
      // untouched and still sits on the first protected action.
      body: Column(
        children: [
          const VerificationNotice(),
          Expanded(
            child: IndexedStack(index: _navIndex, children: _screens),
          ),
        ],
      ),
      bottomNavigationBar: BirrBottomNav(
        currentIndex: _navIndex,
        onTap: (i) => setState(() => _navIndex = i),
      ),
    );
  }
}
