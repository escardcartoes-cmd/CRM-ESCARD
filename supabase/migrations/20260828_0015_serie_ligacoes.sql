-- =============================================================================
-- MIGRATION 20260828_0015 — Série de ligações por dia e por vendedor
-- Projeto: CRM Funil de Vendas (Escard) · Supabase heevguvboffziehftucp
-- Depende de: 0001 a 0014
-- =============================================================================
-- O relatório mostrava "Atividades registradas por dia" como uma linha por
-- vendedor, somando todos os canais. Duas coisas erradas para a operação de hoje:
--
--   1. A meta é UMA — ligações. O gráfico media outra coisa.
--   2. Linha responde "a tendência sobe?". A pergunta do gestor é outra:
--      "trabalhamos TODO dia, e quem trabalhou em cada dia?". Isso é coluna.
--
-- Esta RPC devolve a matéria-prima: uma linha por (dia, vendedor) com tentativas
-- e atendidas. O eixo de dias é montado no frontend a partir do próprio período
-- selecionado — devolver dia vazio para cada vendedor multiplicaria o retorno
-- por nada (30 dias × 4 vendedoras = 120 linhas, quase todas zeradas).
--
-- Fuso de São Paulo, como a 0013 fixou no resto do relatório.
-- =============================================================================

begin;

create or replace function public.serie_ligacoes(
  p_de    date,
  p_ate   date,
  p_owner uuid default null
)
returns table (
  dia       date,
  owner_id  uuid,
  vendedor  text,
  ligacoes  bigint,
  atendidas bigint
)
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
  select (coalesce(a.occurred_at, a.created_at)
            at time zone 'America/Sao_Paulo')::date as dia,
         d.owner_id,
         coalesce(p.full_name, '—')                 as vendedor,
         count(*)                                   as ligacoes,
         count(*) filter (where a.outcome = 'atendeu') as atendidas
    from public.deal_activities a
    join public.deals    d on d.id = a.deal_id
    left join public.profiles p on p.id = d.owner_id
   where a.channel = 'telefone'
     and (v_owner is null or d.owner_id = v_owner)
     and (coalesce(a.occurred_at, a.created_at)
            at time zone 'America/Sao_Paulo')::date between p_de and p_ate
   group by 1, 2, 3
   order by 1, 3;
end;
$$;

comment on function public.serie_ligacoes(date, date, uuid) is
  'Ligações por dia e por vendedor no fuso de São Paulo. Tentativas e atendidas. Escopo por rel_owner_efetivo: vendedor só vê a própria carteira.';

revoke all    on function public.serie_ligacoes(date, date, uuid) from public, anon;
grant execute on function public.serie_ligacoes(date, date, uuid) to authenticated;

commit;

-- =============================================================================
-- CONFERÊNCIA
-- =============================================================================
-- Ligações do mês por dia e vendedor:
--   select * from public.serie_ligacoes(date_trunc('month', current_date)::date,
--                                       current_date, null);
--
-- O total tem que bater com a chave `ligacoes` do relatório no mesmo período:
--   select sum(ligacoes) from public.serie_ligacoes('2026-08-01','2026-08-31', null);
--   select (public.relatorio_produtividade('2026-08-01','2026-08-31', null))->>'ligacoes';

-- =============================================================================
-- ROLLBACK
-- =============================================================================
-- begin;
--   drop function if exists public.serie_ligacoes(date, date, uuid);
-- commit;
