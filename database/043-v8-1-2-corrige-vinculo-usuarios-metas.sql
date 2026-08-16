begin;

-- Vincula participantes antigos ao cadastro atual sem alterar pagamentos ou entregas.
update public.weekly_goal_members gm
set member_record_id=m.id,
    member_name=m.name,
    discord_user_id=coalesce(m.discord_user_id,gm.discord_user_id),
    discord_channel_id=coalesce(m.discord_channel_id,gm.discord_channel_id),
    updated_at=now()
from public.members m
where gm.profile_id is not null
  and m.profile_id=gm.profile_id
  and (gm.member_record_id is distinct from m.id
    or gm.member_name is distinct from m.name
    or gm.discord_user_id is distinct from coalesce(m.discord_user_id,gm.discord_user_id)
    or gm.discord_channel_id is distinct from coalesce(m.discord_channel_id,gm.discord_channel_id));

-- Segunda tentativa segura para cadastros legados sem profile_id na participação.
update public.weekly_goal_members gm
set profile_id=m.profile_id,
    member_record_id=m.id,
    member_name=m.name,
    discord_user_id=coalesce(m.discord_user_id,gm.discord_user_id),
    discord_channel_id=coalesce(m.discord_channel_id,gm.discord_channel_id),
    updated_at=now()
from public.members m
where gm.member_record_id is null
  and m.discord_user_id is not null
  and gm.discord_user_id=m.discord_user_id;

-- Garante que futuras alterações de nome reflitam também nas metas vinculadas.
create or replace function public.sync_member_name_to_goals()
returns trigger language plpgsql security definer set search_path=public as $$
begin
 update weekly_goal_members
 set member_name=new.name,
     profile_id=coalesce(new.profile_id,profile_id),
     discord_user_id=coalesce(new.discord_user_id,discord_user_id),
     discord_channel_id=coalesce(new.discord_channel_id,discord_channel_id),
     updated_at=now()
 where member_record_id=new.id;
 return new;
end $$;

drop trigger if exists members_sync_name_to_goals on public.members;
create trigger members_sync_name_to_goals
after update of name,profile_id,discord_user_id,discord_channel_id on public.members
for each row execute function public.sync_member_name_to_goals();

notify pgrst,'reload schema';
commit;
