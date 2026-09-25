import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';

/// Task 15: "Continue with Google" — the standard OAuth entry point used
/// by both the login and signup screens. Rendered to match the app's
/// light-card aesthetic; the G mark is drawn locally (no new packages).
class GoogleSignInButton extends StatelessWidget {
  final Future<void> Function() onPressed;
  final bool isLoading;
  final String label;

  const GoogleSignInButton({
    super.key,
    required this.onPressed,
    this.isLoading = false,
    this.label = 'Continue with Google',
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 48,
      child: OutlinedButton.icon(
        onPressed: isLoading ? null : onPressed,
        style: OutlinedButton.styleFrom(
          backgroundColor: Colors.white,
          side: const BorderSide(color: AppTheme.cardBorder),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
        icon: isLoading
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const _GoogleGMark(size: 18),
        label: Text(
          label,
          style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: AppTheme.textPrimary,
          ),
        ),
      ),
    );
  }
}

/// Minimal official G logo (four arcs) drawn with two CustomPainters so the
/// button needs no image assets and no additional dependency.
class _GoogleGMark extends StatelessWidget {
  final double size;
  const _GoogleGMark({required this.size});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(painter: _GoogleGPainter()),
    );
  }
}

class _GoogleGPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width;
    final stroke = s * 0.16;
    final rect = Rect.fromLTWH(stroke / 2, stroke / 2, s - stroke, s - stroke);

    final blue = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..color = const Color(0xFF4285F4)
      ..strokeCap = StrokeCap.butt;
    final green = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..color = const Color(0xFF34A853);
    final yellow = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..color = const Color(0xFFFBBC05);
    final red = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..color = const Color(0xFFEA4335);

    // Blue arc: top + right upper sweep.
    canvas.drawArc(rect, -0.55, 2.45, false, blue);
    // Green: bottom-left arc.
    canvas.drawArc(rect, 2.05, 1.05, false, green);
    // Yellow: left arc.
    canvas.drawArc(rect, 3.1, 0.95, false, yellow);
    // Red: top-left arc.
    canvas.drawArc(rect, 4.05, 1.05, false, red);

    // Horizontal bar into the center (the G's "mouth") in blue.
    final bar = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..color = const Color(0xFF4285F4);
    final cx = rect.center.dx;
    final cy = rect.center.dy;
    canvas.drawLine(
      Offset(cx + rect.width * 0.05, cy),
      Offset(rect.right - stroke / 2, cy),
      bar,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
