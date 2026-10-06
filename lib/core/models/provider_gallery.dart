/// Provider gallery image model mapped to the `provider_gallery` Supabase table.
/// Provider manages only their own gallery. Admin can moderate.
class ProviderGalleryImage {
  final String id;
  final String providerId;
  final String storagePath;
  final String? caption;
  final int displayOrder;
  final bool isActive;

  /// What this photo costs, in ETB, or null when it carries no price.
  ///
  /// Null is not zero: "no price on this photo" and "this photo is free" are
  /// different claims, and only one of them should render as `0 ETB` in a
  /// grid. The shop-wide headline is `provider_profiles.price_range`; this is
  /// the per-photo answer, and it is the more specific of the two.
  final double? price;

  final DateTime createdAt;
  final DateTime updatedAt;

  /// Whether customers can see this photo.
  ///
  /// Named for what it means rather than what the column is called:
  /// `is_active` gates `provider_gallery_public_read`, so the flag IS the
  /// public state, and every screen that shows it is talking about
  /// visibility. Saying "active" to a provider who is deciding what to
  /// advertise says nothing they can act on.
  bool get isPublic => isActive;

  const ProviderGalleryImage({
    required this.id,
    required this.providerId,
    required this.storagePath,
    this.caption,
    this.displayOrder = 0,
    this.isActive = true,
    this.price,
    required this.createdAt,
    required this.updatedAt,
  });

  /// A price as a person reads it: `50`, not `50.00`.
  ///
  /// Whole birr is the normal case for a service, and this is the same
  /// convention `Product` uses for a listing price (`_fmt`). It lives in one
  /// public place so the badge on a tile, the value pre-filled into the editor
  /// and the confirmation after a save cannot disagree about what 50 means.
  static String formatPrice(double value) => value == value.roundToDouble()
      ? value.toStringAsFixed(0)
      : value.toStringAsFixed(2);

  /// `50 ETB`, or null when this photo carries no price.
  ///
  /// Null rather than an empty string so a caller cannot accidentally render a
  /// blank chip, and so "no price" never renders as `0 ETB` -- a claim the
  /// provider never made.
  String? get priceLabel => price == null ? null : '${formatPrice(price!)} ETB';

  factory ProviderGalleryImage.fromJson(Map<String, dynamic> json) {
    return ProviderGalleryImage(
      id: json['id'] as String,
      providerId: json['provider_id'] as String,
      storagePath: json['storage_path'] as String,
      caption: json['caption'] as String?,
      displayOrder: json['display_order'] as int? ?? 0,
      isActive: json['is_active'] as bool? ?? true,
      // numeric(12,2) arrives from PostgREST as a JSON number, but a cleared
      // price arrives as null -- hence the nullable cast rather than a
      // default.
      price: (json['price'] as num?)?.toDouble(),
      createdAt: DateTime.parse(json['created_at'] as String),
      updatedAt: json['updated_at'] != null
          ? DateTime.parse(json['updated_at'] as String)
          : DateTime.parse(json['created_at'] as String),
    );
  }
}
