-- =============================================================================
-- MIGRATION 20260827_0010 — Filtro por lista de origem no Funil e no Follow-up
-- Projeto: CRM Funil de Vendas (Escard) · Supabase heevguvboffziehftucp
-- Depende de: 0009 (coluna deals.lista_origem)
-- =============================================================================
-- Quatro RPCs ganham dois parâmetros novos, ambos com default:
--
--   p_lista      text    default null   — filtra por uma lista específica
--   p_sem_lista  boolean default false  — só os leads SEM lista (backfill manual)
--
-- Com os dois no default, o comportamento é IDÊNTICO ao de hoje. Um frontend
-- antigo que não envie os parâmetros continua funcionando sem alteração.
--
-- Por que DROP + CREATE e não CREATE OR REPLACE:
-- no Postgres a função é identificada por nome + tipos dos argumentos. Um
-- CREATE OR REPLACE com um parâmetro a mais NÃO substitui: cria uma SOBRECARGA,
-- e aí o PostgREST fica com duas candidatas e devolve PGRST203 (ambíguo) —
-- o Kanban para de carregar. Dropar e recriar dentro da MESMA transação é
-- atômico: chamadas concorrentes esperam o lock, nenhuma vê a função ausente.
--
-- Os corpos abaixo são os do banco vivo (pg_get_functiondef), reindentados,
-- com UMA linha nova de predicado em cada. Nenhuma outra lógica foi tocada:
-- mesmos filtros de busca, mesma ordenação, mesma paginação, mesmo retorno.
--
-- Nenhuma das quatro é security definer — roda com a RLS de quem chamou.
-- Mantido assim de propósito.
-- =============================================================================

begin;

-- =============================================================================
-- 1. KANBAN — cards por etapa
-- =============================================================================
drop function if exists public.kanban_cards(uuid, uuid, text, integer, integer);

create or replace function public.kanban_cards(
  p_stage     uuid,
  p_owner     uuid    default null::uuid,
  p_busca     text    default null::text,
  p_limit     integer default 100,
  p_offset    integer default 0,
  p_lista     text    default null::text,
  p_sem_lista boolean default false
)
returns table (
  id                  uuid,
  title               text,
  value               numeric,
  contact_name        text,
  expected_close_date date,
  next_followup_date  date,
  stage_changed_at    timestamp with time zone,
  loss_reason         text,
  owner_id            uuid,
  owner_name          text,
  stage_id            uuid
)
language sql
stable
set search_path to 'public'
as $function$
  select
    d.id, d.title, d.value, d.contact_name,
    d.expected_close_date, d.next_followup_date, d.stage_changed_at,
    d.loss_reason, d.owner_id, p.full_name as owner_name, d.stage_id
  from public.deals d
  left join public.profiles p on p.id = d.owner_id
  where d.stage_id = p_stage
    and (p_owner is null or d.owner_id = p_owner)
    and (
      p_busca is null or p_busca = '' or
      d.title ilike '%' || p_busca || '%' or
      d.contact_name ilike '%' || p_busca || '%' or
      d.contact_email ilike '%' || p_busca || '%' or
      d.contact_phone ilike '%' || p_busca || '%'
    )
    and (case when p_sem_lista      then d.lista_origem is null
              when p_lista is null  then true
              else d.lista_origem = p_lista end)
  order by d.created_at desc
  limit p_limit offset p_offset;
$function$;

revoke all on function public.kanban_cards(uuid, uuid, text, integer, integer, text, boolean) from public, anon;
grant execute on function public.kanban_cards(uuid, uuid, text, integer, integer, text, boolean) to authenticated;


-- =============================================================================
-- 2. KANBAN — contagem e soma por etapa
-- =============================================================================
-- O predicado entra no ON do left join, não no where: no where ele mataria as
-- etapas sem nenhum lead da lista, e a coluna sumiria do Kanban em vez de
-- aparecer zerada.
drop function if exists public.kanban_contagem(uuid, text);

create or replace function public.kanban_contagem(
  p_owner     uuid    default null::uuid,
  p_busca     text    default null::text,
  p_lista     text    default null::text,
  p_sem_lista boolean default false
)
returns table (
  stage_id   uuid,
  total      bigint,
  soma_valor numeric
)
language sql
stable
set search_path to 'public'
as $function$
  select
    s.id as stage_id,
    count(d.id) as total,
    coalesce(sum(d.value), 0) as soma_valor
  from public.pipeline_stages s
  left join public.deals d
    on d.stage_id = s.id
   and (p_owner is null or d.owner_id = p_owner)
   and (
     p_busca is null or p_busca = '' or
     d.title ilike '%' || p_busca || '%' or
     d.contact_name ilike '%' || p_busca || '%' or
     d.contact_email ilike '%' || p_busca || '%' or
     d.contact_phone ilike '%' || p_busca || '%'
   )
   and (case when p_sem_lista      then d.lista_origem is null
             when p_lista is null  then true
             else d.lista_origem = p_lista end)
  group by s.id;
$function$;

revoke all on function public.kanban_contagem(uuid, text, text, boolean) from public, anon;
grant execute on function public.kanban_contagem(uuid, text, text, boolean) to authenticated;


-- =============================================================================
-- 3. FOLLOW-UP — lista
-- =============================================================================
drop function if exists public.followups_list(text, text, uuid, integer, uuid, integer, integer);

create or replace function public.followups_list(
  p_filtro    text    default 'esteira'::text,
  p_busca     text    default null::text,
  p_owner     uuid    default null::uuid,
  p_min_dias  integer default 0,
  p_stage     uuid    default null::uuid,
  p_limit     integer default 50,
  p_offset    integer default 0,
  p_lista     text    default null::text,
  p_sem_lista boolean default false
)
returns table (
  id                uuid,
  title             text,
  contact_name      text,
  contact_phone     text,
  whatsapp          text,
  contact_email     text,
  value             numeric,
  stage_id          uuid,
  stage_name        text,
  owner_id          uuid,
  owner_name        text,
  next_followup_date date,
  ultima_atividade  timestamp with time zone,
  dias_parado       integer,
  total_atividades  bigint,
  total_registros   bigint
)
language sql
stable
set search_path to 'public'
as $function$
  with base as (
    select
      d.*,
      s.name as stage_name,
      p.full_name as owner_name,
      (select max(a.occurred_at) from public.deal_activities a
        where a.deal_id = d.id) as ultima_atividade,
      (select count(*) from public.deal_activities a
        where a.deal_id = d.id) as total_atividades,
      extract(day from
        (now() at time zone 'America/Sao_Paulo')
        - coalesce(
            (select max(a.occurred_at) from public.deal_activities a
              where a.deal_id = d.id) at time zone 'America/Sao_Paulo',
            d.stage_changed_at at time zone 'America/Sao_Paulo',
            d.created_at at time zone 'America/Sao_Paulo'
          )
      )::int as dias_parado
    from public.deals d
    join public.pipeline_stages s on s.id = d.stage_id
    left join public.profiles p on p.id = d.owner_id
    where s.in_followup = true
      and s.is_won = false
      and s.is_lost = false
      and (p_owner is null or d.owner_id = p_owner)
      and (p_stage is null or d.stage_id = p_stage)
      and (
        p_busca is null or p_busca = '' or
        d.title ilike '%' || p_busca || '%' or
        d.contact_name ilike '%' || p_busca || '%' or
        d.cnpj ilike '%' || p_busca || '%'
      )
      and (case when p_sem_lista      then d.lista_origem is null
                when p_lista is null  then true
                else d.lista_origem = p_lista end)
  ),
  filtrado as (
    select * from base
    where dias_parado >= coalesce(p_min_dias, 0)
      and case p_filtro
            when 'esteira'   then true
            when 'atrasados' then next_followup_date < (now() at time zone 'America/Sao_Paulo')::date
            when 'hoje'      then next_followup_date = (now() at time zone 'America/Sao_Paulo')::date
            when 'semana'    then next_followup_date between
                                    (now() at time zone 'America/Sao_Paulo')::date
                                and (now() at time zone 'America/Sao_Paulo')::date + 7
            when 'sem_passo' then next_followup_date is null
            else true
          end
  )
  select
    f.id, f.title, f.contact_name, f.contact_phone, f.whatsapp,
    f.contact_email, f.value, f.stage_id, f.stage_name,
    f.owner_id, f.owner_name, f.next_followup_date, f.ultima_atividade,
    f.dias_parado, f.total_atividades,
    count(*) over () as total_registros
  from filtrado f
  order by f.dias_parado desc, f.next_followup_date asc nulls last
  limit p_limit offset p_offset;
$function$;

revoke all on function public.followups_list(text, text, uuid, integer, uuid, integer, integer, text, boolean) from public, anon;
grant execute on function public.followups_list(text, text, uuid, integer, uuid, integer, integer, text, boolean) to authenticated;


-- =============================================================================
-- 4. FOLLOW-UP — contadores
-- =============================================================================
drop function if exists public.followups_contadores(uuid, integer, uuid);

create or replace function public.followups_contadores(
  p_owner     uuid    default null::uuid,
  p_min_dias  integer default 0,
  p_stage     uuid    default null::uuid,
  p_lista     text    default null::text,
  p_sem_lista boolean default false
)
returns jsonb
language sql
stable
set search_path to 'public'
as $function$
  with hoje as (select (now() at time zone 'America/Sao_Paulo')::date as d),
  base as (
    select
      d.next_followup_date,
      d.stage_id,
      s.name as stage_name,
      s.order_index,
      extract(day from
        (now() at time zone 'America/Sao_Paulo')
        - coalesce(
            (select max(a.occurred_at) from public.deal_activities a
              where a.deal_id = d.id) at time zone 'America/Sao_Paulo',
            d.stage_changed_at at time zone 'America/Sao_Paulo',
            d.created_at at time zone 'America/Sao_Paulo'
          )
      )::int as dias_parado
    from public.deals d
    join public.pipeline_stages s on s.id = d.stage_id
    where s.in_followup = true
      and s.is_won = false
      and s.is_lost = false
      and (p_owner is null or d.owner_id = p_owner)
      and (case when p_sem_lista      then d.lista_origem is null
                when p_lista is null  then true
                else d.lista_origem = p_lista end)
  ),
  no_periodo as (
    select * from base where dias_parado >= coalesce(p_min_dias, 0)
  ),
  com_etapa as (
    select * from no_periodo where (p_stage is null or stage_id = p_stage)
  )
  select jsonb_build_object(
    'esteira',   (select count(*) from com_etapa),
    'atrasados', (select count(*) from com_etapa where next_followup_date < (select d from hoje)),
    'hoje',      (select count(*) from com_etapa where next_followup_date = (select d from hoje)),
    'semana',    (select count(*) from com_etapa where next_followup_date between (select d from hoje) and (select d from hoje) + 7),
    'sem_passo', (select count(*) from com_etapa where next_followup_date is null),
    'por_etapa', (
      select coalesce(jsonb_object_agg(stage_id, jsonb_build_object(
               'nome', stage_name, 'ordem', order_index, 'total', qtd)), '{}'::jsonb)
      from (
        select stage_id, stage_name, order_index, count(*) as qtd
        from no_periodo
        group by stage_id, stage_name, order_index
      ) t
    )
  );
$function$;

revoke all on function public.followups_contadores(uuid, integer, uuid, text, boolean) from public, anon;
grant execute on function public.followups_contadores(uuid, integer, uuid, text, boolean) to authenticated;

commit;

-- =============================================================================
-- CONFERÊNCIA (rodar depois do commit)
-- =============================================================================
-- Cada nome deve aparecer UMA vez só. Duas linhas = sobrecarga sobrando,
-- e o PostgREST vai devolver PGRST203 nas chamadas.
-- select p.proname, pg_get_function_identity_arguments(p.oid)
--   from pg_proc p join pg_namespace n on n.oid = p.pronamespace
--  where n.nspname = 'public'
--    and p.proname in ('kanban_cards','kanban_contagem','followups_list','followups_contadores')
--  order by 1;
--
-- select * from public.kanban_contagem();                         -- igual a hoje
-- select * from public.kanban_contagem(null, null, 'NOME DA LISTA');
-- select * from public.kanban_contagem(null, null, null, true);   -- leads sem lista

-- =============================================================================
-- ROLLBACK — recria as quatro na forma anterior
-- =============================================================================
-- begin;
--   drop function if exists public.kanban_cards(uuid, uuid, text, integer, integer, text, boolean);
--   drop function if exists public.kanban_contagem(uuid, text, text, boolean);
--   drop function if exists public.followups_list(text, text, uuid, integer, uuid, integer, integer, text, boolean);
--   drop function if exists public.followups_contadores(uuid, integer, uuid, text, boolean);
--   -- e recriar as quatro sem p_lista/p_sem_lista (corpo idêntico, menos a linha do case)
-- commit;
