import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/friendly_error.dart';
import '../../core/widgets/load_error_view.dart';

/// The queue of identity documents waiting for a human decision.
///
/// WHY THIS SCREEN HAD TO BE BUILT
/// --------------------------------
/// `review_user_document()` has existed since 20260927000030, is admin-only
/// server-side, writes an audit row and notifies the account. It was reachable
/// from exactly one place: a dialog inside the per-user row on
/// `AdminUserManagementScreen`. So the only way to review an identity document
/// was to know which person uploaded one, open Users, find that person, and
/// open their document — and the list of users is paginated by name. There was
/// no way to answer the question an administrator actually opens the admin
/// portal with: "whose documents am I waiting on?"
///
/// The consequence was not a dead button. It was a queue that could only be
/// worked from the other end, which for a platform taking signups means
/// accounts sit in MANUAL_REVIEW until somebody happens to browse the right
/// page. `SUSPECTED_FRAUD` — the one state that is time-critical — was the
/// hardest to reach of all.
///
/// The decision still goes through `review_user_document()` and never through a
/// direct UPDATE: `prevent_document_verification_forgery` refuses a client that
/// changes the column without `is_admin()`, and the RPC is what notifies the
/// account and writes the audit row.
///
/// WHY IT READS `user_documents` DIRECTLY
/// --------------------------------------
/// `user_documents_owner` (0022b) is `user_id = auth.uid() OR is_admin()`, so
/// an administrator can already select every row — this screen adds no read
/// surface. Names are fetched separately because `user_documents.user_id`
/// references the account table, which a migration may not name (the `auth`
/// schema does not resolve on the deploy connection, §7.1.4), so there is no
/// embeddable `profiles` relationship to rely on from here.
class AdminDocumentVerificationScreen extends StatefulWidget {
  const AdminDocumentVerificationScreen({super.key});

  @override
  State<AdminDocumentVerificationScreen> createState() =>
      _AdminDocumentVerificationScreenState();
}

class _AdminDocumentVerificationScreenState
    extends State<AdminDocumentVerificationScreen> {
  List<Map<String, dynamic>> _docs = const [];
  Map<String, String> _names = const {};
  bool _loading = true;
  bool _working = false;
  String? _error;
  String _filter = 'WAITING';

  /// The states a document can be in, per the
  /// `user_documents_verification_status_check` constraint that 20260927000030
  /// widened. Read from the constraint rather than invented here, because a
  /// filter for a value the database refuses is a filter that can only ever
  /// return nothing — and an empty queue reads as "nobody is waiting", which is
  /// the exact sentence this screen exists to contradict.
  static const _filters = <String, String>{
    'WAITING': 'Waiting',
    'SUSPECTED_FRAUD': 'Suspected fraud',
    'VERIFIED': 'Verified',
    'REJECTED': 'Rejected',
    'AUTO_APPROVED': 'Auto-approved',
    'ALL': 'Everything',
  };

  static const _labels = <String, String>{
    'NATIONAL_ID': 'National ID',
    'DRIVING_LICENSE': "Driving licence",
    'DRIVING_LICENSE_ID': "Driving licence (ID)",
    'PASSPORT': 'Passport',
    'TRADE_LICENSE': 'Trade licence',
    'OTHER': 'Other document',
  };

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final client = Supabase.instance.client;

      // WAITING is a UNION of two statuses rather than a value: PostgREST's
      // `in` filter is a real filter, so this is one round trip rather than
      // two, and there is no window where the two halves disagree.
      // `inFilter`, not `in` -- `in` is a Dart keyword. Every other screen in
      // this project uses `inFilter` for the same reason.
      final query = client.from('user_documents').select(
            'id, user_id, document_type, other_document_label, storage_path, '
            'verification_status, uploaded_at, verified_at, agent_verdict',
          );
      final rows = switch (_filter) {
        'WAITING' => await query.inFilter(
            'verification_status', const ['MANUAL_REVIEW', 'SUSPECTED_FRAUD'],
          ),
        'ALL' => await query,
        final status => await query.eq('verification_status', status),
      };

      final docs = List<Map<String, dynamic>>.from(rows as List);

      // Names in a second read rather than an embed: `user_documents.user_id`
      // points at the account table, which cannot be named here (see the class
      // comment). Deduplicated, because a queue of twenty documents from four
      // people should not ask for twenty profiles.
      final ids = <String>{
        for (final d in docs)
          if (d['user_id'] != null) d['user_id'] as String,
      }.toList();
      var names = <String, String>{};
      if (ids.isNotEmpty) {
        final profiles = await client
            .from('profiles')
            .select('id, full_name')
            .inFilter('id', ids);
        names = {
          for (final p in profiles as List)
            if (p['id'] != null)
              p['id'] as String: (p['full_name'] as String?)?.trim().isNotEmpty == true
                  ? (p['full_name'] as String).trim()
                  : 'Unnamed account',
        };
      }

      if (!mounted) return;
      setState(() {
        _docs = docs;
        _names = names;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = friendlyError(e, context: 'Could not load the document queue');
      });
    }
  }

  void _snack(String message, {bool bad = false}) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        backgroundColor: bad ? AppTheme.error : null,
      ));
  }

  /// The decision. A refusal requires a reason: the account is told only that
  /// the document was not accepted, so a bare "REJECTED" leaves them with
  /// nothing to act on and nothing to appeal with.
  Future<void> _review(Map<String, dynamic> doc, String decision) async {
    if (_working) return;
    String? note;
    if (decision == 'REJECTED') {
      note = await showDialog<String>(
        context: context,
        builder: (ctx) => const _RejectReasonDialog(),
      );
      if (note == null || !mounted) return;
    }

    setState(() => _working = true);
    try {
      await Supabase.instance.client.rpc('review_user_document', params: {
        'p_document_id': doc['id'],
        'p_decision': decision,
        'p_note': note,
      });
      if (!mounted) return;
      final who = _names[doc['user_id']] ?? 'The account';
      _snack(decision == 'VERIFIED'
          ? '$who is now verified'
          : 'Document rejected — $who was notified and told why');
      await _load();
    } catch (e) {
      if (mounted) {
        _snack(friendlyError(e, context: 'Could not save the decision'),
            bad: true);
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  /// The image, at full size, before a decision is made.
  ///
  /// `user-documents` is private, so this is a signed URL and not a public one.
  /// It is minted when the dialog opens rather than for the whole list, because
  /// a signed URL per row would mint one per document on a screen that may hold
  /// a hundred of them, and they expire.
  Future<void> _openFull(Map<String, dynamic> doc) async {
    final path = doc['storage_path'] as String?;
    if (path == null || path.isEmpty) {
      _snack('That document has no stored file.', bad: true);
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (ctx) => _FullDocumentDialog(
        storagePath: path,
        title: _labels[doc['document_type']] ?? 'Document',
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Document Verification'),
        actions: [
          IconButton(
            tooltip: 'Reload',
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: AppTheme.primaryGreen))
          : _error != null
              ? LoadErrorView(message: _error!, onRetry: _load)
              : Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _banner(),
                          const SizedBox(height: 14),
                          _filterChips(),
                          const SizedBox(height: 14),
                        ],
                      ),
                    ),
                    // Expanded, so the header stays put and the queue scrolls
                    // under it. A single ListView holding both would scroll the
                    // filter chips off the top on a long queue, which is how an
                    // administrator ends up unable to change the filter
                    // without scrolling back up.
                    Expanded(
                      child: _docs.isEmpty
                          ? ListView(
                              children: [_Empty(filter: _filter)],
                            )
                          : RefreshIndicator(
                              onRefresh: _load,
                              child: _rows(),
                            ),
                    ),
                  ],
                ),
    );
  }

  /// The rows, built lazily.
  ///
  /// Written as `for (final d in _docs)` children at first, which constructs
  /// every row — and every row signs a URL — before the first frame. On a
  /// queue of a hundred pending signups that is a hundred signed URLs for the
  /// dozen rows actually on screen, each expiring while the administrator is
  /// still scrolling. `ListView.builder` builds what is visible, and each
  /// [_DocThumb] signs its own.
  Widget _rows() {
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
      itemCount: _docs.length,
      itemBuilder: (_, i) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: _card(_docs[i]),
      ),
    );
  }

  Widget _banner() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.surfaceVariant,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.cardBorder),
      ),
      child: const Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.badge_outlined, size: 18, color: AppTheme.primaryGreenDark),
          SizedBox(width: 10),
          Expanded(
            child: Text(
              'Approving or refusing an ID unblocks the provider gate, notifies '
              'the account, and is recorded permanently. A refusal always asks '
              'for a reason, because the account is told what was wrong.',
              style: TextStyle(fontSize: 12, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }

  /// A `Wrap`, not a `Row`: six chips side by side overflow a 320pt screen,
  /// and an overflow at the top of the page is what pushed the rest of this
  /// screen off the bottom on a small handset.
  Widget _filterChips() {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final entry in _filters.entries)
          ChoiceChip(
            label: Text(entry.value),
            selected: _filter == entry.key,
            selectedColor: AppTheme.primaryGreen.withOpacity(0.18),
            onSelected: (_) {
              setState(() => _filter = entry.key);
              _load();
            },
          ),
      ],
    );
  }

  Widget _card(Map<String, dynamic> d) {
    final status = d['verification_status'] as String? ?? '';
    final decided = status == 'VERIFIED' ||
        status == 'REJECTED' ||
        status == 'AUTO_APPROVED';
    final verdict = (d['agent_verdict'] as Map?)?.cast<String, dynamic>();

    return DocumentReviewCard(
      status: status,
      typeLabel: _labels[d['document_type']] ?? 'Document',
      otherLabel: (d['other_document_label'] as String?)?.trim() ?? '',
      who: _names[d['user_id']] ?? 'Unnamed account',
      uploadedOn: (d['uploaded_at'] as String? ?? '').substring(0, 10),
      agentVerdict: verdict == null
          ? null
          : (verdict['reason'] ?? verdict['note'] ?? verdict['flag'])?.toString(),
      decided: decided,
      busy: _working,
      thumbnail: _DocThumb(path: d['storage_path'] as String?),
      onView: _working ? null : () => _openFull(d),
      onVerify: _working ? null : () => _review(d, 'VERIFIED'),
      onRefuse: _working ? null : () => _review(d, 'REJECTED'),
      onReload: _working ? null : _load,
    );
  }
}

/// One row of the document queue.
///
/// PUBLIC AND DATA-FREE ON PURPOSE. Every field is a plain string and the
/// thumbnail is a slot, so this row can be laid out in a widget test with no
/// Supabase client, no network and no credentials — which is the only way an
/// overflow here can be caught before it reaches a handset. The shape follows
/// `IncomeFilterChips` in admin_income_summary_screen.dart, extracted for the
/// same reason and tested the same way
/// (test/income_filter_chips_overflow_test.dart).
///
/// The layout rules it exists to hold, each of which is an overflow at some
/// text scale otherwise:
///   * the filter chips and the action row are `Wrap`s;
///   * the status pill is `Flexible`, because it is the one fixed-width item
///     competing with an `Expanded` column for the same 220dp;
///   * the account name is one line with an ellipsis, and the type and the
///     `OTHER` label wrap, so a long business name cannot push the pill off.
class DocumentReviewCard extends StatelessWidget {
  const DocumentReviewCard({
    super.key,
    required this.status,
    required this.typeLabel,
    required this.who,
    required this.uploadedOn,
    required this.decided,
    this.otherLabel = '',
    this.agentVerdict,
    this.busy = false,
    this.thumbnail,
    this.onView,
    this.onVerify,
    this.onRefuse,
    this.onReload,
  });

  final String status;
  final String typeLabel;
  final String otherLabel;
  final String who;
  final String uploadedOn;

  /// What the QR agent concluded, or null when it concluded nothing.
  final String? agentVerdict;

  /// True once the document has a terminal verdict, which removes the two
  /// decision buttons and leaves Reload.
  final bool decided;
  final bool busy;
  final Widget? thumbnail;
  final VoidCallback? onView;
  final VoidCallback? onVerify;
  final VoidCallback? onRefuse;
  final VoidCallback? onReload;

  static const _terminal = <String>{'VERIFIED', 'REJECTED', 'AUTO_APPROVED'};

  @override
  Widget build(BuildContext context) {
    final fraud = status == 'SUSPECTED_FRAUD';
    final resolved = _terminal.contains(status);

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: fraud
              ? AppTheme.error.withOpacity(0.45)
              : resolved
                  ? AppTheme.cardBorder
                  : AppTheme.primaryGreen.withOpacity(0.35),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (thumbnail != null) thumbnail!,
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      typeLabel,
                      style: const TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w700),
                    ),
                    if (otherLabel.isNotEmpty)
                      Text(otherLabel,
                          style: const TextStyle(
                              fontSize: 11.5, color: AppTheme.textSecondary)),
                    const SizedBox(height: 2),
                    Text(who,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12.5)),
                    Text('uploaded $uploadedOn',
                        style: const TextStyle(
                            fontSize: 10.5, color: AppTheme.textMuted)),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Flexible(child: _statusPill(status, fraud)),
            ],
          ),
          if (fraud && agentVerdict != null) ...[
            const SizedBox(height: 10),
            _agentVerdict(agentVerdict!),
          ],
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              OutlinedButton.icon(
                onPressed: busy ? null : onView,
                icon: const Icon(Icons.zoom_out_map, size: 16),
                label: const Text('View'),
              ),
              if (!resolved) ...[
                OutlinedButton.icon(
                  onPressed: busy ? null : onVerify,
                  icon: const Icon(Icons.check_circle_outline, size: 16),
                  label: const Text('Verify'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppTheme.primaryGreenDark,
                    side: const BorderSide(color: AppTheme.primaryGreen),
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: busy ? null : onRefuse,
                  icon: const Icon(Icons.cancel_outlined, size: 16),
                  label: const Text('Refuse'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppTheme.error,
                    side: const BorderSide(color: AppTheme.error),
                  ),
                ),
              ] else
                TextButton(
                  onPressed: busy ? null : onReload,
                  child: const Text('Reload'),
                ),
            ],
          ),
        ],
      ),
    );
  }

  static Widget _statusPill(String status, bool fraud) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: (fraud ? AppTheme.error : AppTheme.textMuted).withOpacity(0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        status.replaceAll('_', ' '),
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          color: fraud ? AppTheme.error : AppTheme.textSecondary,
        ),
      ),
    );
  }

  /// What the QR agent thought. A flagged document is the one an administrator
  /// is most likely to get wrong, and this is the only evidence they are given
  /// before deciding — so it is shown in full rather than truncated to a line.
  static Widget _agentVerdict(String reason) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppTheme.error.withOpacity(0.06),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        reason.trim().isEmpty
            ? 'The automatic check flagged this document.'
            : 'Automatic check: $reason',
        style: const TextStyle(fontSize: 11.5, height: 1.4),
      ),
    );
  }
}

/// One thumbnail, signing its own URL.
///
/// `user-documents` is **private**, so `getPublicUrl` returns a URL that 404s
/// for every row — which is exactly what the first version of this screen did,
/// and it looked like a screen full of broken images rather than a bug. A
/// thumbnail therefore mints a real signed URL, and it does so per row as that
/// row scrolls into view, so a queue of a hundred pending signups costs a dozen
/// signatures rather than a hundred.
class _DocThumb extends StatefulWidget {
  final String? path;
  const _DocThumb({required this.path});

  @override
  State<_DocThumb> createState() => _DocThumbState();
}

class _DocThumbState extends State<_DocThumb> {
  String? _url;
  bool _signing = true;

  @override
  void initState() {
    super.initState();
    _sign();
  }

  @override
  void didUpdateWidget(_DocThumb old) {
    super.didUpdateWidget(old);
    if (old.path != widget.path) _sign();
  }

  Future<void> _sign() async {
    final path = widget.path;
    if (path == null || path.isEmpty) {
      if (mounted) setState(() => _signing = false);
      return;
    }
    if (mounted) setState(() => _signing = true);
    try {
      final url = await Supabase.instance.client.storage
          .from('user-documents')
          .createSignedUrl(path, 300);
      if (!mounted) return;
      setState(() {
        _url = url;
        _signing = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _signing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 52,
      height: 52,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: AppTheme.creamDark,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.cardBorder),
      ),
      child: widget.path == null || widget.path!.isEmpty
          ? const Icon(Icons.description_outlined,
              size: 20, color: AppTheme.textMuted)
          : _signing
              ? const Padding(
                  padding: EdgeInsets.all(16),
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: AppTheme.primaryGreen),
                )
              : _url == null
                  ? const Icon(Icons.broken_image_outlined,
                      size: 20, color: AppTheme.textMuted)
                  : Image.network(
                      _url!,
                      fit: BoxFit.cover,
                      // One missing file out of a hundred must read as one
                      // broken tile, not as a screen that failed to load.
                      errorBuilder: (_, __, ___) => const Icon(
                          Icons.broken_image_outlined,
                          size: 20,
                          color: AppTheme.textMuted),
                    ),
    );
  }
}

class _FullDocumentDialog extends StatefulWidget {
  final String storagePath;
  final String title;
  const _FullDocumentDialog(
      {required this.storagePath, required this.title});

  @override
  State<_FullDocumentDialog> createState() => _FullDocumentDialogState();
}

class _FullDocumentDialogState extends State<_FullDocumentDialog> {
  String? _url;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _sign();
  }

  Future<void> _sign() async {
    try {
      // `user-documents` is private. Five minutes is long enough to look at a
      // document and decide, and short enough that a leaked URL is not a
      // permanent copy of somebody's passport.
      final url = await Supabase.instance.client.storage
          .from('user-documents')
          .createSignedUrl(widget.storagePath, 300);
      if (!mounted) return;
      setState(() {
        _url = url;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: ConstrainedBox(
        // Bounded on both axes so a portrait scan cannot overflow the dialog on
        // a short screen, which is the overflow this screen is most likely to
        // cause and the reason it is checked rather than assumed.
        constraints: const BoxConstraints(maxWidth: 420, maxHeight: 560),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 8, 6),
              child: Row(
                children: [
                  Expanded(
                    child: Text(widget.title,
                        style: const TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w700)),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            Flexible(
              child: _loading
                  ? const Padding(
                      padding: EdgeInsets.all(32),
                      child: CircularProgressIndicator(
                          color: AppTheme.primaryGreen),
                    )
                  : _url == null
                      ? const Padding(
                          padding: EdgeInsets.all(28),
                          child: Text(
                            'That file could not be opened. It may have been '
                            'removed, or the signed link could not be created.',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                                fontSize: 12.5,
                                color: AppTheme.textSecondary),
                          ),
                        )
                      : InteractiveViewer(
                          maxScale: 4,
                          child: Image.network(
                            _url!,
                            fit: BoxFit.contain,
                            errorBuilder: (_, __, ___) => const Padding(
                              padding: EdgeInsets.all(28),
                              child: Text(
                                'That image did not load.',
                                textAlign: TextAlign.center,
                              ),
                            ),
                          ),
                        ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

/// Refusal needs a reason, asked here so the dialog cannot be dismissed with
/// something the account will never be shown.
class _RejectReasonDialog extends StatefulWidget {
  const _RejectReasonDialog();

  @override
  State<_RejectReasonDialog> createState() => _RejectReasonDialogState();
}

class _RejectReasonDialogState extends State<_RejectReasonDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Refuse this document'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        maxLines: 3,
        maxLength: 300,
        decoration: const InputDecoration(
          labelText: 'Why',
          helperText:
              'Sent to the account verbatim. "Blurry" and "wrong document" '
              'are both things they can fix.',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: AppTheme.error),
          onPressed: () {
            final text = _controller.text.trim();
            if (text.length >= 3) Navigator.pop(context, text);
          },
          child: const Text('Refuse'),
        ),
      ],
    );
  }
}

class _Empty extends StatelessWidget {
  final String filter;
  const _Empty({required this.filter});

  @override
  Widget build(BuildContext context) {
    final waiting = filter == 'WAITING' || filter == 'ALL';
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 16),
      child: Column(
        children: [
          Icon(
            waiting ? Icons.task_alt : Icons.filter_alt_off_outlined,
            size: 30,
            color: AppTheme.textMuted.withOpacity(0.5),
          ),
          const SizedBox(height: 8),
          Text(
            waiting
                ? 'No document is waiting on you.'
                : 'Nothing with this status.',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 12.5, color: AppTheme.textMuted),
          ),
        ],
      ),
    );
  }
}
