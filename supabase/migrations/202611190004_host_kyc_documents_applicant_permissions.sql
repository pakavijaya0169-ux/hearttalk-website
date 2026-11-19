-- HeartTalk: allow applicants to read and insert their own host selfie KYC rows.
-- This does not expose other users' KYC documents or allow client-side approval.
grant select, insert on table public.host_kyc_documents to authenticated;

drop policy if exists "Applicants read own host KYC documents" on public.host_kyc_documents;
create policy "Applicants read own host KYC documents"
on public.host_kyc_documents for select to authenticated
using (user_id = auth.uid() or public.is_hearttalk_admin());

drop policy if exists "Applicants insert own pending selfie KYC" on public.host_kyc_documents;
create policy "Applicants insert own pending selfie KYC"
on public.host_kyc_documents for insert to authenticated
with check (
  user_id = auth.uid()
  and document_type = 'video_selfie'
  and status = 'pending'
  and exists (
    select 1 from public.host_applications a
    where a.user_id = auth.uid()
      and a.status in ('pending','under_review')
  )
);
