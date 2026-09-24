-- 0053 — "Sem interesse" leva o lead direto para Perdidos (regra de Roberto, 24/09/2026).
-- (1) RPC marcar_sem_interesse(deal): chamada pela opção "✖ Sem interesse → Perdido" do registro de contato.
--     SECURITY INVOKER (RLS decide). Move para Perdidos, motivo "Sem interesse", zera follow-up e cadência.
--     Se o lead já estiver em Perdidos (ex.: trigger 0041 dos 4 registros), só troca o motivo.
-- (2) Histórico: 22 leads abertos cuja observação registra recusa fechada foram movidos (origem 'sistema').
--     Padrões: "sem interesse", "não tem/possui/há interesse", "não quer", "não aceita", "já tem/possui/usa/trabalha com".
--     Excluídos por ressalva no texto ("mas", "apresentação", "parceria", "proposta") — ex.: OXLEY (parceria em
--     negociação) e Madeiras Vinand (apresentação enviada) continuam abertos.
-- APLICADA EM PRODUÇÃO via MCP: 0053a (backup) e 0053 (mudança).

-- =====================================================================
-- SEÇÃO 1 — BACKUP (rodado sozinho, antes)
-- =====================================================================
create table public.bkp_sem_interesse_20260924 as
with n as (
  select a.deal_id,
         lower(translate(a.note,'ÁÀÃÂÉÊÍÓÔÕÚÇáàãâéêíóôõúç','AAAAEEIOOOUCaaaaeeiooouc')) t
    from public.deal_activities a where a.note is not null
)
select d.id, d.stage_id, d.stage_changed_at, d.next_followup_date, d.loss_reason, d.cadencia_esgotada_em
  from public.deals d join public.pipeline_stages s on s.id = d.stage_id
 where not s.is_lost and not s.is_won
   and exists (select 1 from n where n.deal_id = d.id
        and n.t ~ '(sem interesse|nao tem interesse|nao possui interesse|nao ha interesse|\mnao quer|\mnao aceita|\mja tem|\mja possui|\mja trabalha com|\mja usa)'
        and n.t !~ '(\mmas\M|apresenta|parceria|proposta)');
alter table public.bkp_sem_interesse_20260924 enable row level security;
revoke all on public.bkp_sem_interesse_20260924 from anon, authenticated;

-- =====================================================================
-- SEÇÃO 2 — MUDANÇA
-- =====================================================================
create or replace function public.marcar_sem_interesse(p_deal uuid)
 returns uuid language plpgsql set search_path to ''
as $function$
declare v_perdidos uuid; v_won boolean; v_lost boolean;
begin
  select coalesce(s.is_won,false), coalesce(s.is_lost,false) into v_won, v_lost
    from public.deals d join public.pipeline_stages s on s.id = d.stage_id where d.id = p_deal;
  if not found then raise exception 'Lead não encontrado ou sem permissão'; end if;
  if v_won then raise exception 'Lead já está ganho; não pode ir para Perdidos por aqui'; end if;
  select id into v_perdidos from public.pipeline_stages where is_lost = true order by order_index limit 1;
  if v_lost then
    update public.deals set loss_reason = 'Sem interesse' where id = p_deal;
    return v_perdidos;
  end if;
  update public.deals
     set stage_id = v_perdidos, stage_changed_at = now(), next_followup_date = null,
         cadencia_esgotada_em = null, loss_reason = 'Sem interesse'
   where id = p_deal;
  if not found then raise exception 'Sem permissão para alterar este lead'; end if;
  return v_perdidos;
end;
$function$;
revoke all on function public.marcar_sem_interesse(uuid) from public, anon;
grant execute on function public.marcar_sem_interesse(uuid) to authenticated, service_role;

do $$
declare v_perdidos uuid;
begin
  select id into v_perdidos from public.pipeline_stages where is_lost = true order by order_index limit 1;
  perform set_config('app.mov_automatica', 'on', true);
  update public.deals d
     set stage_id = v_perdidos, stage_changed_at = now(), next_followup_date = null,
         cadencia_esgotada_em = null, loss_reason = 'Sem interesse'
    from public.bkp_sem_interesse_20260924 b where b.id = d.id;
  perform set_config('app.mov_automatica', 'off', true);
end $$;

-- =====================================================================
-- SEÇÃO 3 — CONFERÊNCIA (24/09: 22 / 22 / 22 / sistema)
-- =====================================================================
-- select count(*) total,
--  count(*) filter (where s.is_lost and d.loss_reason='Sem interesse' and d.next_followup_date is null) em_perdidos,
--  (select count(*) from deal_stage_history h join bkp_sem_interesse_20260924 b on h.deal_id=b.id
--    where h.changed_at > '2026-09-24') hist_rows
-- from bkp_sem_interesse_20260924 b join deals d on d.id=b.id join pipeline_stages s on s.id=d.stage_id;

-- =====================================================================
-- SEÇÃO 4 — ROLLBACK do histórico (rodar SEPARADO, só se necessário)
-- =====================================================================
-- do $$ begin
--   perform set_config('app.mov_automatica', 'on', true);
--   update public.deals d
--      set stage_id = b.stage_id, stage_changed_at = b.stage_changed_at, next_followup_date = b.next_followup_date,
--          loss_reason = b.loss_reason, cadencia_esgotada_em = b.cadencia_esgotada_em
--     from public.bkp_sem_interesse_20260924 b where b.id = d.id;
--   perform set_config('app.mov_automatica', 'off', true);
-- end $$;
-- (a RPC pode ficar: sem o botão na tela, ninguém a chama)
