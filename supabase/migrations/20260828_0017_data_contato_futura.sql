-- =============================================================================
-- MIGRATION 20260828_0017 — Contato não pode ter data futura
-- Projeto: CRM Funil de Vendas (Escard) · Supabase heevguvboffziehftucp
-- Depende de: 0001 a 0016
-- =============================================================================
-- O DIAGNÓSTICO
--
-- 41 atividades estavam gravadas com `occurred_at` no futuro — 28 delas ligações.
-- Não foi um deslize isolado: a mesma pessoa repetiu em 26, 27 e 28/08, sempre
-- apontando para 31/08, e uma segunda pessoa fez o mesmo uma vez.
--
--   quem       digitado_em   ocorreu_em   canal      qtd
--   Priscila   28/08         31/08        telefone    22
--   Priscila   28/08         31/08        email        7
--   Priscila   27/08         31/08        email        7
--   Priscila   27/08         31/08        telefone     4
--   Priscila   26/08         28/08        telefone     1
--   Priscila   26/08         01/09        whatsapp     1
--   Heloísa    26/08         31/08        whatsapp     1
--   Heloísa    26/08         31/08        telefone     1
--
-- O deslocamento não é constante (26→31 são 5 dias, 27→31 são 4, 28→31 são 3):
-- não é bug de fuso nem offset fixo. É o campo "Quando" recebendo a data do
-- PRÓXIMO contato. O formulário tem dois campos de data e o operador preenche o
-- errado — problema de interface, resolvido aqui na porta do banco e no front.
--
-- O ESTRAGO
--
-- Ligação com data futura não entra na meta do dia em que foi feita. É a razão
-- de o painel "Progresso das metas" mostrar zero para três das quatro vendedoras
-- num dia em que elas trabalharam. No total do mês contava (31/08 ainda é
-- agosto), então o número mensal estava certo e o diário, errado — justamente o
-- que a gestão cobra todo dia.
--
-- REUNIÃO É A EXCEÇÃO, DE PROPÓSITO
--
-- A agenda (migration 0008) usa `occurred_at` como a data/hora da reunião, que é
-- futura enquanto ela está marcada. `channel = 'presencial'` fica de fora da
-- trava — sem isso, agendar reunião quebraria.
-- =============================================================================

begin;

create or replace function public.fn_atividade_data_valida()
returns trigger
language plpgsql
as $$
begin
  -- Tolerância de 5 minutos: relógio do navegador adiantado não pode barrar um
  -- registro legítimo.
  if new.channel is distinct from 'presencial'
     and new.occurred_at is not null
     and new.occurred_at > now() + interval '5 minutes' then
    raise exception
      'A data do contato não pode ser futura. Para agendar o retorno, use o campo "Próximo contato".'
      using errcode = '22023';
  end if;
  return new;
end;
$$;

comment on function public.fn_atividade_data_valida() is
  'Impede occurred_at futuro em atividade que não seja reunião. Reunião (presencial) usa occurred_at como data da agenda e fica de fora.';

drop trigger if exists trg_atividade_data_valida on public.deal_activities;
create trigger trg_atividade_data_valida
  before insert or update of occurred_at, channel on public.deal_activities
  for each row execute function public.fn_atividade_data_valida();

commit;

-- =============================================================================
-- CONFERÊNCIA DA TRAVA (rodar depois do commit)
-- =============================================================================
-- Tem que dar erro:
--   insert into public.deal_activities (deal_id, channel, outcome, occurred_at)
--   select id, 'telefone', 'nao_atendeu', now() + interval '3 days'
--     from public.deals limit 1;
--
-- Tem que passar (reunião é a exceção):
--   insert into public.deal_activities (deal_id, channel, meeting_status, meeting_mode, occurred_at)
--   select id, 'presencial', 'agendada', 'online', now() + interval '3 days'
--     from public.deals limit 1;

-- =============================================================================
-- ROLLBACK
-- =============================================================================
-- begin;
--   drop trigger if exists trg_atividade_data_valida on public.deal_activities;
--   drop function if exists public.fn_atividade_data_valida();
-- commit;
