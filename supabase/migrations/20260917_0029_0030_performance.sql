-- =============================================================================
-- 0029 + 0030 — Performance do Follow-up e do Dashboard
-- APLICADAS EM PRODUCAO em 17/09/2026 via Supabase MCP (apply_migration).
-- Este arquivo fica no repo como documentacao e rollback.
--
-- DIAGNOSTICO (EXPLAIN ANALYZE em producao + logs de edge):
--
--   followups_contadores  media real 1.302 ms  (758 chamadas)
--   followups_list        media real   552 ms
--   dashboard_stats       media real   409 ms  (1.256 chamadas)
--
--   Causa 1 — calculo antes do filtro: a CTE `base` calculava "dias parado"
--   com subconsulta correlacionada para CADA lead da tabela (19.182) e so
--   depois restringia as etapas de esteira (1.077). Seq Scan em deals com
--   SubPlan por linha.
--
--   Causa 2 — CTE nao materializada: `base` e referenciada 6 vezes e
--   `visiveis` 9 vezes. Sem MATERIALIZED o Postgres inlina e refaz o scan
--   inteiro uma vez por referencia.
--
--   Causa 3 — followups_list rodava TRES subconsultas por linha
--   (max, count e max filtrado) sobre a mesma tabela.
--
-- CORRECAO: filtrar por etapa ANTES de calcular, trocar subconsulta
-- correlacionada por LATERAL agregado, materializar as CTEs, e indice parcial
-- para contato efetivo.
--
-- MEDIDO: 93 ms -> 17,5 ms por passagem, e uma passagem em vez de seis.
--
-- Corrige junto uma inconsistencia da 0027: o lead quente aparecia na lista
-- mas nao era contado pelos contadores (o filtro de etapa era so in_followup).
-- =============================================================================

-- Indice parcial para o "ultimo contato efetivo"
create index if not exists deal_activities_efetivo_idx
  on public.deal_activities (deal_id, occurred_at desc)
  where outcome in ('atendeu','respondeu','realizada');

-- O corpo completo das tres funcoes esta aplicado em producao. Para reler:
--   select pg_get_functiondef(p.oid)
--     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
--    where n.nspname = 'public'
--      and p.proname in ('followups_contadores','followups_list','dashboard_stats');
--
-- As tres mudancas, em resumo:
--
-- 1. followups_contadores
--      - `base as materialized`
--      - `from pipeline_stages s join deals d on d.stage_id = s.id` (etapa primeiro)
--      - subconsulta correlacionada -> `left join lateral (select max(occurred_at)
--        from deal_activities where deal_id = d.id and outcome in (...)) ef on true`
--      - filtro de etapa passa a ser `(s.in_followup = true or d.quente = true)`
--
-- 2. followups_list
--      - `base as materialized`
--      - tres subconsultas por linha -> um unico LATERAL com
--        max(occurred_at), count(*) e max(...) filter (where outcome in (...))
--      - mesma inversao de ordem (etapa antes do calculo)
--
-- 3. dashboard_stats
--      - `WITH visiveis AS MATERIALIZED (...)` — uma palavra, nenhuma
--        mudanca de resultado

notify pgrst, 'reload schema';


-- =============================================================================
-- CONFERENCIA (rodar depois, uma de cada vez)
-- =============================================================================

-- Tempo real da fila, como a tela chama:
-- explain (analyze, buffers) select public.followups_contadores();
--   -> Execution Time esperado abaixo de 60 ms

-- Contadores batem com a lista (quente incluido nos dois):
-- select (public.followups_contadores() ->> 'esteira')::int as contador,
--        (select count(*) from public.followups_list('esteira', null, null, 0, null, 10000, 0)) as lista;
--   -> os dois numeros tem que ser iguais


-- =============================================================================
-- ROLLBACK — NAO executar junto.
-- =============================================================================
-- As versoes anteriores das tres funcoes estao no historico do git, nos
-- arquivos de migration que as criaram. Para voltar, reexecutar aqueles corpos
-- via create or replace (as assinaturas nao mudaram — nenhum drop e necessario).
--
-- O indice pode sair sozinho, sem afetar resultado:
-- drop index if exists public.deal_activities_efetivo_idx;
