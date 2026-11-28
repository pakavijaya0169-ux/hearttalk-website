-- HeartTalk call billing: charge only fully completed minutes.
-- Voice = 1 coin per completed minute; Video = 2 coins per completed minute.
-- Host receives ₹0.50 cash value per billed Host reward coin.
create or replace function public.hearttalk_end_call(target_call_id uuid,final_status text default 'ended')
returns jsonb language plpgsql security definer set search_path='' as $function$
declare
 v_actor uuid:=auth.uid(); v_call public.call_sessions%rowtype;
 v_host uuid; v_user uuid; v_seconds integer; v_completed_minutes integer;
 v_rate integer; v_coins integer; v_host_share integer; v_platform_share integer; v_balance bigint;
begin
 if v_actor is null then raise exception 'Authentication required'; end if;
 if final_status not in ('rejected','ended','cancelled','busy') then raise exception 'Invalid final call status'; end if;
 select * into v_call from public.call_sessions where id=target_call_id and (caller_id=v_actor or callee_id=v_actor) for update;
 if not found then raise exception 'Call not found'; end if;
 if v_call.status not in ('ringing','accepted') then
  return jsonb_build_object('updated',false,'status',v_call.status,'charged_coins',v_call.charged_coins,'host_earned_coins',v_call.host_earned_coins,'billing_status',v_call.billing_status);
 end if;
 update public.call_sessions set status=final_status,ended_at=now() where id=target_call_id and status in ('ringing','accepted');
 if final_status<>'ended' or v_call.status<>'accepted' or v_call.started_at is null then
  return jsonb_build_object('updated',true,'status',final_status,'charged_coins',0,'host_earned_coins',0,'billing_status','not_billable');
 end if;
 select h.user_id into v_host from public.hosts h
 join public.host_applications a on a.user_id=h.user_id and a.status='approved'
 join public.host_kyc_documents d on d.user_id=h.user_id and d.document_type='video_selfie' and d.status='approved'
 where h.host_status='active' and h.user_id in (v_call.caller_id,v_call.callee_id) limit 1;
 if v_host is null then
  update public.call_sessions set billing_status='not_billable' where id=target_call_id;
  return jsonb_build_object('updated',true,'status','ended','charged_coins',0,'billing_status','not_billable');
 end if;
 v_user:=case when v_call.caller_id=v_host then v_call.callee_id else v_call.caller_id end;
 if not exists(select 1 from public.profiles p where p.id=v_user and lower(coalesce(p.gender,''))='male') then
  update public.call_sessions set billing_status='not_billable' where id=target_call_id;
  return jsonb_build_object('updated',true,'status','ended','charged_coins',0,'billing_status','not_billable');
 end if;
 v_seconds:=greatest(0,floor(extract(epoch from(now()-v_call.started_at)))::integer);
 v_completed_minutes:=floor(v_seconds/60.0)::integer;
 v_rate:=case when v_call.call_type='voice' then 1 else 2 end;
 v_coins:=v_completed_minutes*v_rate;
 v_host_share:=v_coins; v_platform_share:=v_coins;
 perform 1 from auth.users where id=v_user for update;
 select coalesce(sum(amount),0) into v_balance from public.wallet_ledger where user_id=v_user;
 if v_balance<v_coins then
  update public.call_sessions set billed_user_id=v_user,billed_host_id=v_host,billed_seconds=v_seconds,
   charged_coins=0,host_earned_coins=0,platform_earned_coins=0,billing_status='insufficient_coins'
  where id=target_call_id;
  return jsonb_build_object('updated',true,'status','ended','billed_seconds',v_seconds,'completed_minutes',v_completed_minutes,
   'required_coins',v_coins,'charged_coins',0,'billing_status','insufficient_coins');
 end if;
 if v_coins>0 then
  insert into public.wallet_ledger(user_id,amount,entry_type,reference_id) values(v_user,-v_coins,'spend','call_session:'||target_call_id::text);
 end if;
 update public.call_sessions set billed_user_id=v_user,billed_host_id=v_host,billed_seconds=v_seconds,
  charged_coins=v_coins,host_earned_coins=v_host_share,platform_earned_coins=v_platform_share,
  billing_status=case when v_coins=0 then 'no_charge' else 'charged' end where id=target_call_id;
 if v_coins>0 then
  insert into public.hearttalk_call_session_earnings(call_id,host_id,user_id,call_type,billed_seconds,charged_coins,earned_coins)
  values(target_call_id,v_host,v_user,v_call.call_type,v_seconds,v_coins,v_host_share) on conflict(call_id) do nothing;
 end if;
 return jsonb_build_object('updated',true,'status','ended','billed_seconds',v_seconds,'completed_minutes',v_completed_minutes,
  'charged_coins',v_coins,'host_earned_coins',v_host_share,'platform_earned_coins',v_platform_share,
  'host_earned_value_paise',v_host_share::bigint*50,'platform_earned_value_paise',v_platform_share::bigint*50,
  'billing_status',case when v_coins=0 then 'no_charge' else 'charged' end);
end;$function$;
revoke all on function public.hearttalk_end_call(uuid,text) from public,anon;
grant execute on function public.hearttalk_end_call(uuid,text) to authenticated;

-- Refund one overcharged coin from each 65s/73s Ayansh -> Sravya voice call.
insert into public.wallet_ledger(user_id,amount,entry_type,reference_id)
select c.billed_user_id,1,'refund','call_rounding_refund:'||c.id::text
from public.call_sessions c
where c.id in ('67b04a2c-a947-4c72-a9f8-b1cb7292e096'::uuid,'b1bd96ef-c6e9-4d63-a274-ded75478562a'::uuid)
 and c.call_type='voice' and c.status='ended' and c.billed_seconds between 60 and 119 and c.charged_coins=2
 and not exists(select 1 from public.wallet_ledger w where w.user_id=c.billed_user_id and w.entry_type='refund'
  and w.reference_id='call_rounding_refund:'||c.id::text);

update public.call_sessions set charged_coins=1,host_earned_coins=1,platform_earned_coins=1,billing_status='charged'
where id in ('67b04a2c-a947-4c72-a9f8-b1cb7292e096'::uuid,'b1bd96ef-c6e9-4d63-a274-ded75478562a'::uuid)
 and call_type='voice' and status='ended' and billed_seconds between 60 and 119 and charged_coins=2;

update public.hearttalk_call_session_earnings set charged_coins=1,earned_coins=1
where call_id in ('67b04a2c-a947-4c72-a9f8-b1cb7292e096'::uuid,'b1bd96ef-c6e9-4d63-a274-ded75478562a'::uuid)
 and call_id in (select id from public.call_sessions where call_type='voice' and status='ended' and billed_seconds between 60 and 119 and charged_coins=1);

update public.hearttalk_host_cash_ledger set amount_paise=50,
 note='Voice call earnings: 1 completed minute × 1 coin × ₹0.50 Host value'
where source_reference in ('call:67b04a2c-a947-4c72-a9f8-b1cb7292e096','call:b1bd96ef-c6e9-4d63-a274-ded75478562a')
 and entry_type='earning_credit' and amount_paise=100;
