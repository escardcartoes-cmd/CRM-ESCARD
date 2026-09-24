-- 0056 — Troca de responsável só por transferência explícita (24/09/2026)
--
-- Causa: o "Salvar" do modal trocava o dono do lead sem o admin pedir
-- (80 leads de Roberto foram para Heloísa em 10 dias; o lead sumia do funil
-- filtrado). A 0055 resolveu a etapa; o dono seguia vulnerável porque qualquer
-- aba desatualizada reenviava owner_id.
--
-- Regra: update direto na tabela (PATCH do PostgREST) feito por usuário logado
-- NÃO troca owner_id — o valor atual é mantido. Troca de dono só por:
--   • RPC public.transferir_lead (admin, após confirmar de/para no modal);
--   • RPCs de distribuição (distribuir_leads etc., chamadas via POST);
--   • scripts SQL (sem usuário logado).

create or replace function public.fn_trava_troca_dono()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.owner_id is not distinct from old.owner_id then return new; end if;
  if auth.uid() is null then return new; end if;
  if coalesce(current_setting('app.transferencia', true), 'off') = 'on' then return new; end if;
  if coalesce(current_setting('request.method', true), '') = 'PATCH' then
    new.owner_id := old.owner_id;
  end if;
  return new;
end;
$$;

revoke all on function public.fn_trava_troca_dono() from public, anon, authenticated;

drop trigger if exists trg_00_trava_troca_dono on public.deals;
create trigger trg_00_trava_troca_dono
  before update of owner_id on public.deals
  for each row execute function public.fn_trava_troca_dono();

create or replace function public.transferir_lead(p_deal uuid, p_owner uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_antes uuid;
begin
  if not public.is_admin() then
    raise exception 'Somente admin transfere lead';
  end if;
  if not exists (select 1 from public.profiles where id = p_owner and active is not false and deleted_at is null) then
    raise exception 'Responsável inválido ou inativo';
  end if;
  select owner_id into v_antes from public.deals where id = p_deal;
  if not found then raise exception 'Lead não encontrado'; end if;
  if v_antes is not distinct from p_owner then return; end if;

  perform set_config('app.transferencia', 'on', true);
  update public.deals set owner_id = p_owner where id = p_deal;
  perform set_config('app.transferencia', 'off', true);

  insert into public.deal_owner_history (deal_id, owner_antes, owner_depois, execucao_id, regra, feito_por)
  values (p_deal, v_antes, p_owner, gen_random_uuid(), 'transferencia_manual', auth.uid());
end;
$$;

revoke all on function public.transferir_lead(uuid, uuid) from public, anon;
grant execute on function public.transferir_lead(uuid, uuid) to authenticated;

-- ROLLBACK (rodar sozinho):
-- drop trigger if exists trg_00_trava_troca_dono on public.deals;
-- drop function if exists public.fn_trava_troca_dono();
-- drop function if exists public.transferir_lead(uuid, uuid);
