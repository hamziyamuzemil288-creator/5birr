/// Barrel export for the models that are actually in use.
///
/// Five exports were removed here (notification, order, provider_profile,
/// provider_store, ride_request). Their classes had no reference anywhere in
/// lib/, test/ or tools/, and leaving them exported is what turned "dead
/// code" into "dead code the compiler refuses to start over".
export 'user_profile.dart';
export 'wallet.dart';
export 'subscription.dart';
export 'product.dart';
export 'category.dart';
export 'category_tabs.dart';
export 'provider_gallery.dart';
