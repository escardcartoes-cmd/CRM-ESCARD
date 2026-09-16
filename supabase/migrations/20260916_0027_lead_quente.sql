-- =============================================================================
-- 0027 — Lead quente
--
-- Marcação manual, por lead, feita pelo consultor. Quem está marcado:
--   * aparece no topo da fila do Follow-up e da coluna do Funil;
--   * aparece na fila MESMO em etapa fora dela ("Sem Contato", "Leads Novos") --
--     a regra de negócio tira da fila o lead que ninguém escolheu; o quente foi
--     escolhido a dedo, um por um.
--   * desmarca a qualquer momento.
--
-- `quente_em` existe só para o frontend desbotar a marcação depois de 30 dias.
-- Nada expira sozinho no banco.
--
-- Rodar os blocos SEPARADAMENTE, na ordem. Rollback no fim, NAO executar junto.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- BLOCO 0 — PORTEIRA. Rode isto primeiro e leia a resposta.
-- -----------------------------------------------------------------------------
-- O BLOCO 2 reescreve kanban_cards a partir da versão que você me mostrou.
-- Se a 0019 (ordem de rediscagem em "Sem Contato") tiver sido aplicada, o
-- BLOCO 2 a apagaria. Se vier `true`, PARE e me avise antes de seguir.

select pg_get_functiondef(p.oid) like '%por_tentativa%' as tem_0019_aplicada
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname = 'kanban_cards';


-- -----------------------------------------------------------------------------
-- BLOCO 1 — coluna + índice
-- -----------------------------------------------------------------------------

alter table public.deals
  add column if not exists quente boolean not null default false;

alter table public.deals
  add column if not exists quente_em timestamptz;

-- Índice parcial: só as linhas marcadas entram. Em 13.565 leads com algumas
-- dezenas de quentes, o índice fica minúsculo.
create index if not exists deals_quente_idx
  on public.deals (quente)
  where quente;


-- -----------------------------------------------------------------------------
-- BLOCO 2 — kanban_cards: devolve `quente` e põe o quente no topo da coluna
--
-- Mudança de RETURNS TABLE exige drop + create. Em transação única para o
-- PostgREST nunca ver a função ausente, e o assinatura-de-argumentos fica
-- idêntica (não cria sobrecarga -> sem PGRST203).
-- -----------------------------------------------------------------------------

begin;

drop function if exists public.kanban_cards(uuid, uuid, text, integer, integer, text, boolean, text);

create function public.kanban_cards(
  p_stage uuid,
  p_owner uuid default null::uuid,
  p_busca text default null::text,
  p_limit integer default 100,
  p_offset integer default 0,
  p_lista text default null::text,
  p_sem_lista boolean default false,
  p_cidade text default null::text
)
returns table(
  id uuid, title text, value numeric, contact_name text,
  expected_close_date date, next_followup_date date,
  stage_changed_at timestamptz, loss_reason text,
  owner_id uuid, owner_name text, stage_id uuid,
  quente boolean, quente_em timestamptz
)
language sql
stable
set search_path to 'public'
as $function$
  select
    d.id, d.title, d.value, d.contact_name,
    d.expected_close_date, d.next_followup_date, d.stage_changed_at,
    d.loss_reason, d.owner_id, p.full_name as owner_name, d.stage_id,
    d.quente, d.quente_em
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
  order by d.quente desc, d.created_at desc
  limit p_limit offset p_offset;
$function$;

commit;


-- -----------------------------------------------------------------------------
-- BLOCO 3 — followups_list: quente fura a fila e vai para o topo
--
-- Três mudanças no corpo, marcadas com "-- 0027":
--   1. etapa fora da fila entra se o lead estiver quente
--   2. os filtros de data (atrasados/hoje/semana/sem_passo) e o p_min_dias não
--      escondem o quente
--   3. ordenação começa por quente
-- -----------------------------------------------------------------------------

begin;

drop function if exists public.followups_list(text, text, uuid, integer, uuid, integer, integer, text, boolean, text);

create function public.followups_list(
  p_filtro text default 'esteira'::text,
  p_busca text default null::text,
  p_owner uuid default null::uuid,
  p_min_dias integer default 0,
  p_stage uuid default null::uuid,
  p_limit integer default 50,
  p_offset integer default 0,
  p_lista text default null::text,
  p_sem_lista boolean default false,
  p_cidade text default null::text
)
returns table(
  id uuid, title text, contact_name text, contact_phone text, whatsapp text,
  contact_email text, value numeric, stage_id uuid, stage_name text,
  owner_id uuid, owner_name text, next_followup_date date,
  ultima_atividade timestamptz, dias_parado integer,
  total_atividades bigint, total_registros bigint,
  quente boolean, quente_em timestamptz
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
    where (s.in_followup = true or d.quente = true)   -- 0027: quente fura a fila
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
    where quente = true            -- 0027: filtro de data não esconde o quente
       or (
         dias_parado >= coalesce(p_min_dias, 0)
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
  )
  select
    f.id, f.title, f.contact_name, f.contact_phone, f.whatsapp,
    f.contact_email, f.value, f.stage_id, f.stage_name,
    f.owner_id, f.owner_name, f.next_followup_date, f.ultima_atividade,
    f.dias_parado, f.total_atividades,
    count(*) over () as total_registros,
    f.quente, f.quente_em
  from filtrado f
  order by f.quente desc,                                   -- 0027
           f.dias_parado desc, f.next_followup_date asc nulls last
  limit p_limit offset p_offset;
$function$;

commit;

notify pgrst, 'reload schema';


-- -----------------------------------------------------------------------------
-- BLOCO 4 — CONFERÊNCIA (rodar depois, um de cada vez)
-- -----------------------------------------------------------------------------

-- 4.1 — colunas criadas
-- select column_name, data_type, column_default
--   from information_schema.columns
--  where table_schema = 'public' and table_name = 'deals'
--    and column_name in ('quente','quente_em');

-- 4.2 — as duas RPCs devolvem `quente`
-- select p.proname, pg_get_function_result(p.oid) like '%quente%' as tem_quente
--   from pg_proc p join pg_namespace n on n.oid = p.pronamespace
--  where n.nspname = 'public' and p.proname in ('kanban_cards','followups_list');

-- 4.3 — teste de ponta a ponta: marque um lead de "Sem Contato" e veja se ele
--       aparece na fila. Troque o UUID pelo de um lead real dessa etapa.
-- update public.deals set quente = true, quente_em = now() where id = 'UUID-AQUI';
-- select id, title, stage_name, quente from public.followups_list('esteira') limit 5;
--   -> o lead marcado tem que estar na primeira linha
-- update public.deals set quente = false, quente_em = null where id = 'UUID-AQUI';


-- =============================================================================
-- ROLLBACK — NÃO executar junto com os blocos acima.
-- =============================================================================
-- Reverter as RPCs: reexecutar os corpos ANTERIORES (os que você me colou),
-- via drop + create, sem `quente`/`quente_em` no returns e sem as três marcas
-- "-- 0027" no followups_list.
--
-- Reverter as colunas (apaga as marcações feitas):
-- drop index if exists public.deals_quente_idx;
-- alter table public.deals drop column if exists quente_em;
-- alter table public.deals drop column if exists quente;
-- notify pgrst, 'reload schema';
