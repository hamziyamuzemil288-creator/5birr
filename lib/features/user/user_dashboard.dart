import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/widgets/app_error_boundary.dart';
import '../../core/widgets/birr_bottom_nav.dart';
import '../../core/widgets/verification_notice.dart';
import 'user_favorites_screen.dart';
import 'user_home_screen.dart';
import 'user_orders_screen.dart';
import 'user_profile_screen.dart';

/// The signed-in shell: four tabs behind a bottom bar.
///
/// ## Why every tab is wrapped in an error boundary
///
/// The tabs live in an [IndexedStack], which means all four are *built* at
/// once even though one is visible. Before this, a throw in any one of them
/// propagated out of the whole shell and the app went to a blank white
/// screen — the exact regression this work exists to make impossible. Each
/// tab now has its own boundary, so a broken Favourite tab shows a recovery
/// screen inside its own slot and Home, Order and Account keep working.
///
/// The boundaries are also keyed, so switching to a tab that crashed and back
/// re-runs it rather than leaving a permanently poisoned subtree.
class UserDashboard extends StatefulWidget {
  const UserDashboard({super.key});

  @override
  State<UserDashboard> createState() => _UserDashboardState();
}

class _UserDashboardState extends State<UserDashboard> {
  int _navIndex = 0;
  bool _initFromRoute = false;

  /// Tab order matches [BirrBottomNav]: Home, Order, Favourite, Account.
  ///
  /// The ?tab= values this is reached with are a contract — see
  /// chat_deep_links.dart, user_checkout_screen.dart and the home header
  /// icons. They were updated together with the nav; the mapping is:
  /// 0 Home, 1 Order, 2 Favourite, 3 Account.
  static const List<Widget> _screens = [
    Material(child: UserHomeScreen()),
    Material(child: UserOrdersScreen()),
    Material(child: UserFavoritesScreen()),
    Material(child: UserProfileScreen()),
  ];

  static const List<String> _tabNames = ['Home', 'Order', 'Favourite', 'Account'];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
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

  void _goTo(int index) {
    if (index == _navIndex) return;
    setState(() => _navIndex = index);
  }

  @override
  Widget build(BuildContext context) {
    return AppErrorBoundary(
      screenName: 'user-dashboard',
      child: Scaffold(
        // Non-blocking "Verify your account" notice after registration.
        // Pure UI; the real gate still sits on the first protected action.
        body: Column(
          children: [
            const VerificationNotice(),
            Expanded(
              child: IndexedStack(
                index: _navIndex,
                children: [
                  for (var i = 0; i < _screens.length; i++)
                    AppErrorBoundary(
                      // Keyed on the tab name so a tab that crashed and is
                      // revisited is rebuilt from scratch.
                      key: ValueKey('tab-$_tabNames-$i'),
                      screenName: 'user/${_tabNames[i]}',
                      child: _screens[i],
                    ),
                ],
              ),
            ),
          ],
        ),
        bottomNavigationBar: BirrBottomNav(
          currentIndex: _navIndex,
          onTap: _goTo,
        ),
      ),
    );
  }
}
