import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/birr_text_field.dart';
import '../../core/widgets/primary_button.dart';
import '../../core/services/review_service.dart';
import '../../core/utils/friendly_error.dart';

class ReviewFormScreen extends ConsumerStatefulWidget {
  final String? orderId;
  final String? productId;
  final String? providerId;

  const ReviewFormScreen({
    super.key,
    this.orderId,
    this.productId,
    this.providerId,
  });
  @override
  ConsumerState<ReviewFormScreen> createState() => _ReviewFormScreenState();
}

class _ReviewFormScreenState extends ConsumerState<ReviewFormScreen> {
  Map<String, dynamic>? _existing;
  int _rating = 0;
  String _targetType = 'PRODUCT';
  final _commentCtrl = TextEditingController();
  bool _loading = true;
  bool _submitting = false;
  String? _error;

  bool get _isEdit => _existing != null;

  /// Available review targets for this order (product and/or provider).
  List<({String type, String label})> get _targets => [
        if (widget.productId != null)
          (type: 'PRODUCT', label: 'Product'),
        if (widget.providerId != null)
          (type: 'PROVIDER', label: 'Provider'),
      ];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _commentCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final orderId = widget.orderId;
    if (orderId == null) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'Missing order reference';
        });
      }
      return;
    }
    try {
      final existing = await ReviewService.instance.getReviewForOrder(orderId);
      if (mounted) {
        setState(() {
          _existing = existing;
          if (existing != null) {
            _rating = (existing['rating'] as num).toInt();
            _targetType = existing['target_type'] as String? ?? 'PRODUCT';
            _commentCtrl.text = existing['comment'] as String? ?? '';
          } else {
            _targetType = widget.productId != null ? 'PRODUCT' : 'PROVIDER';
          }
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'Could not load your review';
        });
      }
    }
  }

  Future<void> _submit() async {
    if (_rating < 1) {
      setState(() => _error = 'Select a rating');
      return;
    }
    final orderId = widget.orderId;
    if (orderId == null) {
      setState(() => _error = 'Missing order reference');
      return;
    }
    final targetId =
        _targetType == 'PROVIDER' ? widget.providerId : widget.productId;
    if (targetId == null) {
      setState(() => _error = 'Missing review target');
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final svc = ReviewService.instance;
      final comment = _commentCtrl.text.trim();
      if (_isEdit) {
        await svc.updateReview(
          reviewId: _existing!['id'] as String,
          rating: _rating,
          comment: comment,
        );
      } else {
        await svc.submitReview(
          orderId: orderId,
          targetType: _targetType,
          targetId: targetId,
          rating: _rating,
          comment: comment,
        );
      }
      if (!mounted) return;
      setState(() => _submitting = false);
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Review submitted')));
      context.pop();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = friendlyError(e, context: 'Could not submit your review');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_isEdit ? 'Edit Review' : 'Leave a Review')),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: AppTheme.primaryGreen))
          : SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_error != null)
                    Container(
                      width: double.infinity,
                      margin: const EdgeInsets.only(bottom: 16),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: AppTheme.error.withOpacity(0.08),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(_error!,
                          style: const TextStyle(
                              fontSize: 13, color: AppTheme.error)),
                    ),
                  const Text('Your Rating',
                      style: TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: List.generate(5, (i) {
                      final star = i + 1;
                      return IconButton(
                        onPressed: _submitting
                            ? null
                            : () => setState(() => _rating = star),
                        icon: Icon(
                            star <= _rating
                                ? Icons.star
                                : Icons.star_border,
                            color: AppTheme.gold,
                            size: 36),
                      );
                    }),
                  ),
                  if (!_isEdit && _targets.length > 1) ...[
                    const SizedBox(height: 4),
                    const Text('Reviewing',
                        style: TextStyle(
                            fontSize: 13, color: AppTheme.textSecondary)),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        for (final t in _targets)
                          Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: ChoiceChip(
                              label: Text(t.label,
                                  style: const TextStyle(fontSize: 13)),
                              selected: _targetType == t.type,
                              onSelected: _submitting
                                  ? null
                                  : (_) =>
                                      setState(() => _targetType = t.type),
                            ),
                          ),
                      ],
                    ),
                  ],
                  if (_isEdit) ...[
                    const SizedBox(height: 8),
                    Text(
                        'Editing your ${_targetType == 'PROVIDER' ? 'provider' : 'product'} review',
                        style: const TextStyle(
                            fontSize: 12, color: AppTheme.textMuted)),
                  ],
                  const SizedBox(height: 20),
                  const Text('Comment (optional)',
                      style: TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 12),
                  BirrTextField(
                    label: 'Comment',
                    controller: _commentCtrl,
                    maxLines: 4,
                    hint: 'Share your experience',
                  ),
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    child: PrimaryButton(
                      label: _isEdit ? 'SAVE REVIEW' : 'SUBMIT REVIEW',
                      isLoading: _submitting,
                      onPressed: _submit,
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}