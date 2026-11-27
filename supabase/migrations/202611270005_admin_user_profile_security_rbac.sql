-- HeartTalk Admin RBAC: user registry, profile review and identity blacklist
-- Existing RPC signatures and data shapes are preserved.
create or replace function public.admin_list_user_registry(
  search_term text default null,status_filter text default 'all',country_filter text default null,
  date_from timestamptz default null,date_to timestamptz default null,result_limit integer default 200
)
returns table(user_id uuid,display_name text,username text,age integer,country text,state text,bio text,avatar_url text,
 account_status text,registered_at timestamptz,email text,phone text)
language plpgsql security definer set search_path=''
as $$
declare q text:=nullif(trim(coalesce(search_term,'')),'');
begin
 if auth.uid() is null then raise exception 'Authentication required'; end if;
 if not public.has_hearttalk_admin_permission('users.view') then raise exception 'User registry permission required'; end if;
 if status_filter not in ('all','active','blocked') then raise exception 'Invalid status filter'; end if;
 return query
 select p.id,p.display_name,p.username,p.age,p.country,p.state,p.bio,p.avatar_url,p.account_status,p.created_at,u.email::text,u.phone::text
 from public.profiles p join auth.users u on u.id=p.id
 where (status_filter='all' or p.account_status=status_filter)
 and (country_filter is null or country_filter='' or lower(coalesce(p.country,''))=lower(country_filter) or lower(coalesce(p.state,''))=lower(country_filter))
 and (date_from is null or p.created_at>=date_from) and (date_to is null or p.created_at<date_to)
 and (q is null or p.id::text ilike '%'||q||'%' or coalesce(p.display_name,'') ilike '%'||q||'%' or coalesce(p.username,'') ilike '%'||q||'%' or coalesce(u.email,'') ilike '%'||q||'%' or coalesce(u.phone,'') ilike '%'||q||'%')
 order by p.created_at desc limit greatest(1,least(coalesce(result_limit,200),500));
end; $$;

create or replace function public.admin_list_profile_review_queue()
returns table(user_id uuid,display_name text,username text,bio text,avatar_url text,country text,state text,status text,submitted_at timestamptz,review_note text)
language plpgsql security definer set search_path=''
as $$
begin
 if auth.uid() is null or not public.has_hearttalk_admin_permission('profiles.review') then raise exception 'Profile review permission required'; end if;
 return query select p.id,p.display_name,p.username,p.bio,p.avatar_url,p.country,p.state,q.status,q.submitted_at,q.review_note
 from public.profile_review_queue q join public.profiles p on p.id=q.profile_id
 where q.status='pending' order by q.submitted_at asc limit 500;
end; $$;

create or replace function public.admin_review_profile(target_user_id uuid,decision text,moderator_note text default null)
returns boolean language plpgsql security definer set search_path=''
as $$
begin
 if auth.uid() is null or not public.has_hearttalk_admin_permission('profiles.review') then raise exception 'Profile review permission required'; end if;
 if decision not in ('approved','rejected') then raise exception 'Decision must be approved or rejected'; end if;
 update public.profile_review_queue set status=decision,reviewed_at=now(),reviewed_by=auth.uid(),review_note=left(moderator_note,1000)
 where profile_id=target_user_id and status='pending';
 if not found then raise exception 'Pending profile review not found'; end if;
 insert into public.hearttalk_admin_audit_log(admin_user_id,action,target_type,target_id,details)
 values(auth.uid(),'profile_'||decision,'profile',target_user_id::text,jsonb_build_object('note',left(moderator_note,1000)));
 return true;
end; $$;

create or replace function public.admin_add_identity_blacklist(identifier_type text,identifier_hash text,reason text)
returns bigint language plpgsql security definer set search_path=''
as $$
declare new_id bigint;
begin
 if auth.uid() is null or not public.has_hearttalk_admin_permission('security.manage') then raise exception 'Security management permission required'; end if;
 if identifier_type not in ('device_token_hash','ip_hash') or identifier_hash !~ '^[a-f0-9]{64}$' then raise exception 'Invalid hashed identifier'; end if;
 insert into public.identity_blacklist(identifier_type,identifier_hash,reason,created_by)
 values(identifier_type,identifier_hash,left(reason,500),auth.uid())
 on conflict(identifier_type,identifier_hash) do update set active=true,reason=excluded.reason returning id into new_id;
 insert into public.hearttalk_admin_audit_log(admin_user_id,action,target_type,target_id,details)
 values(auth.uid(),'identity_blacklisted','identity_hash',new_id::text,jsonb_build_object('type',identifier_type,'reason',left(reason,500)));
 return new_id;
end; $$;

create or replace function public.admin_list_identity_blacklist()
returns table(id bigint,identifier_type text,identifier_hash text,reason text,created_at timestamptz,active boolean)
language plpgsql security definer set search_path=''
as $$
begin
 if auth.uid() is null or not public.has_hearttalk_admin_permission('security.manage') then raise exception 'Security management permission required'; end if;
 return query select b.id,b.identifier_type,b.identifier_hash,b.reason,b.created_at,b.active from public.identity_blacklist b order by b.created_at desc limit 500;
end; $$;

create or replace function public.admin_set_blacklist_active(target_id bigint,is_active boolean)
returns boolean language plpgsql security definer set search_path=''
as $$
begin
 if auth.uid() is null or not public.has_hearttalk_admin_permission('security.manage') then raise exception 'Security management permission required'; end if;
 update public.identity_blacklist set active=is_active where id=target_id;
 if not found then raise exception 'Blacklist entry not found'; end if;
 insert into public.hearttalk_admin_audit_log(admin_user_id,action,target_type,target_id,details)
 values(auth.uid(),'identity_blacklist_toggled','identity_hash',target_id::text,jsonb_build_object('active',is_active));
 return true;
end; $$;

revoke all on function public.admin_list_user_registry(text,text,text,timestamptz,timestamptz,integer) from public,anon;
revoke all on function public.admin_list_profile_review_queue() from public,anon;
revoke all on function public.admin_review_profile(uuid,text,text) from public,anon;
revoke all on function public.admin_add_identity_blacklist(text,text,text) from public,anon;
revoke all on function public.admin_list_identity_blacklist() from public,anon;
revoke all on function public.admin_set_blacklist_active(bigint,boolean) from public,anon;
grant execute on function public.admin_list_user_registry(text,text,text,timestamptz,timestamptz,integer) to authenticated;
grant execute on function public.admin_list_profile_review_queue() to authenticated;
grant execute on function public.admin_review_profile(uuid,text,text) to authenticated;
grant execute on function public.admin_add_identity_blacklist(text,text,text) to authenticated;
grant execute on function public.admin_list_identity_blacklist() to authenticated;
grant execute on function public.admin_set_blacklist_active(bigint,boolean) to authenticated;
