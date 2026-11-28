-- Fix host selfie verification dialog dismissal and deliver store gifts into chat + notifications.
-- Gift coin split remains unchanged: sender pays full coin_price; host receives the existing 50% host_share_coins.

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
 v_event uuid;
 v_balance bigint;
 v_result jsonb;
 v_sender_name text;
begin
 if v_sender is null then raise exception 'Authentication required'; end if;
 if p_request_id is null then raise exception 'Gift request ID is required'; end if;
 if target_host_id is null or target_host_id=v_sender then raise exception 'Choose another member'; end if;

 perform 1 from auth.users
 where id in (v_sender,target_host_id)
 order by id
 for update;

 select result into v_result
 from public.hearttalk_gift_requests
 where sender_id=v_sender and request_id=p_request_id;
 if v_result is not null then return v_result; end if;

 if exists(
  select 1 from public.blocked_users b
  where (b.blocker_id=v_sender and b.blocked_user_id=target_host_id)
     or (b.blocker_id=target_host_id and b.blocked_user_id=v_sender)
 ) then
  raise exception 'You cannot send a gift because this conversation is blocked';
 end if;

 if not exists(
  select 1
  from public.hosts h
  join public.host_applications a on a.user_id=h.user_id and a.status='approved'
  join public.host_kyc_documents d on d.user_id=h.user_id
       and d.document_type='video_selfie' and d.status='approved'
  where h.user_id=target_host_id and h.host_status='active'
 ) then
  raise exception 'Host is not approved';
 end if;

 select coin_price,title,emoji
 into v_price,v_title,v_emoji
 from public.hearttalk_gift_catalog
 where gift_code=selected_gift_code and active=true;

 if v_price is null then raise exception 'Gift is unavailable'; end if;
 if v_price<1 then raise exception 'Gift price is invalid'; end if;

 select coalesce(sum(amount),0)
 into v_balance
 from public.wallet_ledger
 where user_id=v_sender;

 if v_balance<v_price then raise exception 'Not enough coins'; end if;

 v_host_share:=floor(v_price*0.50)::integer;
 v_platform_share:=v_price-v_host_share;

 insert into public.wallet_ledger(user_id,amount,entry_type,reference_id)
 values(v_sender,-v_price,'spend','gift:'||public.gen_random_uuid()::text);

 insert into public.hearttalk_gift_events(
  sender_id,host_id,gift_code,coin_price,host_share_coins,platform_share_coins
 )
 values(v_sender,target_host_id,selected_gift_code,v_price,v_host_share,v_platform_share)
 returning id into v_event;

 insert into public.hearttalk_host_earnings(host_id,gift_event_id,earned_coins)
 values(target_host_id,v_event,v_host_share);

 select coalesce(nullif(trim(p.display_name),''),nullif(trim(p.username),''),'A HeartTalk member')
 into v_sender_name
 from public.profiles p
 where p.id=v_sender;

 if v_sender_name is null then v_sender_name:='A HeartTalk member'; end if;

 insert into public.messages(sender_id,receiver_id,message)
 values(
  v_sender,
  target_host_id,
  '[[GIFT]]'||jsonb_build_object(
   'gift_event_id',v_event,
   'gift_code',selected_gift_code,
   'title',v_title,
   'emoji',v_emoji,
   'coin_price',v_price,
   'host_earned_coins',v_host_share
  )::text
 );

 insert into public.notifications(user_id,kind,title,body,data)
 values(
  target_host_id,
  'gift_received',
  'You received a gift!',
  v_sender_name||' sent you '||coalesce(v_emoji,'🎁')||' '||v_title||'.',
  jsonb_build_object(
   'gift_event_id',v_event,
   'sender_id',v_sender,
   'sender_name',v_sender_name,
   'gift_code',selected_gift_code,
   'gift_title',v_title,
   'gift_emoji',v_emoji,
   'coin_price',v_price,
   'host_earned_coins',v_host_share,
   'conversation_user_id',v_sender
  )
 );

 v_result:=jsonb_build_object(
  'gift_event_id',v_event,
  'gift_code',selected_gift_code,
  'gift_title',v_title,
  'gift_emoji',v_emoji,
  'coin_price',v_price,
  'host_earned_coins',v_host_share,
  'platform_share_coins',v_platform_share,
  'status','delivered'
 );

 insert into public.hearttalk_gift_requests(sender_id,request_id,result)
 values(v_sender,p_request_id,v_result);

 return v_result;
end;
$function$;

revoke all on function public.hearttalk_send_gift(uuid,text,uuid) from public,anon;
grant execute on function public.hearttalk_send_gift(uuid,text,uuid) to authenticated;

with repair_events as (
 select e.id,e.sender_id,e.host_id,e.gift_code,e.coin_price,e.host_share_coins,e.created_at,
        c.title,c.emoji,
        coalesce(nullif(trim(p.display_name),''),nullif(trim(p.username),''),'A HeartTalk member') as sender_name
 from public.hearttalk_gift_events e
 join public.hearttalk_gift_catalog c on c.gift_code=e.gift_code
 left join public.profiles p on p.id=e.sender_id
 where e.id in (
  '1c9bf2da-f3bf-480a-b7f5-c0507216104b'::uuid,
  'f0b17f67-dd97-4a1c-9dd4-6319e6a859d0'::uuid
 )
)
insert into public.messages(sender_id,receiver_id,message,created_at)
select r.sender_id,r.host_id,
 '[[GIFT]]'||jsonb_build_object(
  'gift_event_id',r.id,
  'gift_code',r.gift_code,
  'title',r.title,
  'emoji',r.emoji,
  'coin_price',r.coin_price,
  'host_earned_coins',r.host_share_coins
 )::text,
 r.created_at
from repair_events r
where not exists(
 select 1 from public.messages m
 where m.sender_id=r.sender_id and m.receiver_id=r.host_id
   and left(m.message,8)='[[GIFT]]'
   and position(r.id::text in m.message)>0
);

with repair_events as (
 select e.id,e.sender_id,e.host_id,e.gift_code,e.coin_price,e.host_share_coins,e.created_at,
        c.title,c.emoji,
        coalesce(nullif(trim(p.display_name),''),nullif(trim(p.username),''),'A HeartTalk member') as sender_name
 from public.hearttalk_gift_events e
 join public.hearttalk_gift_catalog c on c.gift_code=e.gift_code
 left join public.profiles p on p.id=e.sender_id
 where e.id in (
  '1c9bf2da-f3bf-480a-b7f5-c0507216104b'::uuid,
  'f0b17f67-dd97-4a1c-9dd4-6319e6a859d0'::uuid
 )
)
insert into public.notifications(user_id,kind,title,body,data,created_at)
select r.host_id,'gift_received','You received a gift!',
       r.sender_name||' sent you '||coalesce(r.emoji,'🎁')||' '||r.title||'.',
       jsonb_build_object(
        'gift_event_id',r.id,
        'sender_id',r.sender_id,
        'sender_name',r.sender_name,
        'gift_code',r.gift_code,
        'gift_title',r.title,
        'gift_emoji',r.emoji,
        'coin_price',r.coin_price,
        'host_earned_coins',r.host_share_coins,
        'conversation_user_id',r.sender_id
       ),
       r.created_at
from repair_events r
where not exists(
 select 1 from public.notifications n
 where n.user_id=r.host_id
   and n.kind='gift_received'
   and n.data->>'gift_event_id'=r.id::text
);
