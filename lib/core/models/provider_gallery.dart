/// Provider gallery image model mapped to the `provider_gallery` Supabase table.
/// Provider manages only their own gallery. Admin can moderate.
class ProviderGalleryImage {
  final String id;
  final String providerId;
  final String storagePath;
  final String? caption;
  final int displayOrder;
  final bool isActive;
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
    required this.createdAt,
    required this.updatedAt,
  });

  factory ProviderGalleryImage.fromJson(Map<String, dynamic> json) {
    return ProviderGalleryImage(
      id: json['id'] as String,
      providerId: json['provider_id'] as String,
      storagePath: json['storage_path'] as String,
      caption: json['caption'] as String?,
      displayOrder: json['display_order'] as int? ?? 0,
      isActive: json['is_active'] as bool? ?? true,
      createdAt: DateTime.parse(json['created_at'] as String),
      updatedAt: json['updated_at'] != null
          ? DateTime.parse(json['updated_at'] as String)
          : DateTime.parse(json['created_at'] as String),
    );
  }
}
