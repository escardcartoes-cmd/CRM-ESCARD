-- 0041 — 4 tentativas seguidas sem resposta => "Perdidos"
-- APLICADA EM PRODUÇÃO em 21/09/2026 via MCP (0041 + 0041b). Este arquivo é
-- documentação do estado final e do rollback. NÃO reexecutar o backfill.
--
-- Regra: 4 registros de telefone/WhatsApp/e-mail CONSECUTIVOS desde o último
-- contato efetivo (atendeu/respondeu/realizada ou reunião agendada/realizada)
-- levam o lead para "Perdidos" (is_lost, fora do Follow-up), motivo "Sem resposta".
-- Só em "Leads Novos", "Sem Contato" e "Contato Feito". Movimento = 'sistema'.

-- ============================ 1. FUNÇÃO + TRIGGER ============================
create or replace function public.fn_perdido_por_tentativas()
returns trigger language plpgsql security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_nome text; v_won boolean; v_lost boolean;
  v_perdidos uuid; v_ult timestamptz; v_n integer;
begin
  if new.channel not in ('telefone', 'whatsapp', 'email') then return null; end if;
  if coalesce(new.outcome in ('atendeu', 'respondeu', 'realizada'), false) then return null; end if;

  select s.name, coalesce(s.is_won, false), coalesce(s.is_lost, false)
    into v_nome, v_won, v_lost
    from public.deals d join public.pipeline_stages s on s.id = d.stage_id
   where d.id = new.deal_id;
  if not found or v_won or v_lost then return null; end if;
  if v_nome not in ('Leads Novos', 'Sem Contato', 'Contato Feito') then return null; end if;

  select max(occurred_at) into v_ult from public.deal_activities
   where deal_id = new.deal_id
     and (outcome in ('atendeu','respondeu','realizada') or meeting_status in ('agendada','realizada'));

  select count(*) into v_n from public.deal_activities
   where deal_id = new.deal_id
     and channel in ('telefone', 'whatsapp', 'email')
     and (v_ult is null or occurred_at > v_ult);
  if v_n < 4 then return null; end if;

  select id into v_perdidos from public.pipeline_stages
   where is_lost = true order by order_index limit 1;
  if v_perdidos is null then return null; end if;

  perform set_config('app.mov_automatica', 'on', true);
  update public.deals
     set stage_id = v_perdidos, stage_changed_at = now(), next_followup_date = null,
         loss_reason = coalesce(nullif(loss_reason, ''), 'Sem resposta'), updated_at = now()
   where id = new.deal_id;
  perform set_config('app.mov_automatica', 'off', true);
  return null;
end;
$function$;
revoke all on function public.fn_perdido_por_tentativas() from public, anon, authenticated;

-- Ordem alfabética: depois de trg_etapa_automatica, antes de trg_rediscagem_sem_contato.
drop trigger if exists trg_perdido_por_tentativas on public.deal_activities;
create trigger trg_perdido_por_tentativas after insert on public.deal_activities
for each row execute function public.fn_perdido_por_tentativas();

-- Trava: etapa terminal nunca carrega follow-up nem marca de régua (antes só na troca de etapa).
create or replace function public.fn_deal_terminal_sem_followup()
returns trigger language plpgsql security definer set search_path to 'public'
as $function$
declare v_terminal boolean;
begin
  select (is_lost or is_won) into v_terminal from public.pipeline_stages where id = new.stage_id;
  if coalesce(v_terminal, false) then
    new.next_followup_date := null;
    new.cadencia_esgotada_em := null;
  end if;
  return new;
end;
$function$;

-- ============================ 2. BACKUP (já feito) ============================
-- public.bkp_0041_perdido_tentativas — 155 linhas (10 Leads Novos, 130 Sem Contato,
-- 15 Contato Feito; 141 Ludmylla, 14 Heloísa). RLS ligado, sem grant para anon/authenticated.

-- ============================ 3. CONFERÊNCIA ============================
-- select s.name, count(*) from public.bkp_0041_perdido_tentativas b
--   join public.deals d on d.id = b.id join public.pipeline_stages s on s.id = d.stage_id group by 1;
-- select origem, count(*) from public.deal_stage_history h
--   join public.bkp_0041_perdido_tentativas b on b.id = h.deal_id
--  where h.changed_at::date = '2026-09-21' group by 1;   -- esperado: sistema = 155

-- ============================ 4. ROLLBACK — rodar SEPARADO ============================
-- 4a. Desligar a regra:
-- drop trigger if exists trg_perdido_por_tentativas on public.deal_activities;
-- drop function if exists public.fn_perdido_por_tentativas();
--
-- 4b. Devolver os 155 leads (só os que continuam em Perdidos):
-- do $$ begin
--   perform set_config('app.mov_automatica','on',true);
--   update public.deals d
--      set stage_id = b.stage_id, stage_changed_at = b.stage_changed_at,
--          next_followup_date = b.next_followup_date, loss_reason = b.loss_reason
--     from public.bkp_0041_perdido_tentativas b
--    where b.id = d.id and d.stage_id = '41430bd1-4c5f-47b1-a108-e6733996303f';
-- end $$;
