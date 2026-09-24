-- 0056a — Devolve a Roberto os leads que o "Salvar" passou para Heloísa sem pedido
-- Aplicada em produção em 24/09/2026. Critério: troca Roberto -> Heloísa feita
-- pelo próprio Roberto (audit_log), lead ainda com Heloísa e SEM nenhuma
-- atividade registrada por ela. Resultado: 51 devolvidos; 29 que ela já
-- trabalhou ficaram com ela.

create table if not exists public.bkp_dono_roberto_20260924 as
with f as (
 select distinct on (a.registro_id) a.registro_id id, a.created_at trocado_em
 from public.audit_log a
 where a.tabela='deals' and a.acao='UPDATE' and a.actor_id='0e85cdd8-0ea0-4608-a6c7-462f69252aea'
   and a.campos->'owner_id'->>'de'='0e85cdd8-0ea0-4608-a6c7-462f69252aea'
   and a.campos->'owner_id'->>'para'='b0312e00-23cf-4c37-a94d-db04b4bd2a10'
 order by a.registro_id, a.created_at desc)
select d.id, d.owner_id as owner_atual, f.trocado_em, now() as salvo_em
  from f join public.deals d on d.id = f.id
 where d.owner_id = 'b0312e00-23cf-4c37-a94d-db04b4bd2a10'
   and not exists (select 1 from public.deal_activities x
                    where x.deal_id = d.id and x.author_id = 'b0312e00-23cf-4c37-a94d-db04b4bd2a10');
alter table public.bkp_dono_roberto_20260924 enable row level security;
revoke all on public.bkp_dono_roberto_20260924 from anon, authenticated;

do $$
begin
  perform set_config('app.transferencia', 'on', true);
  update public.deals d set owner_id = '0e85cdd8-0ea0-4608-a6c7-462f69252aea'
    from public.bkp_dono_roberto_20260924 b
   where d.id = b.id and d.owner_id = b.owner_atual;
  insert into public.deal_owner_history (deal_id, owner_antes, owner_depois, execucao_id, regra, feito_por)
  select b.id, b.owner_atual, '0e85cdd8-0ea0-4608-a6c7-462f69252aea', gen_random_uuid(), 'correcao_troca_indevida_0056a', null
    from public.bkp_dono_roberto_20260924 b;
  perform set_config('app.transferencia', 'off', true);
end $$;

-- ROLLBACK (rodar sozinho):
-- do $$ begin
--   perform set_config('app.transferencia', 'on', true);
--   update public.deals d set owner_id = b.owner_atual
--     from public.bkp_dono_roberto_20260924 b where d.id = b.id;
--   perform set_config('app.transferencia', 'off', true);
-- end $$;
