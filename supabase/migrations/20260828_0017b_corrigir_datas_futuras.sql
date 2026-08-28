-- =============================================================================
-- CORREÇÃO DE DADOS — atividades com occurred_at futuro
-- Projeto: CRM Funil de Vendas (Escard)
-- Rodar DEPOIS da 0017 e SOMENTE depois de confirmar com a Priscila e a Heloísa
-- que os registros correspondem a contatos JÁ FEITOS.
-- =============================================================================
-- Se elas confirmarem que registravam logo depois de ligar, `created_at` é a
-- melhor aproximação disponível do momento real do contato — melhor que a data
-- futura, que é comprovadamente errada.
--
-- Se alguma delas disser que usava o registro para AGENDAR ligações futuras, aí
-- esses registros não são contatos feitos: devem ser apagados e o retorno
-- reagendado pelo campo "Próximo contato". NÃO rode este arquivo nesse caso.
--
-- Reunião fica de fora: `presencial` usa occurred_at como data da agenda.
-- =============================================================================

begin;

-- Backup antes de tocar em qualquer coisa. Sobrevive ao rollback da correção.
create table if not exists public.bkp_occurred_futuro_20260828 as
select id, deal_id, author_id, channel, outcome, note, occurred_at, created_at, now() as backup_em
  from public.deal_activities
 where occurred_at > now()
   and channel is distinct from 'presencial';

-- Quantos vão mudar (confira antes de dar commit se estiver rodando passo a passo)
do $$
declare v_qtd bigint;
begin
  select count(*) into v_qtd from public.bkp_occurred_futuro_20260828;
  raise notice 'Backup criado com % registros.', v_qtd;
end $$;

update public.deal_activities
   set occurred_at = created_at
 where occurred_at > now()
   and channel is distinct from 'presencial';

commit;

-- =============================================================================
-- CONFERÊNCIA
-- =============================================================================
-- Não pode sobrar nada além de reunião:
--   select channel, count(*) from public.deal_activities
--    where occurred_at > now() group by 1;
--
-- As ligações voltaram para os dias certos:
--   select date(occurred_at at time zone 'America/Sao_Paulo') as dia, count(*)
--     from public.deal_activities
--    where channel = 'telefone'
--      and occurred_at >= date_trunc('month', now())
--    group by 1 order by 1;

-- =============================================================================
-- ROLLBACK
-- =============================================================================
-- begin;
--   update public.deal_activities a
--      set occurred_at = b.occurred_at
--     from public.bkp_occurred_futuro_20260828 b
--    where a.id = b.id;
-- commit;
-- (a trava da 0017 barra o rollback: desligue o trigger antes,
--  alter table public.deal_activities disable trigger trg_atividade_data_valida;
--  e reative depois.)
