-- Task 9 — document-type choice moves to the upload step.
--
-- Signup no longer carries any document-type state (the id_doc_type
-- signup-metadata key is retired; nothing server-side ever consumed it).
-- The provider now chooses the document type AND uploads the document in
-- the same step, at the first protected action after wallet recharge
-- (ProviderDocGate sheet).
--
-- provider_docs_satisfied() is restated to match: the gate is satisfied by
-- AT LEAST ONE accepted identity document in user_documents whose status is
-- AUTO_APPROVED or MANUAL_REVIEW (SUSPECTED_FRAUD never counts), regardless
-- of which accepted type it is. The client gate helper implements exactly
-- the same rule.
--
-- No callers existed with the old two-type semantics (the function is a
-- documented server-side re-check), so restating it is safe.

create or replace function public.provider_docs_satisfied(p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.user_documents d
    where d.user_id = p_user_id
      and d.document_type in ('NATIONAL_ID', 'DRIVING_LICENSE', 'DRIVING_LICENSE_ID', 'PASSPORT')
      and coalesce(d.verification_status, 'MANUAL_REVIEW') in ('MANUAL_REVIEW', 'AUTO_APPROVED')
  );
$$;

grant execute on function public.provider_docs_satisfied(uuid) to authenticated;
