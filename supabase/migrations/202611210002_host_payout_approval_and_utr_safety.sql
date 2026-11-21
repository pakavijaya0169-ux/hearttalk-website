-- Tighten manual host payout finalization: approval required and UTR cannot be reused.
create unique index if not exists hearttalk_host_payout_paid_utr_unique
 on public.hearttalk_host_payout_requests (lower(trim(utr)))
 where utr is not null and status='paid';

create or replace function public.admin_mark_host_payout_paid(p_request_id uuid,p_utr text,p_admin_note text default '')
returns boolean language plpgsql security definer set search_path='' as $$
declare v public.hearttalk_host_payout_requests%rowtype;
begin
 if auth.uid() is null or not public.is_hearttalk_admin() then raise exception 'Admin access required'; end if;
 if p_utr is null or char_length(trim(p_utr)) not between 6 and 100 then raise exception 'Enter valid UTR / UPI reference ID'; end if;
 select * into v from public.hearttalk_host_payout_requests where id=p_request_id for update;
 if not found or v.status<>'approved' then raise exception 'Only approved payout requests can be marked paid'; end if;
 update public.hearttalk_host_payout_requests
 set status='paid',utr=trim(p_utr),admin_note=coalesce(p_admin_note,''),reviewed_by=auth.uid(),reviewed_at=now(),paid_at=now(),updated_at=now()
 where id=p_request_id and status='approved';
 if not found then raise exception 'Request changed before payment could be recorded'; end if;
 return true;
end; $$;
revoke all on function public.admin_mark_host_payout_paid(uuid,text,text) from public,anon;
grant execute on function public.admin_mark_host_payout_paid(uuid,text,text) to authenticated;
