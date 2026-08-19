-- =============================================================================
-- MIGRATION 20260819_0003 — Normalização de município e RPCs de relatório
-- Projeto: CRM Funil de Vendas (Escard) · Supabase heevguvboffziehftucp
-- Depende de: 0001_auditoria_base.sql · 0002_stage_history.sql
-- =============================================================================
-- Parte A — expand: colunas city e origem, preenchidas a partir de source.
--   source está sobrecarregado: contém município (~90 valores), origem real
--   (Agendor, Indicação) e lixo (TIAGO). Parte dos registros tem mojibake
--   (SÃ£o em vez de São) por dupla codificação UTF-8/Latin-1.
--   Esta migration NÃO altera source — o front continua funcionando igual.
--
-- Parte B — RPCs de agregação para o painel de produtividade.
--   Toda leitura vai ao banco. Nenhuma depende do array deals em memória,
--   que o PostgREST trunca em 1.000 linhas.
--
-- Regra de permissão: vendedor só enxerga a própria carteira. O parâmetro
--   p_owner é ignorado para quem não é admin — não basta filtrar no front.
--
-- Aditiva. NÃO altera index.html.
-- =============================================================================

begin;

-- =============================================================================
-- A1. REPARO E NORMALIZAÇÃO DE TEXTO
-- =============================================================================
create or replace function public.fn_reparar_mojibake(p_texto text)
returns text
language plpgsql
immutable
as $$
declare
  v text := p_texto;
begin
  if v is null then return null; end if;
  -- Mojibake típico de UTF-8 lido como Latin-1: 'ã' (C3 A3) vira 'Ã£' (C383 C2A3).
  if v ~ '[ÃÂ]' then
    begin
      v := convert_from(convert_to(v, 'LATIN1'), 'UTF8');
    exception when others then
      return p_texto;  -- caractere fora do Latin-1: devolve o original intacto
    end;
  end if;
  return v;
end;
$$;

comment on function public.fn_reparar_mojibake(text) is
  'Reverte dupla codificação UTF-8/Latin-1. Devolve o original se a conversão não for possível.';


create or replace function public.fn_normalizar_municipio(p_texto text)
returns text
language plpgsql
immutable
as $$
declare
  v          text;
  palavra    text;
  partes     text[] := '{}';
  i          integer := 0;
  minusculas text[] := array['de','do','da','dos','das','e','d'];
begin
  v := btrim(coalesce(public.fn_reparar_mojibake(p_texto), ''));
  if v = '' then return null; end if;

  v := regexp_replace(lower(v), '\s+', ' ', 'g');

  foreach palavra in array string_to_array(v, ' ') loop
    i := i + 1;
    -- Preposição no meio do nome fica minúscula: "São Domingos do Norte".
    -- initcap produziria "Do", que é incorreto em português.
    if i > 1 and palavra = any(minusculas) then
      partes := partes || palavra;
    else
      partes := partes || (upper(left(palavra, 1)) || substr(palavra, 2));
    end if;
  end loop;

  return array_to_string(partes, ' ');
end;
$$;


-- =============================================================================
-- A2. COLUNAS E BACKFILL
-- =============================================================================
alter table public.deals add column if not exists city   text;
alter table public.deals add column if not exists origem text;

comment on column public.deals.city is
  'Município normalizado, derivado de source. Substitui source no uso analítico.';
comment on column public.deals.origem is
  'Origem real do lead. Só preenchida quando source continha origem, não município.';

-- Valores de source que são origem, não município.
create or replace function public.fn_source_e_origem(p_texto text)
returns text
language sql
immutable
as $$
  select case lower(btrim(coalesce(public.fn_reparar_mojibake(p_texto), '')))
           when 'agendor'   then 'Agendor'
           when 'indicação' then 'Indicação'
           when 'indicacao' then 'Indicação'
           when 'site'      then 'Site'
           when 'whatsapp'  then 'WhatsApp'
           else null
         end;
$$;

update public.deals d
   set origem = public.fn_source_e_origem(d.source),
       city   = case
                  when public.fn_source_e_origem(d.source) is not null then null
                  -- nome de pessoa gravado no campo errado não é município
                  when lower(btrim(coalesce(d.source,''))) in ('tiago','heloisa','heloísa','priscila','roberto') then null
                  else public.fn_normalizar_municipio(d.source)
                end
 where d.city is null
   and d.origem is null;

create index if not exists idx_deals_city   on public.deals (city);
create index if not exists idx_deals_origem on public.deals (origem);


-- =============================================================================
-- A3. MARCO ZERO — rotular as linhas de base do histórico
-- =============================================================================
-- A 0002 gravou a posição inicial dos leads com origem = 'sistema', o mesmo
-- rótulo de lead vindo por integração. Sem separar, o funil contaria 3.010
-- entradas falsas. As linhas de base são as primeiras inseridas na tabela,
-- portanto têm id menor que qualquer linha gerada por trigger depois.
alter table public.deal_stage_history drop constraint if exists deal_stage_history_origem_check;
alter table public.deal_stage_history add constraint deal_stage_history_origem_check
  check (origem in ('app','sistema','entrada','baseline'));

update public.deal_stage_history
   set origem = 'baseline'
 where origem = 'sistema'
   and from_stage_id is null
   and changed_by is null
   and id < coalesce(
         (select min(id) from public.deal_stage_history where origem in ('app','entrada')),
         (select max(id) + 1 from public.deal_stage_history)
       );


-- =============================================================================
-- B0. RESOLUÇÃO DE ESCOPO — vendedor nunca vê carteira alheia
-- =============================================================================
create or replace function public.rel_owner_efetivo(p_owner uuid)
returns uuid
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
  if auth.uid() is null then
    raise exception 'Relatório exige usuário autenticado.' using errcode = '42501';
  end if;
  -- Admin decide o escopo; null significa toda a equipe.
  if public.audit_usuario_e_admin() then
    return p_owner;
  end if;
  -- Vendedor: o parâmetro é ignorado de propósito.
  return auth.uid();
end;
$$;


-- =============================================================================
-- B1. MOTOR DE MÉTRICAS (interno — NÃO aplica escopo, revogado de authenticated)
-- =============================================================================
-- Separado da RPC pública de propósito: o ranking precisa da média real da
-- equipe, que só existe se a função conseguir calcular por outro owner. A
-- checagem de permissão fica no invólucro público, nunca aqui.
create or replace function public.rel_metricas(
  p_de    date,
  p_ate   date,
  p_owner uuid default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_owner    uuid    := p_owner;
  v_ini      timestamptz := p_de::timestamptz;
  v_fim      timestamptz := (p_ate + 1)::timestamptz;
  v_dorm     integer := public.app_setting_int('lead_dormente_dias', 14);
  v_result   jsonb;
begin
  if p_de is null or p_ate is null or p_ate < p_de then
    raise exception 'Período inválido.' using errcode = '22023';
  end if;

  with carteira as (
    select d.id, d.owner_id, d.next_followup_date, d.created_at
      from public.deals d
      join public.pipeline_stages s on s.id = d.stage_id
     where not coalesce(s.is_won, false)
       and not coalesce(s.is_lost, false)
       and (v_owner is null or d.owner_id = v_owner)
  ),
  ativ as (
    select a.deal_id, a.channel, a.outcome, coalesce(a.occurred_at, a.created_at) as quando
      from public.deal_activities a
      join public.deals d on d.id = a.deal_id
     where coalesce(a.occurred_at, a.created_at) >= v_ini
       and coalesce(a.occurred_at, a.created_at) <  v_fim
       and (v_owner is null or d.owner_id = v_owner)
  ),
  ativ_carteira as (
    select distinct a.deal_id from ativ a join carteira c on c.id = a.deal_id
  ),
  ultimo_toque as (
    select c.id,
           (select max(coalesce(a.occurred_at, a.created_at))
              from public.deal_activities a where a.deal_id = c.id) as ultima
      from carteira c
  ),
  primeiro_contato as (
    select d.id,
           extract(epoch from (
             (select min(coalesce(a.occurred_at, a.created_at))
                from public.deal_activities a where a.deal_id = d.id) - d.created_at
           )) / 3600.0 as horas
      from public.deals d
     where d.created_at >= v_ini and d.created_at < v_fim
       and (v_owner is null or d.owner_id = v_owner)
  ),
  desfecho as (
    select h.deal_id, s.is_won, s.is_lost, h.changed_at, d.value, d.created_at
      from public.deal_stage_history h
      join public.pipeline_stages s on s.id = h.to_stage_id
      join public.deals d           on d.id = h.deal_id
     where h.changed_at >= v_ini and h.changed_at < v_fim
       and h.origem <> 'baseline'
       and (coalesce(s.is_won, false) or coalesce(s.is_lost, false))
       and (v_owner is null or h.owner_id = v_owner)
  )
  select jsonb_build_object(
    'periodo',            jsonb_build_object('de', p_de, 'ate', p_ate, 'dias', (p_ate - p_de) + 1),
    'carteira',           (select count(*) from carteira),
    'trabalhados',        (select count(distinct deal_id) from ativ),
    'trabalhados_carteira',(select count(*) from ativ_carteira),
    'cobertura_pct',      case when (select count(*) from carteira) = 0 then 0
                            else round(100.0 * (select count(*) from ativ_carteira)
                                       / (select count(*) from carteira), 1) end,
    'primeiro_contato_h', (select round(avg(horas)::numeric, 1) from primeiro_contato where horas is not null),
    'leads_criados',      (select count(*) from public.deals d
                            where d.created_at >= v_ini and d.created_at < v_fim
                              and (v_owner is null or d.owner_id = v_owner)),
    'followup_em_dia_pct',case when (select count(*) from carteira) = 0 then 0
                            else round(100.0 * (select count(*) from carteira
                                                 where next_followup_date >= current_date)
                                       / (select count(*) from carteira), 1) end,
    'dormentes',          (select count(*) from ultimo_toque u
                            where coalesce(u.ultima, (select created_at from carteira c where c.id = u.id))
                                  < now() - make_interval(days => v_dorm)),
    'dormentes_dias',     v_dorm,
    'ganhos',             (select count(*) from desfecho where is_won),
    'perdidos',           (select count(*) from desfecho where is_lost),
    'conversao_pct',      case when (select count(*) from desfecho) = 0 then 0
                            else round(100.0 * (select count(*) from desfecho where is_won)
                                       / (select count(*) from desfecho), 1) end,
    'valor_ganho',        coalesce((select sum(value) from desfecho where is_won), 0),
    'ciclo_medio_dias',   (select round(avg(extract(epoch from (changed_at - created_at)) / 86400.0)::numeric, 1)
                             from desfecho where is_won),
    'atividades',         (select count(*) from ativ),
    'atividades_efetivas',(select count(*) from ativ where outcome in ('atendeu','respondeu')),
    'taxa_efetiva_pct',   case when (select count(*) from ativ) = 0 then 0
                            else round(100.0 * (select count(*) from ativ where outcome in ('atendeu','respondeu'))
                                       / (select count(*) from ativ), 1) end,
    'contatos_invalidos', (select count(distinct deal_id) from ativ
                            where outcome in ('numero_errado','numero_invalido')),
    'por_canal',          coalesce((select jsonb_object_agg(coalesce(channel,'(sem canal)'), n)
                                      from (select channel, count(*) n from ativ group by 1) x), '{}'::jsonb),
    'por_desfecho',       coalesce((select jsonb_object_agg(coalesce(outcome,'(sem registro)'), n)
                                      from (select outcome, count(*) n from ativ group by 1) x), '{}'::jsonb),
    'motivos_perda',      coalesce((select jsonb_object_agg(coalesce(lr,'(não preenchido)'), n)
                                      from (select coalesce(d.loss_reason,'(não preenchido)') lr, count(*) n
                                              from desfecho f join public.deals d on d.id = f.deal_id
                                             where f.is_lost group by 1) x), '{}'::jsonb),
    'top_municipios',     coalesce((select jsonb_agg(jsonb_build_object('city', city, 'leads', n) order by n desc)
                                      from (select c.city, count(*) n
                                              from carteira ca join public.deals c on c.id = ca.id
                                             where c.city is not null group by 1 order by 2 desc limit 10) x), '[]'::jsonb)
  ) into v_result;

  return v_result;
end;
$$;


-- Invólucro público: aplica o escopo antes de chamar o motor.
create or replace function public.relatorio_produtividade(
  p_de    date,
  p_ate   date,
  p_owner uuid default null
)
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select public.rel_metricas(p_de, p_ate, public.rel_owner_efetivo(p_owner));
$$;


-- Base do ranking: uma linha por vendedor. Interna, revogada de authenticated.
create or replace function public.rel_ranking_base(p_de date, p_ate date)
returns table (
  id          uuid,
  nome        text,
  trabalhados bigint,
  cobertura   numeric,
  conversao   numeric,
  ganho       numeric
)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select p.id,
         p.full_name,
         coalesce((m->>'trabalhados')::bigint, 0),
         coalesce((m->>'cobertura_pct')::numeric, 0),
         coalesce((m->>'conversao_pct')::numeric, 0),
         coalesce((m->>'valor_ganho')::numeric, 0)
    from public.profiles p
    cross join lateral public.rel_metricas(p_de, p_ate, p.id) m
   where p.role is not null
     and coalesce(p.active, true);
$$;


-- =============================================================================
-- B2. SÉRIE DIÁRIA DE ATIVIDADES
-- =============================================================================
create or replace function public.serie_atividades(
  p_de    date,
  p_ate   date,
  p_owner uuid default null
)
returns table (dia date, total bigint, efetivas bigint)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_owner uuid := public.rel_owner_efetivo(p_owner);
begin
  if p_de is null or p_ate is null or p_ate < p_de then
    raise exception 'Período inválido.' using errcode = '22023';
  end if;

  return query
  select g.d::date,
         count(a.id),
         count(a.id) filter (where a.outcome in ('atendeu','respondeu'))
    from generate_series(p_de, p_ate, interval '1 day') g(d)
    left join public.deal_activities a
           on coalesce(a.occurred_at, a.created_at) >= g.d
          and coalesce(a.occurred_at, a.created_at) <  g.d + interval '1 day'
    left join public.deals dl on dl.id = a.deal_id
   where a.id is null or (v_owner is null or dl.owner_id = v_owner)
   group by g.d
   order by g.d;
end;
$$;


-- =============================================================================
-- B3. FUNIL DO PERÍODO
-- =============================================================================
create or replace function public.funil_periodo(
  p_de    date,
  p_ate   date,
  p_owner uuid default null
)
returns table (
  stage_id       uuid,
  etapa          text,
  order_index    integer,
  is_won         boolean,
  is_lost        boolean,
  leads_agora    bigint,
  entradas       bigint,
  saidas         bigint,
  dias_medio     numeric
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_owner uuid := public.rel_owner_efetivo(p_owner);
  v_ini   timestamptz := p_de::timestamptz;
  v_fim   timestamptz := (p_ate + 1)::timestamptz;
begin
  return query
  select s.id,
         s.name,
         s.order_index,
         coalesce(s.is_won, false),
         coalesce(s.is_lost, false),
         (select count(*) from public.deals d
           where d.stage_id = s.id and (v_owner is null or d.owner_id = v_owner)),
         (select count(*) from public.deal_stage_history h
           where h.to_stage_id = s.id and h.origem <> 'baseline'
             and h.changed_at >= v_ini and h.changed_at < v_fim
             and (v_owner is null or h.owner_id = v_owner)),
         (select count(*) from public.deal_stage_history h
           where h.from_stage_id = s.id
             and h.changed_at >= v_ini and h.changed_at < v_fim
             and (v_owner is null or h.owner_id = v_owner)),
         (select round(avg(h.dias_anterior), 1) from public.deal_stage_history h
           where h.from_stage_id = s.id and h.dias_anterior is not null
             and h.changed_at >= v_ini and h.changed_at < v_fim
             and (v_owner is null or h.owner_id = v_owner))
    from public.pipeline_stages s
   order by s.order_index;
end;
$$;


-- =============================================================================
-- B4. RANKING DA EQUIPE
-- =============================================================================
-- Respeita app_settings.ranking_aberto_vendedor. Com false (padrão), o vendedor
-- recebe apenas a própria linha e a média da equipe — nunca o número do colega.
create or replace function public.ranking_equipe(
  p_de  date,
  p_ate date
)
returns table (
  owner_id     uuid,
  nome         text,
  e_voce       boolean,
  trabalhados  bigint,
  cobertura    numeric,
  conversao    numeric,
  valor_ganho  numeric
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_admin  boolean := public.audit_usuario_e_admin();
  v_aberto boolean := coalesce(
    (select (valor #>> '{}')::boolean from public.app_settings
      where chave = 'ranking_aberto_vendedor'), false);
  v_eu     uuid := auth.uid();
begin
  if v_eu is null then
    raise exception 'Relatório exige usuário autenticado.' using errcode = '42501';
  end if;

  if v_admin or v_aberto then
    return query
      select b.id, b.nome, b.id = v_eu, b.trabalhados, b.cobertura, b.conversao, b.ganho
        from public.rel_ranking_base(p_de, p_ate) b
       order by b.trabalhados desc;
  else
    -- Vendedor: a própria linha e a média da equipe. Nunca o número do colega.
    return query
      select b.id, b.nome, true, b.trabalhados, b.cobertura, b.conversao, b.ganho
        from public.rel_ranking_base(p_de, p_ate) b
       where b.id = v_eu
      union all
      select null::uuid, 'Média da equipe'::text, false,
             round(avg(b.trabalhados))::bigint,
             round(avg(b.cobertura), 1),
             round(avg(b.conversao), 1),
             round(avg(b.ganho), 2)
        from public.rel_ranking_base(p_de, p_ate) b;
  end if;
end;
$$;


-- =============================================================================
-- B5. CONSULTA DA TRILHA DE AUDITORIA
-- =============================================================================
create or replace function public.auditoria_consulta(
  p_de     date,
  p_ate    date,
  p_tabela text    default null,
  p_actor  uuid    default null,
  p_limit  integer default 50,
  p_offset integer default 0
)
returns table (
  id         bigint,
  created_at timestamptz,
  autor      text,
  tabela     text,
  acao       text,
  rotulo     text,
  campos     jsonb,
  txid       bigint,
  no_lote    bigint
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
  if not public.audit_usuario_e_admin() then
    raise exception 'Consulta de auditoria restrita a administradores.' using errcode = '42501';
  end if;

  return query
  select a.id, a.created_at,
         coalesce(p.full_name, case when a.actor_id is null then 'Sistema' else 'Usuário removido' end),
         a.tabela, a.acao, a.rotulo, a.campos, a.txid,
         count(*) over (partition by a.txid)
    from public.audit_log a
    left join public.profiles p on p.id = a.actor_id
   where a.created_at >= p_de::timestamptz
     and a.created_at <  (p_ate + 1)::timestamptz
     and (p_tabela is null or a.tabela = p_tabela)
     and (p_actor  is null or a.actor_id = p_actor)
   order by a.id desc
   limit greatest(1, least(coalesce(p_limit, 50), 500))
  offset greatest(0, coalesce(p_offset, 0));
end;
$$;


-- =============================================================================
-- B6. PERMISSÕES
-- =============================================================================
revoke all on function public.rel_metricas(date, date, uuid)      from public, anon, authenticated;
revoke all on function public.rel_ranking_base(date, date)        from public, anon, authenticated;
revoke all on function public.relatorio_produtividade(date, date, uuid) from public, anon;
revoke all on function public.serie_atividades(date, date, uuid)        from public, anon;
revoke all on function public.funil_periodo(date, date, uuid)           from public, anon;
revoke all on function public.ranking_equipe(date, date)                from public, anon;
revoke all on function public.auditoria_consulta(date, date, text, uuid, integer, integer) from public, anon;

grant execute on function public.relatorio_produtividade(date, date, uuid) to authenticated;
grant execute on function public.serie_atividades(date, date, uuid)        to authenticated;
grant execute on function public.funil_periodo(date, date, uuid)           to authenticated;
grant execute on function public.ranking_equipe(date, date)                to authenticated;
grant execute on function public.auditoria_consulta(date, date, text, uuid, integer, integer) to authenticated;

commit;

-- =============================================================================
-- ROLLBACK
-- =============================================================================
-- begin;
--   drop function if exists public.auditoria_consulta(date, date, text, uuid, integer, integer);
--   drop function if exists public.ranking_equipe(date, date);
--   drop function if exists public.funil_periodo(date, date, uuid);
--   drop function if exists public.serie_atividades(date, date, uuid);
--   drop function if exists public.relatorio_produtividade(date, date, uuid);
--   drop function if exists public.rel_owner_efetivo(uuid);
--   drop function if exists public.fn_source_e_origem(text);
--   drop function if exists public.fn_normalizar_municipio(text);
--   drop function if exists public.fn_reparar_mojibake(text);
--   alter table public.deals drop column if exists city;
--   alter table public.deals drop column if exists origem;
-- commit;
