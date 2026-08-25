-- supabase/migrations/20260825_0007_meta_reunioes.sql
-- Adiciona o indicador 'reunioes' às metas.
-- Fonte: deal_activities.channel = 'presencial' (canal já existente, zero uso).
-- Nenhuma alteração em deal_activities — as constraints do banco vivo já
-- aceitam 'presencial' com outcome ('realizada','nao_compareceu').

begin;

-- 1) Amplia o CHECK de indicador.
--    Lista reproduzida do banco vivo (pg_get_constraintdef) + 'reunioes'.
alter table public.metas drop constraint metas_indicador_check;

alter table public.metas add constraint metas_indicador_check check (
  indicador = any (array[
    'atividades'::text,
    'trabalhados'::text,
    'movimentacoes'::text,
    'ganhos'::text,
    'valor_ganho'::text,
    'ligacoes'::text,
    'whatsapp'::text,
    'emails'::text,
    'conversas_efetivas'::text,
    'reunioes'::text
  ])
);

-- 2) Cria a meta 'reunioes' desligada (valor = 0) para todos os perfis
--    que já possuem metas, nas três periodicidades.
insert into public.metas (owner_id, indicador, periodicidade, valor)
select distinct m.owner_id, 'reunioes', m.periodicidade, 0
from public.metas m
on conflict (owner_id, indicador, periodicidade) do nothing;

-- 3) Ensina metas_progresso a calcular 'reunioes'.
--    Corpo idêntico ao vivo, com um único ramo novo no CASE.
create or replace function public.metas_progresso(p_owner uuid default null::uuid)
 returns table(owner_id uuid, vendedor text, indicador text, periodicidade text, meta numeric, realizado numeric, pct numeric)
 language plpgsql
 stable security definer
 set search_path to 'public', 'pg_temp'
as $function$
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

        -- Reunião: encontro presencial que aconteceu. Filtra por outcome
        -- 'realizada' para não contar no-show como resultado. Para contar
        -- toda reunião marcada, remover a linha do outcome abaixo.
        when 'reunioes' then
          (select count(*)::numeric from public.deal_activities a
             join public.deals d on d.id = a.deal_id
            where d.owner_id = b.owner_id
              and a.channel = 'presencial'
              and a.outcome = 'realizada'
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
$function$;

commit;