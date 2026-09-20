import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../core/theme/app_theme.dart';

/// Version of the Terms & Privacy Policy currently in force. Bump this
/// whenever the policy text changes so existing users can be re-prompted.
const String kTermsVersion = '2026-09-20';

/// Full Terms & Privacy Policy text, shown as a dedicated page and linked
/// from the registration checkbox. Kept in one place so the registration
/// forms and this page can never drift apart.
const String kTermsAndPrivacyText = '''
# Aliob — Terms & Privacy Policy
**Version 2026-09-20**

Welcome to Aliob, Ethiopia's local marketplace for goods, services, and
rides. By creating an account you agree to the rules below. They exist to
keep every trade safe, honest, and fair for both sides.

## 1. Fair dealing after contact is revealed
Once escrow payment is confirmed and contact details are revealed, both
parties must treat each other with respect. You must not:

- Spam, harass, threaten, or abuse the other party by phone, message, or in person.
- Pressure the other party to cancel an order outside the app.
- Share the other party's contact details or location with anyone else.

## 2. Keep payments inside the app
All payments must go through Aliob's escrow flow. You must not:

- Ask another party to pay you directly (cash, Telebirr transfer, or any other off-platform method) to bypass the app's payment process.
- Deliver goods or services paid for outside the app and then claim support or protection from Aliob.

Off-platform deals have no escrow protection. If you are scammed outside
the app, Aliob cannot recover your money or act against the other account.

## 3. Represent yourself and your listings honestly

- Describe products, services, vehicles, and prices accurately.
- Upload real photos of what you actually offer.
- Keep prices, availability, and stock up to date.
- Do not create fake listings, fake reviews, or fake accounts.
- Providers must hold any licence their service legally requires.

## 4. Consequences of violations
Breaking these rules can lead to, in rising order of severity:

1. A warning and a request to correct the issue.
2. Temporary suspension of your account.
3. Permanent suspension, with any pending wallet balance withheld pending investigation of the violation.

Serious matters (fraud, threats, or illegal activity) may also be reported
to the authorities.

## 5. How Aliob uses your data
Aliob collects and uses the minimum data needed to run a safe marketplace:

- **Phone number** — to contact you about your orders and account, and so support can reach you when you report an issue.
- **National ID / licence photos** — to verify your identity before your account is approved. Only our admin team can view them.
- **Location data** — collected only to enable ride matching, delivery location sharing between buyer and seller after escrow confirmation, and directions. Location is never sold or used for advertising.
- **Payment screenshots and transaction records** — to verify payments and resolve disputes.

Your documents and contact details are never shared with other users,
except the specific details revealed by escrow after payment confirmation
(seller contact and delivery location for an order you paid for).

## 6. Your choices
You can request account deletion at any time from your profile. Deleting
your account removes your personal details; transaction records needed for
legal and dispute purposes are retained as required.

## 7. Changes to these terms
If this policy changes materially, you'll be asked to review and accept
the new version before continuing to use updated features.

Questions? Contact support on WhatsApp at **0917686990** or by email at
**muktarbiya329@gmail.com**.
''';

/// Minimal inline renderer for **bold** spans (the only markup the policy
/// text uses inside a line).
List<InlineSpan> _inlineSpans(String line, TextStyle base, TextStyle bold) {
  final spans = <InlineSpan>[];
  final regex = RegExp(r'\*\*(.+?)\*\*');
  var start = 0;
  for (final m in regex.allMatches(line)) {
    if (m.start > start) {
      spans.add(TextSpan(text: line.substring(start, m.start), style: base));
    }
    spans.add(TextSpan(
        text: m.group(1)!.replaceAll('**', ''), style: bold));
    start = m.end;
  }
  if (start < line.length) {
    spans.add(TextSpan(text: line.substring(start), style: base));
  }
  return spans;
}

/// One rendered block of the policy (heading, bullet, or paragraph).
Widget _buildBlock(String rawLine) {
  final line = rawLine.trimRight();
  if (line.startsWith('# ')) {
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 12),
      child: Text(line.substring(2), style: AppTheme.heading.copyWith(fontSize: 22)),
    );
  }
  if (line.startsWith('## ')) {
    return Padding(
      padding: const EdgeInsets.only(top: 20, bottom: 8),
      child: Text(line.substring(3), style: AppTheme.sectionHeader),
    );
  }
  if (line.startsWith('- ')) {
    return Padding(
      padding: const EdgeInsets.only(left: 10, bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 7),
            child: SizedBox(
              width: 6,
              height: 6,
              child: DecoratedBox(
                decoration:
                    BoxDecoration(color: AppTheme.teal, shape: BoxShape.circle),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: _inlineSpans(
                  line.substring(2),
                  AppTheme.bodyMedium.copyWith(
                      color: AppTheme.textPrimary, height: 1.6),
                  AppTheme.bodyStrong,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
  final numbered = RegExp(r'^(\d+)\.\s+(.*)$').firstMatch(line);
  if (numbered != null) {
    return Padding(
      padding: const EdgeInsets.only(left: 10, bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 22,
            child: Text('${numbered.group(1)}.',
                style: AppTheme.bodyStrong.copyWith(height: 1.6)),
          ),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: _inlineSpans(
                  numbered.group(2)!,
                  AppTheme.bodyMedium.copyWith(
                      color: AppTheme.textPrimary, height: 1.6),
                  AppTheme.bodyStrong,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
  if (line.isEmpty) return const SizedBox(height: 8);
  return Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text.rich(
      TextSpan(
        children: _inlineSpans(
          line,
          AppTheme.bodyMedium.copyWith(
              color: AppTheme.textPrimary, height: 1.65),
          AppTheme.bodyStrong,
        ),
      ),
    ),
  );
}

/// Full-screen Terms & Privacy Policy page, opened from the registration
/// checkbox ("I agree to the Terms & Privacy Policy").
class TermsPolicyScreen extends StatelessWidget {
  final bool returnToSignup;

  const TermsPolicyScreen({super.key, this.returnToSignup = false});

  @override
  Widget build(BuildContext context) {
    final blocks =
        kTermsAndPrivacyText.split('\n').map(_buildBlock).toList();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Terms & Privacy Policy'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () =>
              returnToSignup ? context.pop() : context.go('/role-select'),
        ),
      ),
      body: Container(
        color: AppTheme.surface,
        child: Scrollbar(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 40),
            children: blocks,
          ),
        ),
      ),
    );
  }
}
