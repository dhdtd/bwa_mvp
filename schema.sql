-- Im Supabase SQL Editor ausführen
create table players(
  id uuid primary key default gen_random_uuid(),
  name text not null,
  foto_url text,
  aktiv boolean not null default true,
  token text unique not null default substr(md5(random()::text || clock_timestamp()::text),1,8)
);
create table rounds(
  id bigint generated always as identity primary key,
  label text not null,
  gegner text,
  opens_at timestamptz not null,
  closes_at timestamptz not null
);
create table nominations(
  round_id bigint references rounds on delete cascade,
  player_id uuid references players,
  primary key(round_id, player_id)
);
create table votes(
  round_id bigint references rounds on delete cascade,
  voter_id uuid references players,
  player_id uuid references players,
  created_at timestamptz default now(),
  primary key(round_id, voter_id)
);
create table settings(key text primary key, value text not null);
insert into settings values ('trainer_pin','AENDERN-1234');

-- Kein direkter Zugriff für anon: nur über die Funktionen unten
alter table players enable row level security;
alter table rounds enable row level security;
alter table nominations enable row level security;
alter table votes enable row level security;
alter table settings enable row level security;

create or replace function get_current_round(p_token text) returns json
language plpgsql security definer set search_path=public as $$
declare r rounds; v players; st text; voted uuid;
begin
  select * into v from players where token=p_token and aktiv;
  if v.id is null then return json_build_object('error','invalid_token'); end if;
  select * into r from rounds order by opens_at desc limit 1;
  if r.id is null then return json_build_object('state','none','player',v.name); end if;
  st := case when now()<r.opens_at then 'upcoming' when now()<=r.closes_at then 'open' else 'closed' end;
  select player_id into voted from votes where round_id=r.id and voter_id=v.id;
  return json_build_object(
    'state',st,'player',v.name,'voted',voted,
    'round',json_build_object('id',r.id,'label',r.label,'gegner',r.gegner,'opens_at',r.opens_at,'closes_at',r.closes_at),
    'nominees',(select coalesce(json_agg(json_build_object('id',p.id,'name',p.name,'foto_url',p.foto_url)),'[]'::json)
                from nominations n join players p on p.id=n.player_id where n.round_id=r.id),
    'results',case when st='closed' then
      (select coalesce(json_agg(json_build_object('name',p.name,'foto_url',p.foto_url,'votes',c.cnt) order by c.cnt desc),'[]'::json)
       from (select player_id, count(*) cnt from votes where round_id=r.id group by player_id) c
       join players p on p.id=c.player_id) end);
end $$;

create or replace function cast_vote(p_token text, p_round bigint, p_player uuid) returns text
language plpgsql security definer set search_path=public as $$
declare vid uuid; r rounds;
begin
  select id into vid from players where token=p_token and aktiv;
  if vid is null then return 'invalid_token'; end if;
  select * into r from rounds where id=p_round;
  if r.id is null or now() not between r.opens_at and r.closes_at then return 'closed'; end if;
  if not exists(select 1 from nominations where round_id=p_round and player_id=p_player) then return 'not_nominated'; end if;
  if vid=p_player then return 'self_vote'; end if;
  insert into votes(round_id,voter_id,player_id) values(p_round,vid,p_player);
  return 'ok';
exception when unique_violation then return 'already_voted';
end $$;

create or replace function trainer_players(p_pin text) returns json
language plpgsql security definer set search_path=public as $$
begin
  if p_pin is distinct from (select value from settings where key='trainer_pin') then raise exception 'Falsche PIN'; end if;
  return (select coalesce(json_agg(json_build_object('id',id,'name',name,'foto_url',foto_url) order by name),'[]'::json) from players where aktiv);
end $$;

create or replace function nominate(p_pin text, p_label text, p_gegner text, p_opens timestamptz, p_closes timestamptz, p_players uuid[]) returns bigint
language plpgsql security definer set search_path=public as $$
declare rid bigint;
begin
  if p_pin is distinct from (select value from settings where key='trainer_pin') then raise exception 'Falsche PIN'; end if;
  if coalesce(array_length(p_players,1),0)<>3 then raise exception 'Genau 3 Spieler nominieren'; end if;
  insert into rounds(label,gegner,opens_at,closes_at) values(p_label,p_gegner,p_opens,p_closes) returning id into rid;
  insert into nominations(round_id,player_id) select rid, unnest(p_players);
  return rid;
end $$;

grant execute on function get_current_round, cast_vote, trainer_players, nominate to anon;

-- Spieler anlegen (Beispiel), danach Tokens als persönliche Links verteilen:
-- insert into players(name) values ('Max Mustermann'),('Jonas Beispiel');
-- select name, token from players;
