create table public.mw_teacher_profiles (
 owner_id uuid primary key references public.mw_staff(user_id) on delete cascade,
 display_name text not null check(length(trim(display_name)) between 1 and 80),
 headline text not null default '' check(length(headline)<=160),
 bio text not null default '' check(length(bio)<=5000),
 career text not null default '' check(length(career)<=6000),
 image_url text,
 inquiry_url text,
 tags text[] not null default '{}' check(cardinality(tags)<=5 and tags <@ array['힐링','체형교정','바디라인','근력·체력','유연성·가동성','리듬감','섬세한 집중','교류','에너제틱']::text[]),
 published boolean not null default false,
 approval_status text not null default 'draft' check(approval_status in ('draft','pending','approved','rejected')),
 review_note text not null default '',
 approved_by uuid references auth.users(id),
 approved_at timestamptz,
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now(),
 check(image_url is null or image_url like 'https://%'),
 check(inquiry_url is null or inquiry_url like 'https://%')
);
alter table public.mw_teacher_profiles enable row level security;
grant select on public.mw_teacher_profiles to anon;
grant select,insert,update,delete on public.mw_teacher_profiles to authenticated;
create policy mw_profiles_public on public.mw_teacher_profiles for select to anon,authenticated using (published and approval_status='approved');
create policy mw_profiles_staff_read on public.mw_teacher_profiles for select to authenticated using (public.mw_is_staff() and (owner_id=auth.uid() or public.mw_is_admin()));
create policy mw_profiles_insert on public.mw_teacher_profiles for insert to authenticated with check(public.mw_is_staff() and (owner_id=auth.uid() or public.mw_is_admin()));
create policy mw_profiles_update on public.mw_teacher_profiles for update to authenticated using(public.mw_is_staff() and (owner_id=auth.uid() or public.mw_is_admin())) with check(public.mw_is_staff() and (owner_id=auth.uid() or public.mw_is_admin()));
create policy mw_profiles_delete on public.mw_teacher_profiles for delete to authenticated using(public.mw_is_admin());
create trigger mw_profile_approval before insert or update on public.mw_teacher_profiles for each row execute function public.mw_guard_publication();
create function public.mw_profile_timestamp() returns trigger language plpgsql security invoker set search_path='' as $$begin new.updated_at=clock_timestamp();return new;end;$$;
revoke all on function public.mw_profile_timestamp() from public,anon,authenticated;
create trigger mw_profile_timestamp before update on public.mw_teacher_profiles for each row execute function public.mw_profile_timestamp();
