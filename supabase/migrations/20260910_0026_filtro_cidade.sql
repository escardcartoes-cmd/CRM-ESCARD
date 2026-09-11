-- =============================================================================
-- MIGRATION 20260910_0026 — Filtro por cidade no Funil e no Follow-up
-- Projeto: CRM Funil de Vendas (Escard) · Supabase heevguvboffziehftucp
-- Depende de: 0010 (filtro por lista — assinaturas atuais das 4 RPCs)
-- Aplicada em produção em 10/09/2026 via MCP (apply_migration).
-- =============================================================================
-- As quatro RPCs do Funil e do Follow-up ganham UM parâmetro novo, com default:
--
--   p_cidade text default null — filtra por uma cidade (igualdade exata com
--                                deals.city, que já é normalizada pelo importador
--                                e pela fn_desmojibake da 0022; índice
--                                idx_deals_city já existe)
--
-- Com o default, o comportamento é IDÊNTICO ao de hoje. Um frontend antigo que
-- não envie o parâmetro continua funcionando sem alteração.
--
-- Nova RPC cidades_disponiveis(): alimenta o datalist do filtro. NÃO é security
-- definer — roda com a RLS de quem chamou, então o vendedor só enxerga as
-- cidades em que ele tem lead (mesmo critério de listas_importadas).
--
-- Por que DROP + CREATE e não CREATE OR REPLACE: a função é identificada por
-- nome + tipos dos argumentos. CREATE OR REPLACE com um parâmetro a mais NÃO
-- substitui — cria uma SOBRECARGA, o PostgREST fica com duas candidatas e
-- devolve PGRST203 (ambíguo). Dropar e recriar na MESMA transação é atômico.
--
-- Por que o predicado de cidade entra no ON do left join em kanban_contagem
-- (e não no WHERE): no WHERE ele mataria as etapas sem nenhum lead da cidade
-- e a coluna sumiria do Kanban em vez de aparecer zerada.
--
-- Os corpos abaixo são os do banco vivo (pg_get_functiondef), com UMA linha nova
-- de predicado em cada. Busca, ordenação, paginação e retorno intactos.
--
-- DROP apaga também a ACL da função. Por isso o bloco 6 refaz os grants
-- exatamente como estavam: authenticated + service_role, nada para anon/public.
-- =============================================================================

begin;

-- =============================================================================
-- 1. KANBAN — cards por etapa
-- =============================================================================
drop function if exists public.kanban_cards(uuid, uuid, text, integer, integer, text, boolean);

create function public.kanban_cards(
  p_stage     uuid,
  p_owner     uuid    default null::uuid,
  p_busca     text    default null::text,
  p_limit     integer default 100,
  p_offset    integer default 0,
  p_lista     text    default null::text,
  p_sem_lista boolean default false,
  p_cidade    text    default null::text
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
as $$
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
    and (p_cidade is null or p_cidade = '' or d.city = p_cidade)
  order by d.created_at desc
  limit p_limit offset p_offset;
$$;

-- =============================================================================
-- 2. KANBAN — contagem e soma por etapa
-- =============================================================================
drop function if exists public.kanban_contagem(uuid, text, text, boolean);

create function public.kanban_contagem(
  p_owner     uuid    default null::uuid,
  p_busca     text    default null::text,
  p_lista     text    default null::text,
  p_sem_lista boolean default false,
  p_cidade    text    default null::text
)
returns table (
  stage_id   uuid,
  total      bigint,
  soma_valor numeric
)
language sql
stable
set search_path to 'public'
as $$
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
   and (p_cidade is null or p_cidade = '' or d.city = p_cidade)
  group by s.id;
$$;

-- =============================================================================
-- 3. FOLLOW-UP — lista paginada
-- =============================================================================
drop function if exists public.followups_list(text, text, uuid, integer, uuid, integer, integer, text, boolean);

create function public.followups_list(
  p_filtro    text    default 'esteira'::text,
  p_busca     text    default null::text,
  p_owner     uuid    default null::uuid,
  p_min_dias  integer default 0,
  p_stage     uuid    default null::uuid,
  p_limit     integer default 50,
  p_offset    integer default 0,
  p_lista     text    default null::text,
  p_sem_lista boolean default false,
  p_cidade    text    default null::text
)
returns table (
  id                 uuid,
  title              text,
  contact_name       text,
  contact_phone      text,
  whatsapp           text,
  contact_email      text,
  value              numeric,
  stage_id           uuid,
  stage_name         text,
  owner_id           uuid,
  owner_name         text,
  next_followup_date date,
  ultima_atividade   timestamp with time zone,
  dias_parado        integer,
  total_atividades   bigint,
  total_registros    bigint
)
language sql
stable
set search_path to 'public'
as $$
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
              where a.deal_id = d.id
                and a.outcome in ('atendeu','respondeu','realizada')
            ) at time zone 'America/Sao_Paulo',
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
      and (p_cidade is null or p_cidade = '' or d.city = p_cidade)
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
$$;

-- =============================================================================
-- 4. FOLLOW-UP — contadores dos cards e das etapas
-- =============================================================================
drop function if exists public.followups_contadores(uuid, integer, uuid, text, boolean);

create function public.followups_contadores(
  p_owner     uuid    default null::uuid,
  p_min_dias  integer default 0,
  p_stage     uuid    default null::uuid,
  p_lista     text    default null::text,
  p_sem_lista boolean default false,
  p_cidade    text    default null::text
)
returns jsonb
language sql
stable
set search_path to 'public'
as $$
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
              where a.deal_id = d.id
                and a.outcome in ('atendeu','respondeu','realizada')
            ) at time zone 'America/Sao_Paulo',
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
      and (p_cidade is null or p_cidade = '' or d.city = p_cidade)
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
$$;

-- =============================================================================
-- 5. NOVA — cidades disponíveis para o datalist do filtro
--    Sem security definer: RLS do chamador. Ordena por volume, depois nome.
-- =============================================================================
create or replace function public.cidades_disponiveis()
returns table (cidade text, total bigint)
language sql
stable
set search_path to 'public', 'pg_temp'
as $$
  select d.city, count(*)::bigint
    from public.deals d
   where d.city is not null and d.city <> ''
   group by d.city
   order by 2 desc, 1 asc;
$$;

-- =============================================================================
-- 6. ACL — DROP zerou os grants; refaz exatamente o que existia
-- =============================================================================
revoke all on function public.kanban_cards(uuid, uuid, text, integer, integer, text, boolean, text)                          from public, anon;
revoke all on function public.kanban_contagem(uuid, text, text, boolean, text)                                               from public, anon;
revoke all on function public.followups_list(text, text, uuid, integer, uuid, integer, integer, text, boolean, text)         from public, anon;
revoke all on function public.followups_contadores(uuid, integer, uuid, text, boolean, text)                                 from public, anon;
revoke all on function public.cidades_disponiveis()                                                                          from public, anon;

grant execute on function public.kanban_cards(uuid, uuid, text, integer, integer, text, boolean, text)                       to authenticated, service_role;
grant execute on function public.kanban_contagem(uuid, text, text, boolean, text)                                            to authenticated, service_role;
grant execute on function public.followups_list(text, text, uuid, integer, uuid, integer, integer, text, boolean, text)      to authenticated, service_role;
grant execute on function public.followups_contadores(uuid, integer, uuid, text, boolean, text)                              to authenticated, service_role;
grant execute on function public.cidades_disponiveis()                                                                       to authenticated, service_role;

commit;

-- =============================================================================
-- CONFERÊNCIA (rodar separado, depois do commit) — cada nome UMA vez só
-- =============================================================================
-- select p.proname, pg_get_function_identity_arguments(p.oid), p.proacl
--   from pg_proc p join pg_namespace n on n.oid = p.pronamespace
--  where n.nspname = 'public'
--    and p.proname in ('kanban_cards','kanban_contagem','followups_list',
--                      'followups_contadores','cidades_disponiveis')
--  order by 1;
--
-- select * from public.cidades_disponiveis() limit 5;
-- select count(*) from public.kanban_contagem(p_cidade => 'Linhares');

-- =============================================================================
-- ROLLBACK (rodar separado, NUNCA no mesmo bloco da aplicação)
-- =============================================================================
-- 1) dropar as assinaturas NOVAS (a 0010 só dropa as de 5/7 argumentos, então
--    reexecutá-la sem este passo criaria sobrecarga → PGRST203):
--   drop function if exists public.kanban_cards(uuid, uuid, text, integer, integer, text, boolean, text);
--   drop function if exists public.kanban_contagem(uuid, text, text, boolean, text);
--   drop function if exists public.followups_list(text, text, uuid, integer, uuid, integer, integer, text, boolean, text);
--   drop function if exists public.followups_contadores(uuid, integer, uuid, text, boolean, text);
--   drop function if exists public.cidades_disponiveis();
-- 2) reexecutar integralmente 20260827_0010_filtro_lista.sql (recria as versões
--    sem p_cidade) e refazer os grants para authenticated + service_role.
-- O frontend só envia p_cidade quando o filtro está ativo: um index.html novo
-- sobre o banco revertido continua funcionando — só o filtro passa a dar erro.
