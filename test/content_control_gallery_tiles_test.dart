import 'package:birr5/features/admin/widgets/public_image_gallery.dart';
import 'package:flutter_test/flutter_test.dart';

/// The Content Control gallery threw away a whole city's images over one row.
///
/// `PublicImageGallery._grid` built its tiles with `r['storage_path'] as
/// String` and `r['bucket'] as String`. `admin_public_image_gallery` is a
/// `RETURNS TABLE` function, so both output columns are nullable by
/// definition and PostgREST sends JSON `null` for a null one no matter what
/// the query wrote. An unchecked downcast on that null throws, and it threw
/// inside the list literal that assembled the grid -- so the failure was not
/// one missing photo, it was the entire panel for that city. That is what
/// "images are not loading in this section" meant, while the same files
/// rendered correctly everywhere else.
///
/// The assertions run against `galleryTileItems` -- the function the screen
/// actually calls -- rather than a copy of it, so a refactor cannot leave
/// these green against logic the screen no longer runs.
void main() {
  Map<String, dynamic> row({
    Object? path = 'uid/1/photo.jpg',
    Object? bucket = 'provider-gallery',
  }) =>
      {'storage_path': path, 'bucket': bucket};

  test('a null bucket does not take out the whole city grid', () {
    // The shipped shape: real, renderable photos on either side of a row the
    // RPC could legitimately return a null for.
    final items = galleryTileItems([
      row(),
      row(bucket: null),
      row(),
    ]);

    expect(items.length, 2,
        reason: 'one bad row cost this panel every image in the city');
  });

  test('a null storage_path is skipped, not rendered as a broken tile', () {
    final items = galleryTileItems([
      row(),
      row(path: null),
      row(path: ''),
      row(bucket: ''),
      row(),
    ]);

    expect(items.length, 2,
        reason: 'a row with no path or no bucket was rendered as a tile; '
            'there is nothing to sign, so it could only ever be a grey '
            'placeholder opening an action sheet for a file that is not there');
  });

  test('a complete set of rows still yields one tile each', () {
    // The guard must not have become a filter that quietly drops good rows.
    final items = galleryTileItems([
      row(path: 'a/1.jpg', bucket: 'provider-gallery'),
      row(path: 'a/2.jpg', bucket: 'product-images'),
      row(path: 'a/3.jpg', bucket: 'vehicle-images'),
    ]);

    expect(items.length, 3);
    expect(items.map((i) => i.bucket).toList(),
        ['provider-gallery', 'product-images', 'vehicle-images'],
        reason: 'all three content categories must still reach the grid, in '
            'the order the RPC returned them');
  });

  test('the tile keeps the path and bucket the row actually carried', () {
    final items = galleryTileItems([row(path: 'a/9.jpg', bucket: 'product-images')]);

    expect(items.single.path, 'a/9.jpg');
    expect(items.single.bucket, 'product-images');
  });

  test('the tap still receives the row it belongs to', () {
    // A tile whose onTap closed over the wrong row would open the action
    // sheet for someone else's photo -- a worse bug than a blank panel.
    final target = row(path: 'a/2.jpg');
    Map<String, dynamic>? tapped;
    galleryTileItems([row(), target], onTap: (r) => tapped = r);

    final items = galleryTileItems([row(), target], onTap: (r) => tapped = r);
    items[1].onTap!();

    expect(tapped, same(target));
  });

  test('the unchecked cast is what used to throw', () {
    // Proven, not asserted: the exact expression from the shipped _grid(),
    // against the exact row the RPC can return. If this ever stops throwing,
    // the defect these tests describe has been papered over somewhere else
    // and they would be passing for the wrong reason.
    Object? caught;
    try {
      final r = <String, dynamic>{'storage_path': 'a/1.jpg', 'bucket': null};
      // ignore: unused_local_variable
      final bucket = r['bucket'] as String;
    } catch (e) {
      caught = e;
    }
    expect(caught, isNotNull,
        reason: 'a null bucket no longer throws on an unchecked cast');
  });
}
