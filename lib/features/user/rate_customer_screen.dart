import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../core/services/review_service.dart';
import '../../core/utils/friendly_error.dart';

/// Rate the customer on a completed order.
///
/// The mirror of ReviewFormScreen: same 1–5 stars and comment, opposite
/// direction. It is a separate screen rather than a flag on that one because
/// the two halves have nothing in common but a widget — the target is always
/// a USER, the reviewer is the provider, and the order is one they served
/// rather than one they bought. Reusing the screen would mean a form whose
/// target list is always a single hard-coded row.
///
/// The server enforces the same rule from the other side (reviews_provider_insert
/// in 20260927000056): the order must be COMPLETED, must belong to the
/// customer being rated, and the caller must own the provider profile on it.
class RateCustomerScreen extends StatefulWidget {
  const RateCustomerScreen({
    super.key,
    required this.orderId,
    required this.customerId,
    this.customerName,
  });

  final String orderId;

  /// The customer's auth user id — reviews.target_id for target_type 'USER'.
  final String customerId;
  final String? customerName;

  @override
  State<RateCustomerScreen> createState() => _RateCustomerScreenState();
}

class _RateCustomerScreenState extends State<RateCustomerScreen> {
  int _rating = 0;
  final _commentCtrl = TextEditingController();
  bool _saving = false;
  bool _alreadyDone = false;

  @override
  void initState() {
    super.initState();
    _checkExisting();
  }

  @override
  void dispose() {
    _commentCtrl.dispose();
    super.dispose();
  }

  Future<void> _checkExisting() async {
    try {
      final existing =
          await ReviewService.instance.getReviewForOrder(widget.orderId);
      if (existing != null && mounted) {
        setState(() {
          _alreadyDone = true;
          _rating = (existing['rating'] as num?)?.toInt() ?? 0;
          _commentCtrl.text = existing['comment'] as String? ?? '';
        });
      }
    } catch (_) {
      // A failed read is not a reason to block the form; submitting will hit
      // the unique constraint and report it properly if it already exists.
    }
  }

  Future<void> _submit() async {
    if (_rating < 1) {
      _toast('Please choose a star rating.');
      return;
    }
    setState(() => _saving = true);
    try {
      final service = ReviewService.instance;
      if (_alreadyDone) {
        final existing =
            await service.getReviewForOrder(widget.orderId);
        if (existing != null) {
          await service.updateReview(
            reviewId: existing['id'] as String,
            rating: _rating,
            comment: _commentCtrl.text.trim(),
          );
        }
      } else {
        await service.submitReview(
          orderId: widget.orderId,
          targetType: 'USER',
          targetId: widget.customerId,
          rating: _rating,
          comment: _commentCtrl.text.trim(),
        );
      }
      if (!mounted) return;
      _toast('Thanks — your rating was saved.');
      Navigator.of(context).pop();
    } catch (e) {
      if (mounted) _toast(friendlyError(e, context: 'Could not save'));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _toast(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  @override
  Widget build(BuildContext context) {
    final who = (widget.customerName ?? '').trim();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Rate Customer'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Text(
                who.isEmpty ? 'How was this customer?' : 'How was $who?',
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontSize: 17, fontWeight: FontWeight.w700),
              ),
            ),
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (var i = 1; i <= 5; i++)
                  IconButton(
                    onPressed: () => setState(() => _rating = i),
                    iconSize: 40,
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    constraints: const BoxConstraints(),
                    icon: Icon(
                      i <= _rating ? Icons.star : Icons.star_border,
                      color: AppTheme.gold,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Center(
              child: Text(
                _labelFor(_rating),
                style: const TextStyle(
                    fontSize: 13, color: AppTheme.textSecondary),
              ),
            ),
            const SizedBox(height: 24),
            TextField(
              controller: _commentCtrl,
              maxLines: 3,
              decoration: InputDecoration(
                labelText: 'Comment (optional)',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _saving ? null : _submit,
                style: FilledButton.styleFrom(
                  backgroundColor: AppTheme.primaryGreen,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                child: _saving
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : Text(_alreadyDone ? 'UPDATE RATING' : 'SUBMIT RATING',
                        style: const TextStyle(
                            fontWeight: FontWeight.w700)),
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'Ratings are attached to a completed order and can only be '
              'changed or removed by you or the customer.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11, color: AppTheme.textMuted),
            ),
          ],
        ),
      ),
    );
  }

  String _labelFor(int r) => switch (r) {
        1 => 'Very poor',
        2 => 'Poor',
        3 => 'Okay',
        4 => 'Good',
        5 => 'Excellent',
        _ => 'Tap a star to rate',
      };
}
