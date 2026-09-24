import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

class BirrTextField extends StatelessWidget {
  final String label;
  final String? hint;
  final TextEditingController? controller;
  final TextInputType? keyboardType;
  final bool obscure;
  final Widget? suffixIcon;
  final String? errorText;
  final bool enabled;
  final int maxLines;
  final String? Function(String?)? validator;
  final FocusNode? focusNode;
  final TextInputAction? textInputAction;
  final VoidCallback? onEditingComplete;
  final TextCapitalization? textCapitalization;
  final ValueChanged<String>? onChanged;

  const BirrTextField({
    super.key,
    required this.label,
    this.hint,
    this.controller,
    this.keyboardType,
    this.obscure = false,
    this.suffixIcon,
    this.errorText,
    this.enabled = true,
    this.maxLines = 1,
    this.validator,
    this.focusNode,
    this.textInputAction,
    this.onEditingComplete,
    this.textCapitalization,
    this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      keyboardType: keyboardType,
      obscureText: obscure,
      enabled: enabled,
      maxLines: maxLines,
      validator: validator,
      focusNode: focusNode,
      textInputAction: textInputAction,
      onEditingComplete: onEditingComplete,
      onChanged: onChanged,
      textCapitalization:
          textCapitalization ?? TextCapitalization.none,
      style: const TextStyle(fontSize: 15, color: AppTheme.textPrimary),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        errorText: errorText,
        suffixIcon: suffixIcon,
      ),
    );
  }
}
