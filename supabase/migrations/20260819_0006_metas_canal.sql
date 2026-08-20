-- =============================================================================
-- MIGRATION 20260819_0006 — Metas por canal e por conversa efetiva
-- Projeto: CRM Funil de Vendas (Escard) · Supabase heevguvboffziehftucp
-- Depende de: 0001 a 0005
-- =============================================================================
-- Quatro indicadores novos, somando nove no total:
--   ligacoes            — channel = 'telefone'
--   whatsapp            — channel = 'whatsapp'
--   emails              — channel = 'email'
--   conversas_efetivas  — outcome em ('atendeu','respondeu'), qualquer canal
--
-- Os três primeiros medem esforço por canal. O quarto mede resultado do
-- esforço: no histórico da base, 108 ligações produziram 15 atendimentos.
-- Meta só de volume premia discagem; conversa efetiva premia venda.
--
-- Aditiva. Nenhuma meta existente é alterada. Novas metas nascem em 0
-- (desligadas), como as anteriores.
-- =============================================================================

begin;

-- Amplia o domínio de indicador
alter table public.metas drop constraint if exists metas_indicador_check;
alter table public.metas add constraint metas_indicador_check
  check (indicador in ('atividades','trabalhados','movimentacoes','ganhos','valor_ganho',
                       'ligacoes','whatsapp','emails','conversas_efetivas'));

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

        when 'ligacoes' then
          (select count(*)::numeric from public.deal_activities a
             join public.deals d on d.id = a.deal_id
            where d.owner_id = b.owner_id and a.channel = 'telefone'
              and coalesce(a.occurred_at, a.created_at) >= b.ini
              and coalesce(a.occurred_at, a.created_at) <  b.fim)

        when 'whatsapp' then
          (select count(*)::numeric from public.deal_activities a
             join public.deals d on d.id = a.deal_id
            where d.owner_id = b.owner_id and a.channel = 'whatsapp'
              and coalesce(a.occurred_at, a.created_at) >= b.ini
              and coalesce(a.occurred_at, a.created_at) <  b.fim)

        when 'emails' then
          (select count(*)::numeric from public.deal_activities a
             join public.deals d on d.id = a.deal_id
            where d.owner_id = b.owner_id and a.channel = 'email'
              and coalesce(a.occurred_at, a.created_at) >= b.ini
              and coalesce(a.occurred_at, a.created_at) <  b.fim)

        -- Conversa efetiva: alguém do outro lado respondeu. É o indicador que
        -- distingue trabalho de discagem — meta só de volume produz ligação
        -- feita e desligada para bater número.
        when 'conversas_efetivas' then
          (select count(*)::numeric from public.deal_activities a
             join public.deals d on d.id = a.deal_id
            where d.owner_id = b.owner_id
              and a.outcome in ('atendeu','respondeu')
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

-- Semeia os quatro novos indicadores, desligados
insert into public.metas (owner_id, indicador, periodicidade, valor)
select p.id, ind, per, 0
  from public.profiles p
  cross join unnest(array['ligacoes','whatsapp','emails','conversas_efetivas']) ind
  cross join unnest(array['diaria','semanal','mensal']) per
 where coalesce(p.active, true)
   and p.role is not null
on conflict (owner_id, indicador, periodicidade) do nothing;

commit;

-- =============================================================================
-- ROLLBACK
-- =============================================================================
-- begin;
--   delete from public.metas
--    where indicador in ('ligacoes','whatsapp','emails','conversas_efetivas');
--   alter table public.metas drop constraint if exists metas_indicador_check;
--   alter table public.metas add constraint metas_indicador_check
--     check (indicador in ('atividades','trabalhados','movimentacoes','ganhos','valor_ganho'));
--   -- reexecutar 0004 para restaurar metas_progresso
-- commit;
