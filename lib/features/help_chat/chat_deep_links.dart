/// Intent → in-app route mapping for the assistant's step-by-step guidance.
///
/// The Edge Function returns a `links: [{ label, route }]` array alongside
/// its reply; this table is the single source of truth for which routes
/// exist and what they're called. Keep it in sync when adding features:
/// the server-side `INTENT_ROUTES` in supabase/functions/repo-chat/index.ts
/// must only ever reference routes listed here.
library;

class ChatDeepLink {
  final String label;
  final String route;

  const ChatDeepLink(this.label, this.route);
}

const List<ChatDeepLink> kKnownRoutes = [
  // Wallet / fees
  ChatDeepLink('Open my Wallet', '/wallet'),
  ChatDeepLink('Recharge my wallet', '/wallet/recharge'),
  // Buying / selling
  ChatDeepLink('Go to my dashboard', '/user'),
  ChatDeepLink('Browse & shop', '/user'),
  ChatDeepLink('Open my cart', '/user/cart'),
  ChatDeepLink('Go to checkout', '/user/checkout'),
  ChatDeepLink('My orders', '/user/orders'),
  ChatDeepLink('Provider dashboard', '/provider'),
  ChatDeepLink('Manage my listings', '/provider/products'),
  ChatDeepLink('Add a new listing', '/provider/products/new'),
  ChatDeepLink('Provider orders', '/provider/orders'),
  // Rides
  ChatDeepLink('Book a ride', '/user/ride-request'),
  ChatDeepLink('My ride history', '/user/ride-history'),
  ChatDeepLink('Driver dashboard', '/vehicle'),
  ChatDeepLink('Ride requests', '/vehicle/ride-requests'),
  ChatDeepLink('Vehicle history', '/vehicle/history'),
  ChatDeepLink('Manage vehicles', '/vehicle/vehicles'),
  ChatDeepLink('Add a vehicle', '/vehicle/vehicles/new'),
  // Help & account
  ChatDeepLink('Help & Support', '/help'),
  ChatDeepLink('My profile', '/user/profile'),
  ChatDeepLink('Favorites', '/user/favorites'),
  // Appeals (user-submitted appeal / spam-report form)
  ChatDeepLink('Submit an appeal', '/appeal'),
  // Task 14: chat escalations open the appeal form pre-tagged with context
  // (the AppealScreen reads `about` + `source=chat` from the query string).
  ChatDeepLink('Submit an appeal', '/appeal?about=rider&source=chat'),
  ChatDeepLink('Submit an appeal', '/appeal?about=provider&source=chat'),
  ChatDeepLink('Submit an appeal', '/appeal?about=dispute&source=chat'),
  ChatDeepLink('Submit an appeal', '/appeal?about=account&source=chat'),
  ChatDeepLink('Submit an appeal', '/appeal?about=general&source=chat'),
];
