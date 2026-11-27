-- Harden manual UPI host withdrawal settlement.
-- Only an approved request can be marked paid, and a UTR can settle only one request.

create unique index if not exists hearttalk_host_payout_paid_utr_unique_idx
on public.hearttalk_host_payout_requests (upper(btrim(utr)))
where status = 'paid' and utr is not null and btrim(utr) <> '';

create or replace function public.admin_mark_host_payout_paid(
 p_request_id uuid,
 p_utr text,
 p_admin_note text default ''
) returns boolean
language plpgsql
security definer
set search_path=''
as $$
declare
 v public.hearttalk_host_payout_requests%rowtype;
begin
 if auth.uid() is null or not public.has_hearttalk_admin_permission('withdrawals.manage') then
  raise exception 'Withdrawal management permission required';
 end if;

 if p_utr is null or char_length(btrim(p_utr)) not between 6 and 100 then
  raise exception 'Enter valid UTR / UPI reference ID';
 end if;

 select * into v
 from public.hearttalk_host_payout_requests
 where id=p_request_id
 for update;

 if not found or v.status <> 'approved' then
  raise exception 'Only an approved withdrawal can be marked paid';
 end if;

 if exists (
  select 1
  from public.hearttalk_host_payout_requests
  where upper(btrim(utr))=upper(btrim(p_utr))
    and status='paid'
    and id<>p_request_id
 ) then
  raise exception 'This UTR has already been used';
 end if;

 update public.hearttalk_host_payout_requests
 set status='paid',
     utr=btrim(p_utr),
     admin_note=coalesce(p_admin_note,''),
     reviewed_by=auth.uid(),
     reviewed_at=now(),
     paid_at=now(),
     updated_at=now()
 where id=p_request_id and status='approved';

 if not found then
  raise exception 'Withdrawal status changed; refresh and try again';
 end if;

 insert into public.hearttalk_admin_audit_log(admin_user_id,action,target_type,target_id,details)
 values(
  auth.uid(),
  'host_payout_marked_paid',
  'payout',
  p_request_id::text,
  jsonb_build_object(
   'host_id',v.host_id,
   'amount_paise',v.amount_paise,
   'utr',btrim(p_utr)
  )
 );

 return true;
end;
$$;

revoke all on function public.admin_mark_host_payout_paid(uuid,text,text) from public,anon;
grant execute on function public.admin_mark_host_payout_paid(uuid,text,text) to authenticated;
