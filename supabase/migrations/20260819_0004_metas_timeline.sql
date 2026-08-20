-- =============================================================================
-- MIGRATION 20260819_0004 — Metas, marcador de movimentação e linha do tempo
-- Projeto: CRM Funil de Vendas (Escard) · Supabase heevguvboffziehftucp
-- Depende de: 0001, 0002, 0003
-- =============================================================================
-- A. Restaura deals.updated_at, sobrescrito pelo backfill de município da 0003.
--    Os valores originais estão preservados na trilha de auditoria.
-- B. Tabela de metas por vendedor (5 indicadores × 3 periodicidades).
-- C. RPC de progresso das metas.
-- D. RPC de linha do tempo do lead (histórico dentro do registro).
-- E. Métrica de leads alterados no período, para o painel.
--
-- Aditiva. Idempotente.
-- =============================================================================

begin;

-- =============================================================================
-- A. RESTAURAR updated_at
-- =============================================================================
-- O backfill da 0003 gravou now() em 3.010 leads. O valor anterior de cada um
-- ficou registrado em audit_log.campos->'updated_at'->>'de'. Recupera o PRIMEIRO
-- registro de cada lead, que é o valor de antes da migration.
do $restaura$
declare
  v_qtd integer;
begin
  if not exists (select 1 from public.audit_log
                  where tabela = 'deals' and campos ? 'updated_at' limit 1) then
    raise notice 'Nenhum updated_at na trilha — restauração ignorada.';
    return;
  end if;

  with original as (
    select distinct on (a.registro_id)
           a.registro_id,
           (a.campos -> 'updated_at' ->> 'de')::timestamptz as valor
      from public.audit_log a
     where a.tabela = 'deals'
       and a.campos ? 'updated_at'
       and a.actor_id is null          -- alteração feita pela migration, não por usuário
     order by a.registro_id, a.id asc  -- o primeiro registro guarda o valor pré-migration
  )
  update public.deals d
     set updated_at = o.valor
    from original o
   where d.id = o.registro_id
     and o.valor is not null
     and d.updated_at <> o.valor;

  get diagnostics v_qtd = row_count;
  raise notice 'updated_at restaurado em % leads.', v_qtd;
end;
$restaura$;


-- =============================================================================
-- B. METAS
-- =============================================================================
create table if not exists public.metas (
  id            uuid primary key default gen_random_uuid(),
  owner_id      uuid        not null references public.profiles(id) on delete cascade,
  indicador     text        not null check (indicador in
                  ('atividades','trabalhados','movimentacoes','ganhos','valor_ganho')),
  periodicidade text        not null check (periodicidade in ('diaria','semanal','mensal')),
  valor         numeric     not null default 0 check (valor >= 0),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  updated_by    uuid        references public.profiles(id) on delete set null,
  unique (owner_id, indicador, periodicidade)
);

comment on table public.metas is
  'Metas por vendedor. Valor 0 significa meta desligada — não aparece no painel.';

create index if not exists idx_metas_owner on public.metas (owner_id);

alter table public.metas enable row level security;

-- Vendedor vê a própria meta. Admin vê todas. Escrita só por RPC.
drop policy if exists metas_select on public.metas;
create policy metas_select on public.metas
  for select to authenticated
  using (public.audit_usuario_e_admin() or owner_id = auth.uid());

revoke insert, update, delete, truncate on public.metas from anon, authenticated;


create or replace function public.metas_salvar(
  p_owner         uuid,
  p_indicador     text,
  p_periodicidade text,
  p_valor         numeric
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if not public.audit_usuario_e_admin() then
    raise exception 'Somente administradores definem metas.' using errcode = '42501';
  end if;
  if p_valor is null or p_valor < 0 then
    raise exception 'Valor de meta inválido.' using errcode = '22023';
  end if;

  insert into public.metas (owner_id, indicador, periodicidade, valor, updated_by, updated_at)
  values (p_owner, p_indicador, p_periodicidade, p_valor, auth.uid(), now())
  on conflict (owner_id, indicador, periodicidade)
  do update set valor = excluded.valor, updated_by = excluded.updated_by, updated_at = now();
end;
$$;


-- =============================================================================
-- C. PROGRESSO DAS METAS
-- =============================================================================
create or replace function public.metas_progresso(p_owner uuid default null)
returns table (
  owner_id      uuid,
  vendedor      text,
  indicador     text,
  periodicidade text,
  meta          numeric,
  realizado     numeric,
  pct           numeric
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_owner uuid := public.rel_owner_efetivo(p_owner);
begin
  return query
  with janela as (
    select 'diaria'::text  as p, current_date                                  as ini, current_date + 1 as fim
    union all
    select 'semanal',      date_trunc('week',  current_date)::date, (date_trunc('week',  current_date) + interval '7 days')::date
    union all
    select 'mensal',       date_trunc('month', current_date)::date, (date_trunc('month', current_date) + interval '1 month')::date
  ),
  base as (
    select m.owner_id, p.full_name, m.indicador, m.periodicidade, m.valor, j.ini, j.fim
      from public.metas m
      join public.profiles p on p.id = m.owner_id
      join janela j on j.p = m.periodicidade
     where m.valor > 0
       and (v_owner is null or m.owner_id = v_owner)
  )
  select b.owner_id,
         b.full_name,
         b.indicador,
         b.periodicidade,
         b.valor,
         r.realizado,
         case when b.valor = 0 then 0 else round(100.0 * r.realizado / b.valor, 1) end
    from base b
    cross join lateral (
      select case b.indicador

        when 'atividades' then
          (select count(*)::numeric from public.deal_activities a
             join public.deals d on d.id = a.deal_id
            where d.owner_id = b.owner_id
              and coalesce(a.occurred_at, a.created_at) >= b.ini
              and coalesce(a.occurred_at, a.created_at) <  b.fim)

        when 'trabalhados' then
          (select count(distinct a.deal_id)::numeric from public.deal_activities a
             join public.deals d on d.id = a.deal_id
            where d.owner_id = b.owner_id
              and coalesce(a.occurred_at, a.created_at) >= b.ini
              and coalesce(a.occurred_at, a.created_at) <  b.fim)

        when 'movimentacoes' then
          (select count(*)::numeric from public.deal_stage_history h
            where h.owner_id = b.owner_id and h.origem = 'app'
              and h.changed_at >= b.ini and h.changed_at < b.fim)

        when 'ganhos' then
          (select count(*)::numeric from public.deal_stage_history h
             join public.pipeline_stages s on s.id = h.to_stage_id
            where h.owner_id = b.owner_id and coalesce(s.is_won, false)
              and h.origem <> 'baseline'
              and h.changed_at >= b.ini and h.changed_at < b.fim)

        when 'valor_ganho' then
          coalesce((select sum(d.value) from public.deal_stage_history h
             join public.pipeline_stages s on s.id = h.to_stage_id
             join public.deals d on d.id = h.deal_id
            where h.owner_id = b.owner_id and coalesce(s.is_won, false)
              and h.origem <> 'baseline'
              and h.changed_at >= b.ini and h.changed_at < b.fim), 0)

        else 0
      end as realizado
    ) r
   order by b.full_name, b.indicador, b.periodicidade;
end;
$$;


-- =============================================================================
-- D. LINHA DO TEMPO DO LEAD
-- =============================================================================
create or replace function public.lead_timeline(p_deal_id uuid)
returns table (
  quando    timestamptz,
  tipo      text,
  autor     text,
  titulo    text,
  detalhe   jsonb
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_dono uuid;
begin
  select d.owner_id into v_dono from public.deals d where d.id = p_deal_id;
  if v_dono is null and not exists (select 1 from public.deals where id = p_deal_id) then
    raise exception 'Lead não encontrado.' using errcode = '02000';
  end if;

  if not public.audit_usuario_e_admin() and v_dono is distinct from auth.uid() then
    raise exception 'Sem permissão para ver este lead.' using errcode = '42501';
  end if;

  return query
  -- contatos e notas
  select coalesce(a.occurred_at, a.created_at),
         'atividade'::text,
         coalesce(p.full_name, 'Sistema'),
         coalesce(a.channel, 'contato') ||
           case when a.outcome is null then '' else ' · ' || a.outcome end,
         jsonb_build_object('nota', a.note)
    from public.deal_activities a
    left join public.profiles p on p.id = a.author_id
   where a.deal_id = p_deal_id

  union all
  -- movimentação de etapa
  select h.changed_at,
         'etapa'::text,
         coalesce(p.full_name, 'Sistema'),
         coalesce(o.name, 'Entrada no funil') || ' → ' || coalesce(n.name, '—'),
         jsonb_build_object('dias_na_etapa_anterior', h.dias_anterior)
    from public.deal_stage_history h
    left join public.profiles p        on p.id = h.changed_by
    left join public.pipeline_stages o on o.id = h.from_stage_id
    left join public.pipeline_stages n on n.id = h.to_stage_id
   where h.deal_id = p_deal_id
     and h.origem <> 'baseline'

  union all
  -- demais alterações de campo (etapa já aparece acima)
  select a.created_at,
         'alteracao'::text,
         coalesce(p.full_name, 'Sistema'),
         case a.acao when 'INSERT' then 'Lead criado'
                     when 'DELETE' then 'Lead removido'
                     else 'Campos alterados' end,
         coalesce(a.campos - 'stage_id' - 'stage_changed_at' - 'updated_at', '{}'::jsonb)
    from public.audit_log a
    left join public.profiles p on p.id = a.actor_id
   where a.tabela = 'deals'
     and a.registro_id = p_deal_id
     and (a.acao <> 'UPDATE'
          or (a.campos - 'stage_id' - 'stage_changed_at' - 'updated_at') <> '{}'::jsonb)

   order by 1 desc;
end;
$$;


-- =============================================================================
-- E. MÉTRICA DE LEADS ALTERADOS NO PERÍODO
-- =============================================================================
-- Acrescenta 'leads_alterados' ao retorno de rel_metricas sem tocar no restante.
create or replace function public.leads_alterados(
  p_de    date,
  p_ate   date,
  p_owner uuid default null
)
returns bigint
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select count(distinct a.registro_id)
    from public.audit_log a
    join public.deals d on d.id = a.registro_id
   where a.tabela = 'deals'
     and a.actor_id is not null          -- exclui backfill e integrações
     and a.created_at >= p_de::timestamptz
     and a.created_at <  (p_ate + 1)::timestamptz
     and (p_owner is null or d.owner_id = p_owner);
$$;


-- =============================================================================
-- F. PERMISSÕES
-- =============================================================================
revoke all on function public.metas_salvar(uuid, text, text, numeric) from public, anon;
revoke all on function public.metas_progresso(uuid)                   from public, anon;
revoke all on function public.lead_timeline(uuid)                     from public, anon;
revoke all on function public.leads_alterados(date, date, uuid)       from public, anon;

grant execute on function public.metas_salvar(uuid, text, text, numeric) to authenticated;
grant execute on function public.metas_progresso(uuid)                   to authenticated;
grant execute on function public.lead_timeline(uuid)                     to authenticated;
grant execute on function public.leads_alterados(date, date, uuid)       to authenticated;


-- =============================================================================
-- G. SEMENTE — metas zeradas para os vendedores ativos
-- =============================================================================
-- Valor 0 = meta desligada. O admin liga só o que vai usar.
insert into public.metas (owner_id, indicador, periodicidade, valor)
select p.id, ind, per, 0
  from public.profiles p
  cross join unnest(array['atividades','trabalhados','movimentacoes','ganhos','valor_ganho']) ind
  cross join unnest(array['diaria','semanal','mensal']) per
 where coalesce(p.active, true)
   and p.role is not null
on conflict (owner_id, indicador, periodicidade) do nothing;

commit;

-- =============================================================================
-- ROLLBACK
-- =============================================================================
-- begin;
--   drop function if exists public.leads_alterados(date, date, uuid);
--   drop function if exists public.lead_timeline(uuid);
--   drop function if exists public.metas_progresso(uuid);
--   drop function if exists public.metas_salvar(uuid, text, text, numeric);
--   drop table if exists public.metas;
-- commit;
-- OBS: a restauração de updated_at (seção A) não é revertida — os valores
-- restaurados são os corretos; desfazer significaria reintroduzir o erro.
