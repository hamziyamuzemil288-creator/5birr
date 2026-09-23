/// Category model mapped to the `categories` Supabase table.
/// Supports both SERVICE/VEHICLE sectors and marketplace_sector mapping.
class AppCategory {
  final String id;
  final String? parentId;
  final String name;
  final String sector; // SERVICE | VEHICLE
  final String slug;
  final String? icon;
  final String? imageUrl;
  final String? description;
  final String? marketplaceSector; // FOOD, RETAIL, ACCOMMODATION, SERVICES, TRANSPORT, OTHER
  /// Task 7 item 5: two top-level groups. 'PRODUCT_BASED' = the user
  /// orders/receives a physical product; 'BOOKING_BASED' = the user books a
  /// service/ride/time slot. Null on legacy rows before grouping.
  final String? serviceGroup;
  final bool isActive;
  final int sortOrder;
  final DateTime createdAt;
  final DateTime? updatedAt;
  final List<AppCategory> subcategories;

  const AppCategory({
    required this.id,
    this.parentId,
    required this.name,
    required this.sector,
    required this.slug,
    this.icon,
    this.imageUrl,
    this.description,
    this.marketplaceSector,
    this.serviceGroup,
    this.isActive = true,
    this.sortOrder = 0,
    required this.createdAt,
    this.updatedAt,
    this.subcategories = const [],
  });

  factory AppCategory.fromJson(Map<String, dynamic> json) {
    return AppCategory(
      id: json['id'] as String,
      parentId: json['parent_id'] as String?,
      name: json['name'] as String,
      sector: json['sector'] as String,
      slug: json['slug'] as String,
      icon: json['icon'] as String?,
      imageUrl: json['image_url'] as String?,
      description: json['description'] as String?,
      marketplaceSector: json['marketplace_sector'] as String?,
      serviceGroup: json['service_group'] as String?,
      isActive: json['is_active'] as bool? ?? true,
      sortOrder: json['sort_order'] as int? ?? 0,
      createdAt: DateTime.parse(json['created_at'] as String),
      updatedAt: json['updated_at'] != null
          ? DateTime.parse(json['updated_at'] as String)
          : DateTime.parse(json['created_at'] as String),
    );
  }

  bool get isService => sector == 'SERVICE';
  bool get isVehicle => sector == 'VEHICLE';
  bool get isParent => parentId == null;
  bool get isMarketplaceCategory => marketplaceSector != null;
}
