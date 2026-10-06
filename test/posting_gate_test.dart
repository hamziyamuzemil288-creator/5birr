// The posting gate, tested where it decides.
//
// The gate is the three-step checklist a provider meets before posting:
// document verification, the admin-configured wallet minimum, and — since
// item 6 — an active payment account (no account, no listing, and the
// existing ones are hidden from buyers). What breaks
// silently in a gate like this is the DISPLAY logic — a step that reads
// "Done" when the server did not say so, an "under review" state that
// swallows the other step, a progress line that counts the wrong things, or
// a new server code (WALLET_BELOW_MINIMUM, migration 20261006000003) that
// falls through to a generic sentence instead of the wallet step's remedy.
// Every test below is one of those shapes, driven through the real pure
// factory (`PostingGateState.from`) rather than a copy of it.

import 'package:birr5/core/services/posting_gate.dart';
import 'package:birr5/core/services/provider_doc_gate.dart';
import 'package:birr5/core/services/provider_readiness.dart';
import 'package:birr5/core/utils/friendly_error.dart';
import 'package:flutter_test/flutter_test.dart';

PostingGateState _state({
  bool checked = true,
  List<String> blockers = const [],
  DocReviewState docState = DocReviewState.verified,
  double balance = 500,
  double requiredAmount = 0,
  bool verificationRequired = true,
  String? rejectionReason,
  bool? hasPaymentAccount,
}) =>
    PostingGateState.from(
      checked: checked,
      blockers: blockers,
      docState: docState,
      balance: balance,
      requiredAmount: requiredAmount,
      verificationRequired: verificationRequired,
      rejectionReason: rejectionReason,
      hasPaymentAccount: hasPaymentAccount,
    );

void main() {
  group('readiness is the server answer, and only the server answer', () {
    test('checked with no blockers is ready', () {
      expect(_state().ready, isTrue);
    });

    // Item 6: the account step is a direct read of the table the server
    // refuses without. A definite "no" blocks; an unreadable step never
    // pretends to be done but does not block either (the create path still
    // enforces the rule).
    test('no payment account is a blocking todo step', () {
      final s = _state(hasPaymentAccount: false);
      expect(s.paymentAccount.state, PostingStepState.todo);
      expect(s.paymentAccount.route, '/provider/payment-methods');
      expect(s.ready, isFalse);
    });

    test('an active payment account reads as done', () {
      final s = _state(hasPaymentAccount: true);
      expect(s.paymentAccount.state, PostingStepState.done);
      expect(s.ready, isTrue);
      expect(s.progressLabel, '3 of 3 done');
    });

    test('an unreadable account step is unknown and never blocks', () {
      final s = _state(); // hasPaymentAccount not passed => null
      expect(s.paymentAccount.state, PostingStepState.unknown);
      expect(s.ready, isTrue);
    });

    // A provider whose blockers could not be read must never see a green
    // checklist: "could not ask" is a different answer from "nothing is
    // outstanding", and the first one must not open the form.
    test('unchecked is NOT ready, even with an empty blocker list', () {
      expect(_state(checked: false).ready, isFalse);
    });

    test('the unknown constant never reads as ready, and shows why', () {
      // What the dialog renders when every read failed: unknown steps, not
      // done ones, and no way to press Continue.
      final s = PostingGateState.unknown;
      expect(s.ready, isFalse);
      expect(s.documents.state, PostingStepState.unknown);
      expect(s.wallet.state, PostingStepState.unknown);
      expect(s.progressLabel, '0 of 3 done');
    });

    test('any blocker means not ready', () {
      expect(_state(blockers: ['ACCOUNT_NOT_APPROVED']).ready, isFalse);
    });
  });

  group('progress counts what the server counts', () {
    test('one step done reads "1 of 3 done"', () {
      // Documents under review (not done), wallet short (not done), the
      // payment account present (done): exactly one counted step.
      final s = _state(
        blockers: const ['DOCUMENTS_UNVERIFIED', 'WALLET_BELOW_MINIMUM'],
        docState: DocReviewState.pending,
        balance: 40,
        requiredAmount: 100,
        hasPaymentAccount: true,
      );
      expect(s.doneCount, 1);
      expect(s.progressLabel, '1 of 3 done');
      expect(s.ready, isFalse);
    });

    test('two steps done read "2 of 3 done" and are ready', () {
      // The account step was not read (null): unknown, not counted, not
      // blocking — the third row shows "We could not check", never "Done".
      final s = _state(balance: 500, requiredAmount: 100);
      expect(s.progressLabel, '2 of 3 done');
      expect(s.ready, isTrue);
    });

    test('under review is NOT done, and never swallows the wallet step', () {
      // The spec's edge case: documents sitting with an administrator must
      // not hide the wallet step — the provider can still recharge while
      // they wait, and the progress line must not count the review as done.
      final s = _state(
        docState: DocReviewState.pending,
        blockers: const ['DOCUMENTS_UNVERIFIED', 'WALLET_BELOW_MINIMUM'],
        balance: 0,
        requiredAmount: 100,
      );
      expect(s.documents.state, PostingStepState.underReview);
      expect(s.documents.actionLabel, isNull);
      expect(s.wallet.state, PostingStepState.todo);
      expect(s.wallet.route, '/wallet/recharge');
      expect(s.progressLabel, '0 of 3 done');
    });
  });

  group('the wallet step speaks in the admin number', () {
    test('shortfall names the minimum and offers the recharge screen', () {
      final s = _state(
        blockers: const ['WALLET_BELOW_MINIMUM'],
        balance: 40,
        requiredAmount: 100,
      );
      expect(s.wallet.state, PostingStepState.todo);
      expect(s.wallet.detail, contains('60 ETB short'));
      expect(s.wallet.detail, contains('100 ETB minimum'));
      expect(s.wallet.route, '/wallet/recharge');
    });

    test('a funded wallet reads as done with the number on file', () {
      final s = _state(
        blockers: const [],
        balance: 120,
        requiredAmount: 100,
      );
      expect(s.wallet.state, PostingStepState.done);
      expect(s.wallet.detail, contains('120 ETB'));
    });

    test('WALLET_BELOW_MINIMUM folds into the wallet step, not extra blockers',
        () {
      // The new server code must not render as a third, unexplained row —
      // the remedy is the same recharge, so it belongs to the wallet step.
      final s = _state(
        blockers: const ['DOCUMENTS_UNVERIFIED', 'WALLET_BELOW_MINIMUM'],
        docState: DocReviewState.none,
        balance: 0,
        requiredAmount: 50,
      );
      expect(s.extraBlockers, isEmpty);
      expect(s.wallet.state, PostingStepState.todo);
    });

    test('unrelated blockers still surface as extra rows', () {
      final s = _state(
        blockers: const ['ACCOUNT_NOT_APPROVED', 'ACTIVATION_FEE_UNPAID'],
        docState: DocReviewState.verified,
      );
      expect(s.extraBlockers,
          containsAll(['ACCOUNT_NOT_APPROVED', 'ACTIVATION_FEE_UNPAID']));
    });
  });

  group('document states say what a provider can do', () {
    test('rejected carries the administrator reason and a re-upload action',
        () {
      final s = _state(
        docState: DocReviewState.rejected,
        blockers: const ['DOCUMENTS_UNVERIFIED'],
        rejectionReason: 'Photo of the ID was blurry.',
      );
      expect(s.documents.state, PostingStepState.rejected);
      expect(s.documents.detail, contains('Photo of the ID was blurry.'));
      expect(s.documents.actionLabel, 'Upload a new ID');
      expect(s.documents.opensSheet, isTrue);
    });

    test('verification switched off makes the step done, not todo', () {
      final s = _state(
        docState: DocReviewState.none,
        verificationRequired: false,
        blockers: const [],
      );
      expect(s.documents.state, PostingStepState.done);
      expect(s.ready, isTrue);
    });
  });

  group('the new server codes arrive as sentences', () {
    test('WALLET_BELOW_MINIMUM in a refusal names the minimum', () {
      final text = friendlyError(
        'PROVIDER_NOT_FULFILMENT_READY: DOCUMENTS_UNVERIFIED,'
        'WALLET_BELOW_MINIMUM',
      );
      expect(text, contains('minimum balance'));
      expect(text, isNot(contains('WALLET_BELOW_MINIMUM')));
    });

    test('POSTING_FEE_INSUFFICIENT says nothing was charged or created', () {
      final text = friendlyError('POSTING_FEE_INSUFFICIENT: 25');
      expect(text, contains('nothing was charged'));
      expect(text, isNot(contains('POSTING_FEE_INSUFFICIENT')));
    });

    test('WALLET_BELOW_MINIMUM has a readiness remedy pointing at recharge',
        () {
      final remedy = ProviderReadiness.remedyFor('WALLET_BELOW_MINIMUM');
      expect(remedy.route, '/wallet/recharge');
      expect(remedy.action, 'Top up your wallet');
    });
  });
}
