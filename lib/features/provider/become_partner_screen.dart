import 'dart:io';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/services/document_upload_service.dart';
import '../../core/services/provider_doc_gate.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/birr_text_field.dart';
import '../../core/widgets/document_upload_card.dart';
import '../../core/widgets/primary_button.dart';
import '../../core/utils/friendly_error.dart';

/// Become a Partner: apply to run a business on Aliob without making a new
/// account.
///
/// The same three steps a fresh provider signup takes — say which kind of
/// business, attach an identity document, describe the business — submitted
/// through the same approval pipeline. It is deliberately NOT a shortcut
/// around that pipeline: [submit_partner_application] inserts one
/// PENDING_APPROVAL provider_profiles row and lets
/// trg_provider_profiles_auto_setup do the rest, so an existing customer
/// applying here is reviewed by exactly the admin screen a new signup reaches,
/// and on approval ends up holding BOTH their USER role and the provider role.
class BecomePartnerScreen extends StatefulWidget {
  const BecomePartnerScreen({super.key});

  @override
  State<BecomePartnerScreen> createState() => _BecomePartnerScreenState();
}

class _BecomePartnerScreenState extends State<BecomePartnerScreen> {
  static const _types = <String, ({String label, String blurb, IconData icon})>{
    'SERVICE_PROVIDER': (
      label: 'Service Provider',
      blurb: 'List your business, products and professional services',
      icon: Icons.storefront_outlined,
    ),
    'VEHICLE_PROVIDER': (
      label: 'Vehicle Provider',
      blurb: 'Offer ride, delivery and transportation services',
      icon: Icons.local_shipping_outlined,
    ),
  };

  final _picker = ImagePicker();
  final _nameCtrl = TextEditingController();
  final _descCtrl = TextEditingController();
  final _idCtrl = TextEditingController();

  String? _type;
  String? _docType = 'NATIONAL_ID';
  File? _docFile;
  bool _submitting = false;
  String? _error;

  /// What the document is, when the type is OTHER. A dropdown entry that
  /// just says "Other" tells the reviewer nothing; the label is what turns
  /// the row into a reviewable document.
  final _otherLabelCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    final uid = Supabase.instance.client.auth.currentUser?.id;
    if (uid != null) _idCtrl.text = uid;
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _descCtrl.dispose();
    _idCtrl.dispose();
    _otherLabelCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickDoc() async {
    final picked = await _picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 1920,
      maxHeight: 1920,
      imageQuality: 85,
    );
    if (picked == null) return;
    setState(() {
      _docFile = File(picked.path);
      _error = null;
    });
  }

  Future<void> _submit() async {
    final type = _type;
    final name = _nameCtrl.text.trim();
    if (type == null) {
      setState(() => _error = 'Choose what kind of business you run.');
      return;
    }
    if (name.length < 2) {
      setState(() => _error = 'Enter your business name.');
      return;
    }
    if (_docFile == null || _docType == null) {
      setState(() => _error =
          'Attach one identity document so we can verify who you are.');
      return;
    }
    if (_docType == ProviderDocGate.otherDocType &&
        _otherLabelCtrl.text.trim().isEmpty) {
      setState(() => _error =
          'Say what the document is — the person who reviews it needs to know.');
      return;
    }

    final uid = Supabase.instance.client.auth.currentUser?.id;
    if (uid == null) {
      setState(() => _error = 'Please sign in again.');
      return;
    }

    setState(() {
      _submitting = true;
      _error = null;
    });

    // Documents first, exactly as signup does it. If the application is
    // refused afterwards the documents are already on file and a second
    // attempt reuses them; the reverse order would leave an application with
    // nothing to verify.
    try {
      await DocumentUploadService.instance.uploadAndRecord(
        file: _docFile!,
        userId: uid,
        documentType: _docType!,
        otherDocumentLabel: _docType == ProviderDocGate.otherDocType
            ? _otherLabelCtrl.text.trim()
            : null,
      );
    } catch (e) {
      setState(() {
        _submitting = false;
        _error = friendlyError(e, context: 'Could not upload the document');
      });
      return;
    }

    try {
      await Supabase.instance.client.rpc('submit_partner_application', params: {
        'p_provider_type': type,
        'p_business_name': name,
        'p_business_description':
            _descCtrl.text.trim().isEmpty ? null : _descCtrl.text.trim(),
        'p_owner_national_id': _idCtrl.text.trim(),
        'p_city': null,
        'p_kebele': null,
        'p_street_road': null,
      });
      if (!mounted) return;
      // The same destination a fresh provider signup lands on.
      context.go('/pending-approval');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = _messageFor(e);
      });
    }
  }

  String _messageFor(Object e) {
    final raw = e.toString();
    if (raw.contains('ALREADY_HAS_PENDING_PARTNER_APPLICATION')) {
      return 'You already have an application being reviewed.';
    }
    if (raw.contains('INVALID_PROVIDER_TYPE')) {
      return 'That kind of business cannot be applied for here.';
    }
    if (raw.contains('BUSINESS_NAME_REQUIRED')) {
      return 'Enter your business name.';
    }
    return friendlyError(e, context: 'Could not submit your application');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Become a Partner')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Run your business on Aliob',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            const Text(
              'Your account stays exactly as it is — you keep buying and '
              'booking as a customer, and gain a business alongside it once '
              'you are approved.',
              style: TextStyle(
                  fontSize: 13, color: AppTheme.textSecondary, height: 1.4),
            ),
            const SizedBox(height: 24),
            if (_error != null) ...[
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: AppTheme.error.withOpacity(0.08),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(_error!,
                    style: const TextStyle(
                        color: AppTheme.error, fontSize: 13)),
              ),
            ],
            const Text('What kind of business?',
                style: TextStyle(
                    fontSize: 14, fontWeight: FontWeight.w600)),
            const SizedBox(height: 10),
            for (final entry in _types.entries) ...[
              _TypeCard(
                icon: entry.value.icon,
                label: entry.value.label,
                blurb: entry.value.blurb,
                selected: _type == entry.key,
                onTap: () => setState(() => _type = entry.key),
              ),
              const SizedBox(height: 10),
            ],
            const SizedBox(height: 16),
            BirrTextField(
              label: 'Business name',
              controller: _nameCtrl,
            ),
            const SizedBox(height: 14),
            BirrTextField(
              label: 'What do you offer? (optional)',
              controller: _descCtrl,
              maxLines: 3,
            ),
            const SizedBox(height: 20),
            const Text('Identity document',
                style: TextStyle(
                    fontSize: 14, fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            const Text(
              'Choose the type — or Other if none fit, and say what it is.',
              style: TextStyle(fontSize: 12, color: AppTheme.textMuted),
            ),
            const SizedBox(height: 10),
            DropdownButtonFormField<String>(
              value: _docType,
              decoration: const InputDecoration(labelText: 'Document type'),
              items: [
                for (final e in ProviderDocGate.acceptedDocTypes.entries)
                  DropdownMenuItem(
                      value: e.key, child: Text(e.value)),
                // Same fourth choice the verification gate offers. NOT part
                // of acceptedDocTypes on purpose: that map is what the gate
                // iterates, and an Other document proves nothing about
                // identity until an administrator has looked at it.
                const DropdownMenuItem(
                    value: ProviderDocGate.otherDocType,
                    child: Text('Other')),
              ],
              onChanged: (v) => setState(() => _docType = v),
            ),
            if (_docType == ProviderDocGate.otherDocType) ...[
              const SizedBox(height: 14),
              TextField(
                controller: _otherLabelCtrl,
                textCapitalization: TextCapitalization.sentences,
                maxLength: 60,
                decoration: const InputDecoration(
                  labelText: 'What is this document?',
                  hintText: 'e.g. business licence, health certificate',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
            const SizedBox(height: 14),
            DocumentUploadCard(
              title: 'Identity document',
              subtitle: _docFile == null
                  ? 'Tap to choose a photo'
                  : _docFile!.uri.pathSegments.last,
              file: _docFile,
              isUploading: _submitting,
              error: null,
              onPick: _pickDoc,
              onRemove: () => setState(() => _docFile = null),
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: PrimaryButton(
                label: 'SUBMIT APPLICATION',
                isLoading: _submitting,
                onPressed: _submit,
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              'We review every application by hand, so it is not instant.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11, color: AppTheme.textMuted),
            ),
          ],
        ),
      ),
    );
  }
}

class _TypeCard extends StatelessWidget {
  const _TypeCard({
    required this.icon,
    required this.label,
    required this.blurb,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final String blurb;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppTheme.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? AppTheme.primaryGreen : AppTheme.cardBorder,
            width: selected ? 1.6 : 1,
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: (selected
                        ? AppTheme.primaryGreen
                        : AppTheme.textMuted)
                    .withOpacity(0.10),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon,
                  size: 20,
                  color:
                      selected ? AppTheme.primaryGreen : AppTheme.textMuted),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: const TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text(blurb,
                      style: const TextStyle(
                          fontSize: 12, color: AppTheme.textSecondary)),
                ],
              ),
            ),
            if (selected)
              const Icon(Icons.check_circle,
                  color: AppTheme.primaryGreen, size: 20),
          ],
        ),
      ),
    );
  }
}
