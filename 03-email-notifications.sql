create schema if not exists mw_private;
revoke all on schema mw_private from public,anon,authenticated;
create table mw_private.notification_config(singleton boolean primary key default true check(singleton),dispatch_key text not null);
insert into mw_private.notification_config(singleton,dispatch_key) values(true,gen_random_uuid()::text||gen_random_uuid()::text);
revoke all on mw_private.notification_config from public,anon,authenticated;
create table public.mw_notifications(
 id uuid primary key default gen_random_uuid(),
 event_key text not null unique,
 kind text not null check(kind in ('member_request','program_submission','test')),
 source_id uuid,
 payload jsonb not null default '{}',
 status text not null default 'pending' check(status in ('pending','sending','sent','failed','cancelled')),
 attempts integer not null default 0,
 lease_id uuid,
 lease_until timestamptz,
 first_attempt_at timestamptz,
 next_attempt_at timestamptz not null default now(),
 created_at timestamptz not null default now(),
 sent_at timestamptz,
 provider_id text,
 last_error text
);
alter table public.mw_notifications enable row level security;
revoke all on public.mw_notifications from public,anon,authenticated;
grant select on public.mw_notifications to authenticated;
grant all on public.mw_notifications to service_role;
create policy mw_notifications_admin_read on public.mw_notifications for select to authenticated using(public.mw_is_admin());
create index mw_notifications_pending on public.mw_notifications(next_attempt_at) where status in ('pending','sending');

-- Internal dispatch key stays in the database and is never returned to a browser.
create extension if not exists pg_net with schema extensions;
create or replace function public.mw_wake_notifications() returns void
language plpgsql security definer set search_path='' as $$
declare token text;
begin
 if not exists(select 1 from public.mw_notifications where (status='pending' and next_attempt_at<=now()) or (status='sending' and lease_until<now())) then return; end if;
 select dispatch_key into token from mw_private.notification_config where singleton;
 perform net.http_post(url:='https://hmdlrjzgzefuylfljdlc.supabase.co/functions/v1/send-admin-notifications',headers:=jsonb_build_object('Content-Type','application/json','x-mw-dispatch',token),body:='{}'::jsonb,timeout_milliseconds:=5000);
exception when others then
 -- Queue remains durable; the next scheduled run retries dispatch.
 return;
end;$$;
revoke all on function public.mw_wake_notifications() from public,anon,authenticated;
grant execute on function public.mw_wake_notifications() to service_role;

create function public.mw_queue_admin_notification() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if tg_table_name='mw_requests' then
  insert into public.mw_notifications(event_key,kind,source_id) values('request/'||new.id,'member_request',new.id) on conflict(event_key) do nothing;
 elsif new.approval_status='pending' then
  insert into public.mw_notifications(event_key,kind,source_id,payload)
  values('program/'||new.id||'/'||new.updated_at,'program_submission',new.id,jsonb_build_object('title',left(new.title,150),'teacher_name',left(new.teacher_name,80))) on conflict(event_key) do nothing;
 end if;
 perform public.mw_wake_notifications();return new;
end;$$;
revoke all on function public.mw_queue_admin_notification() from public,anon,authenticated;
create trigger mw_email_member_request after insert on public.mw_requests for each row execute function public.mw_queue_admin_notification();
create trigger mw_email_program_submission after insert or update on public.mw_programs for each row when(new.approval_status='pending') execute function public.mw_queue_admin_notification();

create function public.mw_claim_notifications(dispatch_key text,configured boolean)
returns setof public.mw_notifications language plpgsql security definer set search_path='' as $$
begin
 if dispatch_key is null or not exists(select 1 from mw_private.notification_config c where c.dispatch_key=mw_claim_notifications.dispatch_key) then raise exception 'unauthorized'; end if;
 if not configured then
  update public.mw_notifications set last_error='mail_configuration_missing' where status='pending';return;
 end if;
 -- Never blindly resend outside the provider's 24-hour deduplication window.
 update public.mw_notifications set status='failed',last_error='retry_window_expired'
 where status in ('pending','sending') and first_attempt_at<now()-interval '22 hours';
 update public.mw_notifications n set status='cancelled',last_error='request_removed'
 where n.kind='member_request' and n.status in ('pending','sending') and not exists(select 1 from public.mw_requests r where r.id=n.source_id);
 update public.mw_notifications n set status='cancelled',last_error='review_no_longer_pending'
 where n.kind='program_submission' and n.status in ('pending','sending') and not exists(select 1 from public.mw_programs p where p.id=n.source_id and p.approval_status='pending');
 update public.mw_notifications set status='failed',last_error=coalesce(last_error,'attempt_limit') where status in ('pending','sending') and attempts>=5 and (lease_until is null or lease_until<now());
 return query with picked as (
  select n.id from public.mw_notifications n where n.attempts<5 and ((n.status='pending' and n.next_attempt_at<=now()) or (n.status='sending' and n.lease_until<now())) order by n.created_at for update skip locked limit 5
 ) update public.mw_notifications n set status='sending',attempts=n.attempts+1,lease_id=gen_random_uuid(),lease_until=now()+interval '2 minutes',first_attempt_at=coalesce(n.first_attempt_at,now()),last_error=null from picked where n.id=picked.id returning n.*;
end;$$;
revoke all on function public.mw_claim_notifications(text,boolean) from public,anon,authenticated;
grant execute on function public.mw_claim_notifications(text,boolean) to service_role;

create function public.mw_finish_notification(notification_id uuid,claim_id uuid,delivered boolean,mail_id text default null,failure text default null)
returns boolean language plpgsql security definer set search_path='' as $$
declare row public.mw_notifications;
begin
 update public.mw_notifications n set status=case when delivered then 'sent' when attempts>=5 then 'failed' else 'pending' end,
 sent_at=case when delivered then now() else null end,provider_id=mail_id,last_error=case when delivered then null else left(failure,160) end,lease_until=null,
 next_attempt_at=now()+make_interval(mins=>power(2,least(attempts,5))::integer)
 where n.id=notification_id and n.status='sending' and n.lease_id=claim_id returning n.* into row;
 if not found then return false;end if;
 if row.kind='member_request' then update public.mw_requests set notification_status=case when delivered then 'sent' when row.status='failed' then 'failed' else 'pending' end where id=row.source_id;end if;
 return true;
end;$$;
revoke all on function public.mw_finish_notification(uuid,uuid,boolean,text,text) from public,anon,authenticated;
grant execute on function public.mw_finish_notification(uuid,uuid,boolean,text,text) to service_role;

select cron.schedule('mw-admin-mail-dispatch','* * * * *','select public.mw_wake_notifications()');
select cron.schedule('mw-admin-mail-retention','45 18 * * *',$job$delete from public.mw_notifications where status in ('sent','failed','cancelled') and created_at<now()-interval '90 days'$job$);
