-- 0052 — E-mail "Enviado" passa a ser gravado como 'enviado' (antes: 'bounce') — 24/09/2026.
-- Motivo: 'bounce' em inglês significa "e-mail devolvido". O nome induzia a erro (a 1ª versão da 0051
-- tratou e-mail enviado como falha). 379 registros convertidos.
-- APLICADA EM PRODUÇÃO via MCP, em duas migrations: 0052a (backup) e 0052 (mudança).
-- Compatível com tela antiga: trigger converte 'bounce' -> 'enviado' em qualquer INSERT/UPDATE.

-- =====================================================================
-- SEÇÃO 1 — BACKUP (rodado sozinho, antes da mudança)
-- =====================================================================
create table public.bkp_outcome_bounce_20260924 as
  select id, outcome from public.deal_activities where outcome = 'bounce';
alter table public.bkp_outcome_bounce_20260924 enable row level security;
revoke all on public.bkp_outcome_bounce_20260924 from anon, authenticated;

-- =====================================================================
-- SEÇÃO 2 — MUDANÇA
-- =====================================================================
create or replace function public.fn_atividade_normaliza_resultado()
 returns trigger language plpgsql set search_path to ''
as $function$
begin
  if new.channel = 'email' and new.outcome = 'bounce' then
    new.outcome := 'enviado';
  end if;
  return new;
end;
$function$;
revoke all on function public.fn_atividade_normaliza_resultado() from public, anon, authenticated;

create trigger trg_atividade_normaliza_resultado
  before insert or update of outcome, channel on public.deal_activities
  for each row execute function public.fn_atividade_normaliza_resultado();

alter table public.deal_activities drop constraint resultado_valido;
update public.deal_activities set outcome = 'enviado' where outcome = 'bounce';
alter table public.deal_activities add constraint resultado_valido check (
     ((channel = 'nota') and (outcome is null))
  or ((channel = 'telefone')   and (outcome = any (array['atendeu','nao_atendeu','caixa_postal','numero_errado'])))
  or ((channel = 'whatsapp')   and (outcome = any (array['respondeu','visualizou','nao_visualizou','numero_invalido'])))
  or ((channel = 'email')      and (outcome = any (array['respondeu','sem_resposta','enviado'])))
  or ((channel = 'presencial') and (outcome = any (array['realizada','nao_compareceu'])))
);

-- =====================================================================
-- SEÇÃO 3 — CONFERÊNCIA (resultado em 24/09: 0 / 379 / 379 / false / 1)
-- =====================================================================
-- select
--  (select count(*) from deal_activities where outcome='bounce') bounce_restante,
--  (select count(*) from deal_activities where outcome='enviado') enviado,
--  (select count(*) from deal_activities a join bkp_outcome_bounce_20260924 b on b.id=a.id where a.outcome='enviado') conferem_bkp,
--  (select pg_get_constraintdef(oid) from pg_constraint where conname='resultado_valido') ~ 'bounce' constraint_cita_bounce,
--  (select count(*) from pg_trigger where tgname='trg_atividade_normaliza_resultado') trigger_ok;

-- =====================================================================
-- SEÇÃO 4 — ROLLBACK (rodar SEPARADO, só se necessário, e SÓ depois de voltar o index.html antigo)
-- =====================================================================
-- drop trigger trg_atividade_normaliza_resultado on public.deal_activities;
-- drop function public.fn_atividade_normaliza_resultado();
-- alter table public.deal_activities drop constraint resultado_valido;
-- update public.deal_activities a set outcome = 'bounce'
--   from public.bkp_outcome_bounce_20260924 b where b.id = a.id and a.outcome = 'enviado';
-- alter table public.deal_activities add constraint resultado_valido check (
--      ((channel = 'nota') and (outcome is null))
--   or ((channel = 'telefone')   and (outcome = any (array['atendeu','nao_atendeu','caixa_postal','numero_errado'])))
--   or ((channel = 'whatsapp')   and (outcome = any (array['respondeu','visualizou','nao_visualizou','numero_invalido'])))
--   or ((channel = 'email')      and (outcome = any (array['respondeu','sem_resposta','bounce'])))
--   or ((channel = 'presencial') and (outcome = any (array['realizada','nao_compareceu'])))
-- );
-- (e-mails "Enviado" gravados depois da 0052 ficam 'enviado' e precisariam de UPDATE próprio)
