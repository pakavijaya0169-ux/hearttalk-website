-- Allow authenticated admin UI to invoke the KYC review RPC.
-- The function itself must retain its internal is_hearttalk_admin() authorization check.
revoke all on function public.admin_review_host_kyc_document(uuid,text,text) from public, anon;
grant execute on function public.admin_review_host_kyc_document(uuid,text,text) to authenticated;
