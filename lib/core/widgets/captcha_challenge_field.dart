import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/captcha_service.dart';
import '../theme/app_theme.dart';

/// Reusable zero-setup CAPTCHA: the user ticks the box, solves the displayed
/// math, and the verified challenge id is returned to the enforcement call.
class CaptchaChallengeField extends StatefulWidget {
  final ValueChanged<String> onVerified;

  const CaptchaChallengeField({
    super.key,
    required this.onVerified,
  });

  @override
  State<CaptchaChallengeField> createState() => _CaptchaChallengeFieldState();
}

class _CaptchaChallengeFieldState extends State<CaptchaChallengeField> {
  final _answerController = TextEditingController();
  CaptchaChallenge? _challenge;
  bool _ticked = false;
  bool _loading = false;
  bool _verifying = false;
  bool _solved = false;
  String? _error;

  @override
  void dispose() {
    _answerController.dispose();
    super.dispose();
  }

  Future<void> _tickChanged(bool ticked) async {
    if (!ticked || _solved) return;
    setState(() {
      _ticked = true;
      _error = null;
    });
    await _loadChallenge();
  }

  Future<void> _loadChallenge() async {
    setState(() {
      _loading = true;
      _error = null;
      _challenge = null;
    });
    try {
      final challenge = await CaptchaService.instance.request();
      if (!mounted) return;
      setState(() {
        _challenge = challenge;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _ticked = false;
        _error = 'Could not load the security check. Tap the box to retry.';
      });
    }
  }

  Future<void> _verify() async {
    final challenge = _challenge;
    final answer = _answerController.text.trim();
    if (challenge == null || answer.isEmpty) return;

    setState(() {
      _verifying = true;
      _error = null;
    });
    try {
      await CaptchaService.instance.verify(challenge.id, answer);
      if (!mounted) return;
      setState(() {
        _verifying = false;
        _solved = true;
        _answerController.clear();
      });
      widget.onVerified(challenge.id);
    } on CaptchaException catch (e) {
      if (!mounted) return;
      _answerController.clear();
      setState(() {
        _verifying = false;
        _ticked = false;
        _challenge = null;
        _error = e.message;
      });
    } catch (_) {
      if (!mounted) return;
      _answerController.clear();
      setState(() {
        _verifying = false;
        _ticked = false;
        _challenge = null;
        _error = 'Could not check the answer. Tap the box to retry.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final success = _solved;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: success
            ? AppTheme.primaryGreen.withValues(alpha: 0.07)
            : AppTheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: success
              ? AppTheme.primaryGreen
              : _error != null
                  ? AppTheme.error
                  : AppTheme.cardBorder,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SizedBox(
                width: 24,
                height: 24,
                child: Checkbox(
                  value: success || _ticked,
                  activeColor: AppTheme.primaryGreen,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  onChanged: success || (_loading || _verifying)
                      ? null
                      : (value) => _tickChanged(value ?? false),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  success ? 'Security check complete' : 'I am not a robot',
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    color: AppTheme.textPrimary,
                  ),
                ),
              ),
              if (_loading)
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else if (success)
                const Icon(Icons.verified,
                    color: AppTheme.primaryGreen, size: 20),
            ],
          ),
          if (_ticked && !success) ...[
            const SizedBox(height: 12),
            if (_challenge != null) ...[
              Text(
                _challenge!.question,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.textPrimary,
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _answerController,
                      enabled: !_verifying,
                      keyboardType: TextInputType.number,
                      textInputAction: TextInputAction.done,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      decoration: InputDecoration(
                        hintText: 'Answer',
                        isDense: true,
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide:
                              const BorderSide(color: AppTheme.cardBorder),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: const BorderSide(
                            color: AppTheme.primaryGreen,
                            width: 1.5,
                          ),
                        ),
                      ),
                      onSubmitted: (_) => _verify(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton(
                    onPressed: _verifying ? null : _verify,
                    child: _verifying
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Check'),
                  ),
                ],
              ),
            ] else if (_loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text('Loading a fresh question…'),
              ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(
              _error!,
              style: const TextStyle(fontSize: 12, color: AppTheme.error),
            ),
          ],
        ],
      ),
    );
  }
}
