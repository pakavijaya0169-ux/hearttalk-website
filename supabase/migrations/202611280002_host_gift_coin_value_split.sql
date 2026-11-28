-- HeartTalk creator gift rewards: 1 gift coin = ₹0.50 Host earning + ₹0.50 HeartTalk share.
-- Host reward coins are tracked separately from spendable wallet coins to prevent double-spending and cash withdrawal of promotional bonuses.

alter table public.hearttalk_gift_events
 add column if not exists host_share_paise bigint,
 add column if not exists platform_share_paise bigint;

update public.hearttalk_gift_events
set host_share_paise=coalesce(host_share_paise,host_share_coins::bigint*50),
    platform_share_paise=coalesce(platform_share_paise,platform_share_coins::bigint*50)
where host_share_paise is null or platform_share_paise is null;

create or replace function public.hearttalk_send_gift(
 target_host_id uuid,
 selected_gift_code text,
 p_request_id uuid
) returns jsonb
language plpgsql
security definer
set search_path=''
as $function$
declare
 v_sender uuid:=auth.uid();
 v_price integer;
 v_title text;
 v_emoji text;
 v_host_share integer;
 v_platform_share integer;
 v_host_share_paise bigint;
 v_platform_share_paise bigint;
 v_event uuid;
 v_balance bigint;
 v_result jsonb;
 v_sender_name text;
begin
 if v_sender is null then raise exception 'Authentication required'; end if;
 if p_request_id is null then raise exception 'Gift request ID is required'; end if;
 if target_host_id is null or target_host_id=v_sender then raise exception 'Choose another member'; end if;
 perform 1 from auth.users where id in (v_sender,target_host_id) order by id for update;
 select result into v_result from public.hearttalk_gift_requests where sender_id=v_sender and request_id=p_request_id;
 if v_result is not null then return v_result; end if;
 if exists(select 1 from public.blocked_users b where (b.blocker_id=v_sender and b.blocked_user_id=target_host_id) or (b.blocker_id=target_host_id and b.blocked_user_id=v_sender)) then
  raise exception 'You cannot send a gift because this conversation is blocked';
 end if;
 if not exists(select 1 from public.hosts h join public.host_applications a on a.user_id=h.user_id and a.status='approved' join public.host_kyc_documents d on d.user_id=h.user_id and d.document_type='video_selfie' and d.status='approved' where h.user_id=target_host_id and h.host_status='active') then
  raise exception 'Host is not approved';
 end if;
 select coin_price,title,emoji into v_price,v_title,v_emoji from public.hearttalk_gift_catalog where gift_code=selected_gift_code and active=true;
 if v_price is null then raise exception 'Gift is unavailable'; end if;
 if v_price<1 then raise exception 'Gift price is invalid'; end if;
 select coalesce(sum(amount),0) into v_balance from public.wallet_ledger where user_id=v_sender;
 if v_balance<v_price then raise exception 'Not enough coins'; end if;

 v_host_share:=v_price;
 v_platform_share:=0;
 v_host_share_paise:=v_price::bigint*50;
 v_platform_share_paise:=v_price::bigint*50;

 insert into public.wallet_ledger(user_id,amount,entry_type,reference_id) values(v_sender,-v_price,'spend','gift:'||public.gen_random_uuid()::text);
 insert into public.hearttalk_gift_events(sender_id,host_id,gift_code,coin_price,host_share_coins,platform_share_coins,host_share_paise,platform_share_paise)
 values(v_sender,target_host_id,selected_gift_code,v_price,v_host_share,v_platform_share,v_host_share_paise,v_platform_share_paise)
 returning id into v_event;
 insert into public.hearttalk_host_earnings(host_id,gift_event_id,earned_coins) values(target_host_id,v_event,v_host_share);
 insert into public.hearttalk_host_cash_ledger(host_id,amount_paise,entry_type,reference_id,source_reference,note,created_by)
 values(target_host_id,v_host_share_paise,'earning_credit',v_event,'gift:'||v_event::text,'Gift earnings converted at ₹0.50 per Host coin',null)
 on conflict(host_id,source_reference) do nothing;

 select coalesce(nullif(trim(p.display_name),''),nullif(trim(p.username),''),'A HeartTalk member') into v_sender_name from public.profiles p where p.id=v_sender;
 if v_sender_name is null then v_sender_name:='A HeartTalk member'; end if;
 insert into public.messages(sender_id,receiver_id,message)
 values(v_sender,target_host_id,'[[GIFT]]'||jsonb_build_object('gift_event_id',v_event,'gift_code',selected_gift_code,'title',v_title,'emoji',v_emoji,'coin_price',v_price,'host_earned_coins',v_host_share,'host_earned_value_paise',v_host_share_paise,'platform_share_value_paise',v_platform_share_paise)::text);
 insert into public.notifications(user_id,kind,title,body,data)
 values(target_host_id,'gift_received','You received a gift!',v_sender_name||' sent you '||coalesce(v_emoji,'🎁')||' '||v_title||'.',
  jsonb_build_object('gift_event_id',v_event,'sender_id',v_sender,'sender_name',v_sender_name,'gift_code',selected_gift_code,'gift_title',v_title,'gift_emoji',v_emoji,'coin_price',v_price,'host_earned_coins',v_host_share,'host_earned_value_paise',v_host_share_paise,'platform_share_value_paise',v_platform_share_paise,'conversation_user_id',v_sender));
 v_result:=jsonb_build_object('gift_event_id',v_event,'gift_code',selected_gift_code,'gift_title',v_title,'gift_emoji',v_emoji,'coin_price',v_price,'host_earned_coins',v_host_share,'host_earned_value_paise',v_host_share_paise,'platform_share_coins',v_platform_share,'platform_share_value_paise',v_platform_share_paise,'status','delivered');
 insert into public.hearttalk_gift_requests(sender_id,request_id,result) values(v_sender,p_request_id,v_result);
 return v_result;
end;
$function$;
revoke all on function public.hearttalk_send_gift(uuid,text,uuid) from public,anon;
grant execute on function public.hearttalk_send_gift(uuid,text,uuid) to authenticated;

update public.hearttalk_gift_events
set host_share_coins=coin_price,platform_share_coins=0,
    host_share_paise=coin_price::bigint*50,platform_share_paise=coin_price::bigint*50
where id in ('1c9bf2da-f3bf-480a-b7f5-c0507216104b'::uuid,'f0b17f67-dd97-4a1c-9dd4-6319e6a859d0'::uuid);
update public.hearttalk_host_earnings he set earned_coins=e.coin_price
from public.hearttalk_gift_events e
where he.gift_event_id=e.id and e.id in ('1c9bf2da-f3bf-480a-b7f5-c0507216104b'::uuid,'f0b17f67-dd97-4a1c-9dd4-6319e6a859d0'::uuid);
insert into public.hearttalk_host_cash_ledger(host_id,amount_paise,entry_type,reference_id,source_reference,note,created_by)
select e.host_id,e.host_share_paise,'earning_credit',e.id,'gift:'||e.id::text,'Gift earnings converted at ₹0.50 per Host coin',null
from public.hearttalk_gift_events e
where e.id in ('1c9bf2da-f3bf-480a-b7f5-c0507216104b'::uuid,'f0b17f67-dd97-4a1c-9dd4-6319e6a859d0'::uuid)
on conflict(host_id,source_reference) do nothing;

update public.hearttalk_gift_requests gr
set result=gr.result||jsonb_build_object('host_earned_coins',e.coin_price,'host_earned_value_paise',e.coin_price::bigint*50,'platform_share_coins',0,'platform_share_value_paise',e.coin_price::bigint*50)
from public.hearttalk_gift_events e
where e.id in ('1c9bf2da-f3bf-480a-b7f5-c0507216104b'::uuid,'f0b17f67-dd97-4a1c-9dd4-6319e6a859d0'::uuid)
and gr.result->>'gift_event_id'=e.id::text;

update public.messages m
set message='[[GIFT]]'||(substring(m.message from 9)::jsonb||jsonb_build_object('host_earned_coins',e.coin_price,'host_earned_value_paise',e.coin_price::bigint*50,'platform_share_value_paise',e.coin_price::bigint*50))::text
from public.hearttalk_gift_events e
where e.id in ('1c9bf2da-f3bf-480a-b7f5-c0507216104b'::uuid,'f0b17f67-dd97-4a1c-9dd4-6319e6a859d0'::uuid)
and left(m.message,8)='[[GIFT]]' and position(e.id::text in m.message)>0;
update public.notifications n
set data=n.data||jsonb_build_object('host_earned_coins',e.coin_price,'host_earned_value_paise',e.coin_price::bigint*50,'platform_share_value_paise',e.coin_price::bigint*50)
from public.hearttalk_gift_events e
where e.id in ('1c9bf2da-f3bf-480a-b7f5-c0507216104b'::uuid,'f0b17f67-dd97-4a1c-9dd4-6319e6a859d0'::uuid)
and n.kind='gift_received' and n.data->>'gift_event_id'=e.id::text;
