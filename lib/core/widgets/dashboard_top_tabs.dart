import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// One top-level group on a provider dashboard.
class DashboardTab {
  const DashboardTab({
    required this.label,
    required this.icon,
    required this.builder,
  });

  final String label;
  final IconData icon;

  /// The tab's content. Called only while the tab is selected, so a tab's
  /// data is fetched when the user arrives at it rather than for all tabs at
  /// once — four dashboards' worth of queries on open is four times the load
  /// for content the user may never look at.
  final WidgetBuilder builder;
}

/// The top tab row on a provider dashboard, matching the user home's sketch.
///
/// ## Why the tabs, and not just a longer list
///
/// The service provider's Actions list was nine rows in one undifferentiated
/// list: browsing, products, gallery, orders, wallet, subscription, profile.
/// Nothing said which of those were the things a provider opens daily
/// ("Orders") and which were set-once configuration ("Business Profile",
/// "Subscription"). Grouping them means the first screen a provider sees
/// answers "what is happening to me" and the rest is one tap away.
///
/// The vehicle dashboard groups the same way: the shift-related work
/// (Live Map, Ride Requests, Active Trip) sits apart from the fleet
/// management (Vehicles, Add Vehicle) and the account bits.
class DashboardTopTabs extends StatefulWidget {
  const DashboardTopTabs({super.key, required this.tabs, this.initialIndex = 0});

  final List<DashboardTab> tabs;
  final int initialIndex;

  @override
  State<DashboardTopTabs> createState() => _DashboardTopTabsState();
}

class _DashboardTopTabsState extends State<DashboardTopTabs> {
  late int _index = widget.initialIndex;

  @override
  Widget build(BuildContext context) {
    if (widget.tabs.isEmpty) return const SizedBox.shrink();
    return Column(
      children: [
        Container(
          height: 46,
          color: AppTheme.background,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            itemCount: widget.tabs.length,
            separatorBuilder: (_, __) => const SizedBox(width: 8),
            itemBuilder: (context, i) {
              final tab = widget.tabs[i];
              final selected = i == _index;
              return GestureDetector(
                onTap: () => setState(() => _index = i),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeOut,
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: selected ? AppTheme.primaryGreen : Colors.white,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: selected
                          ? AppTheme.primaryGreen
                          : AppTheme.cardBorder,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        tab.icon,
                        size: 15,
                        color: selected ? Colors.white : AppTheme.textMuted,
                      ),
                      const SizedBox(width: 7),
                      Text(
                        tab.label,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color:
                              selected ? Colors.white : AppTheme.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
        // Keyed on the index so switching tabs rebuilds the subtree. A crashed
        // tab is re-created rather than left poisoned.
        //
        // NOT wrapped in Expanded: this widget is used inside a
        // SingleChildScrollView, where Expanded would throw because the column
        // has no bounded height. The tab content therefore sizes itself and
        // scrolls with the rest of the page, which is also what a provider
        // expects — the whole dashboard is one scroll.
        KeyedSubtree(
          key: ValueKey('dash-tab-$_index'),
          child: widget.tabs[_index].builder(context),
        ),
      ],
    );
  }
}
