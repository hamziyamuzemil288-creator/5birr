/// User profile model mapped to the `profiles` Supabase table.
class UserProfile {
  final String id;
  final String fullName;
  final String? phone;
  final String? email;
  final String? nationalId;
  final String status; // PENDING_APPROVAL | APPROVED | REJECTED | SUSPENDED | INACTIVE
  final DateTime createdAt;
  final DateTime updatedAt;

  // The address half. Nullable and absent from toJson's contract for older
  // callers, but they ARE what a Google sign-up never supplies, so the router
  // gate needs them to decide whether the account is verifiable.
  final String? city;
  final String? kebele;
  final String? streetRoad;

  const UserProfile({
    required this.id,
    required this.fullName,
    this.phone,
    this.email,
    this.nationalId,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
    this.city,
    this.kebele,
    this.streetRoad,
  });

  factory UserProfile.fromJson(Map<String, dynamic> json) {
    return UserProfile(
      id: json['id'] as String,
      fullName: json['full_name'] as String,
      phone: json['phone'] as String?,
      email: json['email'] as String?,
      nationalId: json['national_id'] as String?,
      status: json['status'] as String,
      createdAt: DateTime.parse(json['created_at'] as String),
      updatedAt: DateTime.parse(json['updated_at'] as String),
      city: json['city'] as String?,
      kebele: json['kebele'] as String?,
      streetRoad: json['street_road'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'full_name': fullName,
        'phone': phone,
        'email': email,
        'national_id': nationalId,
        'status': status,
        'city': city,
        'kebele': kebele,
        'street_road': streetRoad,
      };

  bool get isApproved => status == 'APPROVED';
  bool get isPending => status == 'PENDING_APPROVAL';
  bool get isRejected => status == 'REJECTED';
  bool get isSuspended => status == 'SUSPENDED';

  /// Whether an admin has enough on this account to verify a document.
  ///
  /// `fullName` is checked against the trigger's placeholder because
  /// `handle_new_user()` writes `COALESCE(metadata->>'full_name', 'New User')`
  /// — a Google account therefore has a NON-NULL name that is not a name, and
  /// a null check alone would wave it straight through.
  ///
  /// `nationalId` is deliberately NOT required: no sign-up flow collects it
  /// (signup_screen says so explicitly), it is proven by the uploaded
  /// document instead, and requiring it here would bounce every user to a
  /// screen asking for something the app then cannot check.
  bool get isVerifiable =>
      fullName.trim().isNotEmpty &&
      fullName.trim() != 'New User' &&
      (phone?.trim().isNotEmpty ?? false) &&
      (kebele?.trim().isNotEmpty ?? false) &&
      (streetRoad?.trim().isNotEmpty ?? false);
}
