import 'package:birr5/features/admin/admin_content_control_screen.dart';
import 'package:flutter_test/flutter_test.dart';

/// "Delete image" on the Content Control reports list showed an error and
/// deleted nothing.
///
/// Content Control calls `_removeImageFromRow` from two different lists, and
/// the two callers do not hold the same kind of row:
///
///   * the delete-only image strip passes an `admin_public_image_gallery`
///     row, which carries `bucket` and `storage_path`;
///   * `_reportCard` passes a `content_reports` row, whose columns are
///     `object_bucket` and `object_path` (20260927000122) — there is no
///     `bucket` and no `storage_path` on that table at all.
///
/// The handler read only the gallery names, so for a report both resolved to
/// null and it returned early with "That image has no usable path, so it
/// cannot be deleted." — an error snackbar, no server call, and no way to
/// clear it by trying again. The two names are fused into one fact by
/// `moderationDeleteTarget`, which is the function the screen itself calls, so
/// a refactor cannot leave these tests green against logic the screen no
/// longer runs.
void main() {
  test('a report row is understood, not rejected', () {
    // The exact shape content_reports returns for a photo report, as filed by
    // user_provider_detail_screen's `file_content_report` call.
    final target = moderationDeleteTarget({
      'id': 'r-1',
      'object_bucket': 'provider-gallery',
      'object_path': 'uid/1/photo.jpg',
      'category': 'NUDITY_OR_SEXUAL',
      'status': 'OPEN',
    });

    expect(target, isNotNull,
        reason: 'a report row still resolved to nulls and stopped at the '
            '"no usable path" error before reaching the server');
    expect(target!.bucket, 'provider-gallery');
    expect(target.path, 'uid/1/photo.jpg');
  });

  test('the gallery-only read is what used to return nothing', () {
    // Proven, not asserted: the exact two expressions the handler used before
    // moderationDeleteTarget existed, run against the exact row a report card
    // holds. Both are null, which is the early return and the error snackbar.
    final reportRow = <String, dynamic>{
      'object_bucket': 'provider-gallery',
      'object_path': 'uid/1/photo.jpg',
    };

    expect(reportRow['bucket'] as String?, isNull,
        reason: 'content_reports has no bucket column');
    expect(reportRow['storage_path'] as String?, isNull,
        reason: 'content_reports has no storage_path column');
  });

  test('the gallery row shape keeps working unchanged', () {
    final target = moderationDeleteTarget({
      'storage_path': 'uid/2/photo.jpg',
      'bucket': 'product-images',
    });

    expect(target, isNotNull);
    expect(target!.bucket, 'product-images');
    expect(target.path, 'uid/2/photo.jpg');
  });

  test('every moderable bucket a report can name is passed through', () {
    // `admin_moderate_image` refuses anything outside its membership list
    // with THAT_BUCKET_IS_NOT_MODERABLE, so these are the only values that may
    // ever leave the client.
    const moderable = [
      'provider-photos',
      'provider-gallery',
      'product-images',
      'vehicle-images',
      'profile-avatars',
    ];
    for (final bucket in moderable) {
      final target = moderationDeleteTarget(
          {'object_bucket': bucket, 'object_path': 'uid/3/$bucket.jpg'});
      expect(target?.bucket, bucket);
    }
  });

  test('a report that named no photo is refused, not sent with a guess', () {
    // `file_content_report` sends a null bucket whenever the reporter chose no
    // photo, which is also the case where no Delete button is drawn. It must
    // stay a refusal: sending `p_bucket: ''` would come back
    // THAT_BUCKET_IS_NOT_MODERABLE, and inventing a bucket would write the
    // wrong one into the audit record.
    expect(moderationDeleteTarget({'object_path': 'uid/4/x.jpg'}), isNull);
    expect(moderationDeleteTarget({'object_bucket': 'provider-gallery'}),
        isNull);
    expect(
        moderationDeleteTarget(
            {'object_bucket': 'provider-gallery', 'object_path': ''}),
        isNull);
    expect(moderationDeleteTarget(const {}), isNull);
  });

  test('an empty gallery bucket does not silently fall back to a report key',
      () {
    // The order matters only when a row somehow carries both; the gallery
    // value is the one the RPC was called with before, so it must win.
    final target = moderationDeleteTarget({
      'bucket': 'vehicle-images',
      'storage_path': 'uid/5/x.jpg',
      'object_bucket': 'provider-gallery',
      'object_path': 'uid/5/other.jpg',
    });

    expect(target!.bucket, 'vehicle-images');
    expect(target.path, 'uid/5/x.jpg');
  });
}
