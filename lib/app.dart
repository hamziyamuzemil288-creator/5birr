import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'routing/app_router.dart';
import 'core/theme/app_theme.dart';
import 'core/widgets/connectivity_banner.dart';
import 'features/help_chat/floating_chat_button.dart';

class Birr5App extends ConsumerWidget {
  const Birr5App({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(appRouterProvider);

    return MaterialApp.router(
      title: 'Aliob',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: ThemeMode.light,
      routerConfig: router,
      // `builder` runs above the Navigator, so the connectivity banner is not
      // a route: it cannot be popped, cannot stack, and shows on every screen
      // including modal ones. That is the intent — the connection is a global
      // fact, and a per-screen indicator would mean the user learns about it
      // on whichever screen they happen to be on.
      builder: (context, child) => Column(
        children: [
          const ConnectivityBanner(),
          // Expanded, not Expanded-less: without it the Column would size
          // itself to the banner and the app would collapse to a sliver.
          Expanded(
            child: FloatingChatOverlay(child: child ?? const SizedBox.shrink()),
          ),
        ],
      ),
    );
  }
}
