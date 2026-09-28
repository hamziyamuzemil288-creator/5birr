/// One widget for the three states every data-loading screen has.
///
/// WHY THIS EXISTS
///
/// The screens this replaces each had their own hand-rolled version of the
/// same three branches, and they all got it slightly wrong in the same way:
/// on refresh failure they replaced good content with a full-screen error.
/// The user pulled to refresh, the network blipped, and a screen full of
/// perfectly good data was replaced by "something went wrong" — as though
/// there were nothing there before. The data was still there. It was still
/// valid. It just had not been updated for ten seconds.
///
/// So the rule this widget encodes is: **[data] wins**. If there is data,
/// show the data, and put the failure in a small banner above it. Only when
/// there is genuinely nothing to show does the error take over the screen.
///
/// The other two states are unremarkable but still mandatory: a skeleton while
/// loading (never a bare spinner over a blank page), and an explicit empty
/// state (never an empty grey area, which reads as "still loading" forever).
library;

import 'package:flutter/material.dart';

import '../resilience/app_failure.dart';
import '../resilience/safe_call.dart';
import '../services/connectivity_service.dart';
import '../theme/app_theme.dart';
import 'shimmer_effect.dart';

/// Loads [loader] and renders loading / error / empty / data.
class AsyncView<T> extends StatefulWidget {
  const AsyncView({
    super.key,
    required this.loader,
    required this.builder,
    this.isEmpty,
    this.emptyBuilder,
    this.errorBuilder,
    this.loadingBuilder,
    this.skeletonHeight = 220,
    this.errorContext,
    this.policy = const RetryPolicy.standard(),
    this.timeout = const Duration(seconds: 20),
    this.onRefreshed,
  });

  /// Fetches the data. Should use [safeCall]/[withRetry] — this widget does
  /// not wrap it, so the retry policy and the call site's logging stay
  /// together.
  final Future<T> Function() loader;

  final Widget Function(BuildContext context, T data) builder;

  /// Predicate for "there is nothing here". A null/empty list, usually.
  final bool Function(T data)? isEmpty;

  final Widget Function(BuildContext context, AppFailure failure, VoidCallback retry)?
      emptyBuilder;
  final Widget Function(BuildContext context, AppFailure failure, VoidCallback retry)?
      errorBuilder;
  final Widget Function(BuildContext context)? loadingBuilder;

  final double skeletonHeight;

  /// Prefix for the failure message, e.g. 'Could not load your orders'.
  ///
  /// Named `errorContext` rather than `context` because a `context` field
  /// shadows the `BuildContext` parameter of `build()` in the same class —
  /// which is a compile error at best and, inside a closure, a widget that
  /// quietly loses its element at worst.
  final String? errorContext;

  final RetryPolicy policy;
  final Duration timeout;

  /// Called after every successful load, so the caller can clear a
  /// "couldn't refresh" banner elsewhere or notify [ConnectivityService].
  final void Function(T data)? onRefreshed;

  @override
  State<AsyncView<T>> createState() => _AsyncViewState<T>();
}

class _AsyncViewState<T> extends State<AsyncView<T>> {
  T? _data;
  AppFailure? _failure;
  bool _loading = true;
  /// True once we have something to show, even if stale.
  bool _hasData = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) {
      setState(() => _loading = true);
    }
    try {
      final result = await withRetry<T>(
        widget.loader,
        policy: widget.policy,
        timeout: widget.timeout,
        context: widget.errorContext,
      );
      if (!mounted) return;
      setState(() {
        _data = result;
        _failure = null;
        _loading = false;
        _hasData = true;
      });
      ConnectivityService.instance.reportRefreshed();
      widget.onRefreshed?.call(result);
    } on AppFailure catch (e) {
      if (!mounted) return;
      setState(() {
        // NOTE: _data is deliberately left alone. A failed refresh must not
        // destroy the last good result.
        _failure = e;
        _loading = false;
      });
    }
  }

  void _retry() {
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
    final hasData = _hasData && data != null;

    // 1. Loading, with nothing to show yet -> skeleton.
    if (_loading && !hasData) {
      return widget.loadingBuilder?.call(context) ??
          _Skeleton(height: widget.skeletonHeight);
    }

    // 2. Something to show -> show it, with a quiet banner if the last
    //    refresh failed. The data is still the best information available.
    if (hasData) {
      final staleBanner = _failure == null
          ? null
          : _StaleDataBanner(message: _failure!.message, onRetry: _retry);
      final content = widget.builder(context, data as T);
      if (staleBanner == null) return content;
      return Column(
        children: [
          staleBanner,
          Expanded(child: content),
        ],
      );
    }

    // 3. Failed with nothing to show -> full error state.
    final failure = _failure;
    if (failure != null) {
      return widget.errorBuilder?.call(context, failure, _retry) ??
          _ErrorState(failure: failure, onRetry: _retry);
    }

    // Defensive: no data, no failure, not loading. Should be unreachable.
    return _ErrorState(
      failure: const AppFailure(
        kind: AppFailureKind.unknown,
        message: 'Something went wrong. Please try again.',
      ),
      onRetry: _retry,
    );
  }
}

/// Convenience for the very common "list that can be empty" case.
///
/// Adds the empty branch on top of [AsyncView] so screens do not each
/// re-implement it.
class AsyncListView<T> extends StatelessWidget {
  const AsyncListView({
    super.key,
    required this.loader,
    required this.itemBuilder,
    this.itemCount,
    this.isEmpty,
    this.emptyBuilder,
    this.loadingBuilder,
    this.skeletonItemCount = 6,
    this.padding = const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
    this.separator,
    this.header,
    this.context,
    this.shrinkWrap = false,
    this.physics,
  });

  final Future<List<T>> Function() loader;
  final Widget Function(BuildContext context, T item, int index) itemBuilder;
  final int? Function(List<T> items)? itemCount;

  final bool Function(List<T> items)? isEmpty;
  final WidgetBuilder? emptyBuilder;
  final WidgetBuilder? loadingBuilder;
  final int skeletonItemCount;
  final EdgeInsets padding;
  final Widget? separator;

  /// Rendered above the list and scrolls with it (a section title, say).
  final Widget? header;

  final String? context;
  final bool shrinkWrap;
  final ScrollPhysics? physics;

  @override
  Widget build(BuildContext context) {
    return AsyncView<List<T>>(
      loader: loader,
      errorContext: errorContext,
      loadingBuilder: loadingBuilder ??
          (_) => _ListSkeleton(
              count: skeletonItemCount, padding: padding),
      builder: (context, items) {
        final isReallyEmpty = isEmpty?.call(items) ?? items.isEmpty;
        if (isReallyEmpty) {
          if (emptyBuilder != null) {
            return SingleChildScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: padding,
              child: emptyBuilder!(context),
            );
          }
          return ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: padding,
            children: [
              const SizedBox(height: 40),
              const _GenericEmpty(),
            ],
          );
        }

        final count = itemCount?.call(items) ?? items.length;
        final list = ListView.separated(
          padding: padding,
          shrinkWrap: shrinkWrap,
          physics: physics,
          itemCount: count,
          separatorBuilder: separator == null
              ? (_, __) => const SizedBox(height: 12)
              : (_, __) => separator!,
          itemBuilder: (context, i) => itemBuilder(context, items[i], i),
        );
        if (header == null) return list;
        return CustomScrollView(
          physics: physics,
          slivers: [
            SliverToBoxAdapter(child: header!),
            SliverToBoxAdapter(
              // `separated`, not `builder`: separatorBuilder is a named
              // parameter of ListView.separated and does not exist on
              // ListView.builder. Defaulting to a 12px gap keeps the list
              // readable when the caller passes no separator.
              child: ListView.separated(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                padding: padding,
                itemCount: count,
                separatorBuilder: separator == null
                    ? (_, __) => const SizedBox(height: 12)
                    : (_, __) => separator!,
                itemBuilder: (context, i) => itemBuilder(context, items[i], i),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// "Couldn't refresh" strip shown above content that is still on screen.
///
/// Small on purpose: the user has stale-but-usable data, so this is an
/// FYI, not an alarm. It is tappable to retry.
class _StaleDataBanner extends StatelessWidget {
  const _StaleDataBanner({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppTheme.gold.withOpacity(0.12),
      child: InkWell(
        onTap: onRetry,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
          child: Row(
            children: [
              const Icon(Icons.cloud_off_outlined,
                  size: 15, color: AppTheme.textSecondary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Couldn\'t refresh — $message',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppTheme.textSecondary,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              const Text(
                'Retry',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: AppTheme.primaryGreen,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.failure, required this.onRetry});

  final AppFailure failure;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 76,
              height: 76,
              decoration: BoxDecoration(
                color: AppTheme.error.withOpacity(0.08),
                shape: BoxShape.circle,
              ),
              child: Icon(_iconFor(failure), size: 34, color: AppTheme.error),
            ),
            const SizedBox(height: 18),
            Text(
              failure.message,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 15,
                height: 1.5,
                fontWeight: FontWeight.w600,
                color: AppTheme.textPrimary,
              ),
            ),
            const SizedBox(height: 20),
            // A 403 will not fix itself on retry, so do not offer a button
            // that cannot work. Telling someone to retry an authorisation
            // failure teaches them that Retry is a lie.
            if (failure.isRetryable)
              ElevatedButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('Try again'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.primaryGreen,
                  foregroundColor: Colors.white,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                ),
              ),
          ],
        ),
      ),
    );
  }

  static IconData _iconFor(AppFailure failure) => switch (failure.kind) {
        AppFailureKind.network => Icons.wifi_off_rounded,
        AppFailureKind.timeout => Icons.hourglass_empty_rounded,
        AppFailureKind.serverBusy => Icons.cloud_off_rounded,
        AppFailureKind.unauthorized => Icons.lock_outline_rounded,
        AppFailureKind.forbidden => Icons.block_rounded,
        AppFailureKind.validation => Icons.error_outline_rounded,
        AppFailureKind.malformed => Icons.sync_problem_rounded,
        AppFailureKind.unknown => Icons.error_outline_rounded,
      };
}

class _GenericEmpty extends StatelessWidget {
  const _GenericEmpty();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          width: 72,
          height: 72,
          decoration: BoxDecoration(
            color: AppTheme.gold.withOpacity(0.1),
            shape: BoxShape.circle,
            border: Border.all(color: AppTheme.gold.withOpacity(0.15), width: 1.5),
          ),
          child: const Icon(Icons.inbox_outlined, color: AppTheme.gold, size: 32),
        ),
        const SizedBox(height: 16),
        const Text(
          'Nothing here yet',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w700,
            color: AppTheme.textPrimary,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          'Check back a little later.',
          style: TextStyle(fontSize: 13, color: AppTheme.textMuted.withOpacity(0.8)),
        ),
      ],
    );
  }
}

class _Skeleton extends StatelessWidget {
  const _Skeleton({required this.height});
  final double height;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(20),
      child: ShimmerEffect(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SkeletonBox(width: 150, height: 20, borderRadius: 4),
            const SizedBox(height: 16),
            SkeletonBox(width: double.infinity, height: height, borderRadius: 14),
            const SizedBox(height: 16),
            const SkeletonBox(width: 200, height: 16, borderRadius: 4),
          ],
        ),
      ),
    );
  }
}

class _ListSkeleton extends StatelessWidget {
  const _ListSkeleton({required this.count, required this.padding});

  final int count;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      padding: padding,
      itemCount: count,
      itemBuilder: (_, __) => const Padding(
        padding: EdgeInsets.only(bottom: 12),
        child: ShimmerEffect(
          child: SkeletonBox(width: double.infinity, height: 88, borderRadius: 14),
        ),
      ),
    );
  }
}

/// Tab-specific empty state with a per-tab sentence ("No hotels yet").
///
/// A single generic empty state across a tabbed screen is the same failure as
/// a generic one everywhere else: the user cannot tell "no hotels in this
/// city" from "the Hotels tab is broken".
class TabEmptyState extends StatelessWidget {
  const TabEmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.action,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 48),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                color: AppTheme.primaryGreen.withOpacity(0.08),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 36, color: AppTheme.primaryGreen),
            ),
            const SizedBox(height: 18),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 16.5,
                fontWeight: FontWeight.w700,
                color: AppTheme.textPrimary,
              ),
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 7),
              Text(
                subtitle!,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.5,
                  color: AppTheme.textMuted.withOpacity(0.85),
                ),
              ),
            ],
            if (action != null) ...[const SizedBox(height: 20), action!],
          ],
        ),
      ),
    );
  }
}
