-- 0055 — Trava de reversão de etapa automática (24/09/2026)
--
-- Causa: o modal do lead lia a etapa na abertura e o "Salvar" reenviava esse
-- valor. Quando o registro de contato fazia o trigger avançar a etapa
-- (Leads Novos -> Sem Contato / Contato Feito), o Salvar seguinte devolvia o
-- lead para a etapa antiga (e o fn_followup_coerente zerava o follow-up).
-- ~1.000 reversões desde 28/08; 534 leads presos no estado revertido.
--
-- O index.html corrigido deixa de reenviar etapa não tocada, mas abas abertas
-- antes do deploy continuam com o código velho até recarregar. Esta trava
-- protege no banco, já.
--
-- Regra: update feito por usuário que tenta devolver o lead exatamente para a
-- etapa de onde o SISTEMA acabou de tirá-lo (até 30 min), SEM carimbar
-- stage_changed_at, é reenvio de etapa velha -> a etapa atual é mantida.
-- Troca deliberada passa: o arrastar do Funil e o modal corrigido carimbam
-- stage_changed_at.

create or replace function public.fn_trava_reversao_automatica()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_ult record;
begin
  if new.stage_id is not distinct from old.stage_id then return new; end if;
  if coalesce(current_setting('app.mov_automatica', true), 'off') = 'on' then return new; end if;
  if auth.uid() is null then return new; end if;
  if new.stage_changed_at is distinct from old.stage_changed_at then return new; end if;

  select h.from_stage_id, h.to_stage_id, h.origem, h.changed_at
    into v_ult
    from public.deal_stage_history h
   where h.deal_id = old.id
   order by h.changed_at desc
   limit 1;

  if found
     and v_ult.origem = 'sistema'
     and v_ult.to_stage_id = old.stage_id
     and v_ult.from_stage_id is not distinct from new.stage_id
     and v_ult.changed_at > now() - interval '30 minutes'
  then
    new.stage_id           := old.stage_id;
    new.next_followup_date := old.next_followup_date;
    new.loss_reason        := old.loss_reason;
  end if;

  return new;
end;
$$;

revoke all on function public.fn_trava_reversao_automatica() from public, anon, authenticated;

drop trigger if exists trg_00_trava_reversao_automatica on public.deals;
-- Nome com "00" para disparar antes de trg_deal_terminal_sem_followup e
-- trg_followup_coerente (BEFORE triggers rodam em ordem alfabética).
create trigger trg_00_trava_reversao_automatica
  before update of stage_id on public.deals
  for each row execute function public.fn_trava_reversao_automatica();

-- ROLLBACK (rodar sozinho, nunca junto):
-- drop trigger if exists trg_00_trava_reversao_automatica on public.deals;
-- drop function if exists public.fn_trava_reversao_automatica();
