-- Royal Crown FANGroup: персональные уведомления форума
-- Запускать в Supabase SQL Editor под владельцем проекта.
-- В этой версии форума rc_forum_topics.id и rc_forum_replies.id имеют тип bigint.

create table if not exists public.rc_forum_notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  actor_id uuid references auth.users(id) on delete set null,
  topic_id bigint references public.rc_forum_topics(id) on delete cascade,
  reply_id bigint references public.rc_forum_replies(id) on delete cascade,
  type text not null check (type in ('new_topic','new_reply','new_like')),
  message text not null,
  created_at timestamptz not null default now(),
  read_at timestamptz
);

create index if not exists rc_forum_notifications_user_created_idx
  on public.rc_forum_notifications(user_id, created_at desc);
create index if not exists rc_forum_notifications_unread_idx
  on public.rc_forum_notifications(user_id) where read_at is null;

alter table public.rc_forum_notifications enable row level security;

drop policy if exists "Users read own notifications" on public.rc_forum_notifications;
create policy "Users read own notifications"
  on public.rc_forum_notifications for select to authenticated
  using (auth.uid() = user_id);

drop policy if exists "Users mark own notifications read" on public.rc_forum_notifications;
create policy "Users mark own notifications read"
  on public.rc_forum_notifications for update to authenticated
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

-- Запрещаем клиенту создавать и удалять уведомления напрямую.
drop policy if exists "No client notification inserts" on public.rc_forum_notifications;
drop policy if exists "No client notification deletes" on public.rc_forum_notifications;

create or replace function public.rc_forum_notify_new_topic()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  insert into public.rc_forum_notifications(user_id, actor_id, topic_id, type, message)
  select p.id, new.user_id, new.id, 'new_topic',
         'Новая тема на форуме: ' || left(new.title, 140)
  from public.rc_forum_profiles p
  where p.id <> new.user_id;
  return new;
end; $$;

create or replace function public.rc_forum_notify_new_reply()
returns trigger language plpgsql security definer set search_path = public
as $$
declare topic_owner uuid; topic_title text;
begin
  select t.user_id, t.title into topic_owner, topic_title
  from public.rc_forum_topics t where t.id = new.topic_id;
  if topic_owner is not null and topic_owner <> new.user_id then
    insert into public.rc_forum_notifications(user_id, actor_id, topic_id, reply_id, type, message)
    values (topic_owner, new.user_id, new.topic_id, new.id, 'new_reply',
            'Новый ответ в вашей теме: ' || left(coalesce(topic_title,'тема'), 140));
  end if;
  return new;
end; $$;

create or replace function public.rc_forum_notify_new_like()
returns trigger language plpgsql security definer set search_path = public
as $$
declare topic_owner uuid; topic_title text;
begin
  select t.user_id, t.title into topic_owner, topic_title
  from public.rc_forum_topics t where t.id = new.topic_id;
  if topic_owner is not null and topic_owner <> new.user_id then
    insert into public.rc_forum_notifications(user_id, actor_id, topic_id, type, message)
    values (topic_owner, new.user_id, new.topic_id, 'new_like',
            'Кому-то понравилась ваша тема: ' || left(coalesce(topic_title,'тема'), 140));
  end if;
  return new;
end; $$;

drop trigger if exists rc_forum_trg_notify_new_topic on public.rc_forum_topics;
create trigger rc_forum_trg_notify_new_topic after insert on public.rc_forum_topics
for each row execute function public.rc_forum_notify_new_topic();

drop trigger if exists rc_forum_trg_notify_new_reply on public.rc_forum_replies;
create trigger rc_forum_trg_notify_new_reply after insert on public.rc_forum_replies
for each row execute function public.rc_forum_notify_new_reply();

drop trigger if exists rc_forum_trg_notify_new_like on public.rc_forum_likes;
create trigger rc_forum_trg_notify_new_like after insert on public.rc_forum_likes
for each row execute function public.rc_forum_notify_new_like();

-- Важно: UPDATE policy выше разрешает менять только собственные строки.
-- Для строгого запрета изменения других полей (кроме read_at) включите
-- ограничение столбцов на уровне grants, если ранее не выдавались широкие права:
revoke insert, delete on public.rc_forum_notifications from anon, authenticated;
grant select on public.rc_forum_notifications to authenticated;
grant update (read_at) on public.rc_forum_notifications to authenticated;
