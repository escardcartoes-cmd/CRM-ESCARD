-- =============================================================================
-- MIGRATION 20260828_0014 — Marcador de lead esgotado na régua de cadência
-- Projeto: CRM Funil de Vendas (Escard) · Supabase heevguvboffziehftucp
-- Depende de: 0001 a 0013
-- =============================================================================
-- A régua de cadência (5 toques em 15 dias) vive no frontend: o desfecho sem
-- contato agenda o próximo toque sozinho em `deals.next_followup_date`. Isso não
-- precisa de banco.
--
-- O que precisa é o FIM da régua. Quando o lead esgota as 5 tentativas — ou o
-- desfecho é "número errado"/"número inválido", onde insistir não resolve — ele
-- sai da esteira com `next_followup_date = null`. Sem um marcador, esse lead
-- fica indistinguível do lead que nunca teve follow-up agendado: some da fila e
-- ninguém nunca mais o encontra.
--
-- Uma coluna nullable resolve. Nada de tabela nova, nada de constraint, nada de
-- alteração em RPC. A RLS de `deals` já cobre a leitura.
-- =============================================================================

begin;

alter table public.deals
  add column if not exists cadencia_esgotada_em timestamptz;

comment on column public.deals.cadencia_esgotada_em is
  'Quando o lead saiu da esteira por esgotar a régua de cadência (5 tentativas sem contato efetivo) ou por contato inválido. NULL = está na régua. Volta a NULL no primeiro contato efetivo.';

-- Índice parcial: a consulta é sempre "os esgotados", nunca "os não esgotados".
-- Parcial mantém o índice pequeno mesmo com a carteira inteira na tabela.
create index if not exists deals_cadencia_esgotada_idx
  on public.deals (owner_id, cadencia_esgotada_em)
  where cadencia_esgotada_em is not null;

commit;

-- =============================================================================
-- CONFERÊNCIA
-- =============================================================================
-- Quantos saíram da esteira, por vendedor:
--   select p.full_name, count(*)
--     from public.deals d
--     join public.profiles p on p.id = d.owner_id
--    where d.cadencia_esgotada_em is not null
--    group by 1 order by 2 desc;
--
-- Devolver um lead à esteira à mão (ex.: telefone corrigido):
--   update public.deals
--      set cadencia_esgotada_em = null, next_followup_date = current_date
--    where id = '<uuid>';

-- =============================================================================
-- ROLLBACK
-- =============================================================================
-- begin;
--   drop index if exists public.deals_cadencia_esgotada_idx;
--   alter table public.deals drop column if exists cadencia_esgotada_em;
-- commit;
