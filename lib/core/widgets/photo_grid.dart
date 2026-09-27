import 'dart:io';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../theme/app_theme.dart';

/// One tile's worth of data. Either a stored [path] (resolved against
/// [bucket]) or a local [file] that has not been uploaded yet -- the product
/// form shows both at once, and a grid that could only show one of them would
/// force that screen back to a plain list.
class PhotoGridItem {
  final String? path;
  final String? bucket;
  final String? publicUrl;
  final File? file;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final Widget? overlay;

  const PhotoGridItem.file(this.file, {this.onTap, this.onLongPress, this.overlay})
      : path = null,
        bucket = null,
        publicUrl = null;

  const PhotoGridItem.stored(
    this.path, {
    required this.bucket,
    this.publicUrl,
    this.onTap,
    this.onLongPress,
    this.overlay,
  }) : file = null;
}

/// A square, tightly-spaced image grid — the layout every phone photo app uses,
/// and the one a customer expects when a provider has more than two photos.
///
/// Three or more per row, 1:1 tiles, a small consistent gap and rounded
/// corners. It is a GridView rather than a horizontal ListView so the row count
/// adapts to width instead of scrolling sideways, and it takes both local files
/// and stored paths so a screen mid-upload can show the same grid it will show
/// after the upload.
class PhotoGrid extends StatelessWidget {
  const PhotoGrid({
    super.key,
    required this.items,
    this.columns = 3,
    this.spacing = 4,
    this.borderRadius = 10,
    this.aspectRatio = 1,
    this.crossAxisCount,
  });

  final List<PhotoGridItem> items;

  /// Minimum columns per row. Raised on wider layouts by the caller; the
  /// widget never drops below three on a phone because a two-across grid stops
  /// reading as a photo set.
  final int columns;
  final double spacing;
  final double borderRadius;
  final double aspectRatio;

  /// Overrides [columns] outright. Used for the one-across full-bleed hero
  /// image on a product detail screen, which is a layout decision and not a
  /// grid decision.
  final int? crossAxisCount;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    final count = crossAxisCount ?? columns;
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: EdgeInsets.zero,
      itemCount: items.length,
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: count,
        crossAxisSpacing: spacing,
        mainAxisSpacing: spacing,
        // childAspectRatio is width/height, so 1.0 is the square tile.
        childAspectRatio: aspectRatio,
      ),
      itemBuilder: (context, index) => _tile(context, items[index]),
    );
  }

  Widget _tile(BuildContext context, PhotoGridItem item) {
    Widget image;
    if (item.file != null) {
      image = Image.file(
        item.file!,
        fit: BoxFit.cover,
        width: double.infinity,
        height: double.infinity,
        errorBuilder: (_, __, ___) => const _Fallback(),
      );
    } else if (item.publicUrl != null && item.publicUrl!.isNotEmpty) {
      image = Image.network(
        item.publicUrl!,
        fit: BoxFit.cover,
        width: double.infinity,
        height: double.infinity,
        errorBuilder: (_, __, ___) => const _Fallback(),
      );
    } else if (item.path != null && item.bucket != null) {
      // Resolve through the client so private buckets and signed URLs both
      // work; a gallery row that stored only a path is the normal case.
      image = FutureBuilder<List<String>>(
        future: Supabase.instance.client.storage.from(item.bucket!).createSignedUrls(
              [item.path!],
              3600,
            ),
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const _Fallback(showSpinner: true);
          }
          final urls = snap.data;
          if (urls == null || urls.isEmpty || urls.first.isEmpty) {
            return const _Fallback();
          }
          return Image.network(
            urls.first,
            fit: BoxFit.cover,
            width: double.infinity,
            height: double.infinity,
            errorBuilder: (_, __, ___) => const _Fallback(),
          );
        },
      );
    } else {
      image = const _Fallback();
    }

    return GestureDetector(
      onTap: item.onTap,
      onLongPress: item.onLongPress,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(borderRadius),
        child: Stack(
          fit: StackFit.expand,
          children: [
            image,
            if (item.overlay != null) item.overlay!,
          ],
        ),
      ),
    );
  }
}

class _Fallback extends StatelessWidget {
  const _Fallback({this.showSpinner = false});
  final bool showSpinner;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppTheme.creamDark,
      alignment: Alignment.center,
      child: showSpinner
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: AppTheme.textMuted),
            )
          : const Icon(Icons.image, color: AppTheme.textMuted, size: 20),
    );
  }
}
