-- 0057 — Desempenho da carga do CRM (24/09/2026)
--
-- Diagnóstico (pg_stat_statements desde 10/08 + edge logs de 24h):
--  * Cada boot do app dispara ~25 requisições pesadas em paralelo. Houve 643
--    boots em 24h para ~6 usuários: o front refaz o boot inteiro a cada evento
--    de sessão (inclusive ao voltar para a aba). Correção no index.html.
--  * icp_indice devolve 26.482 objetos (~7,3 MB de JSON) por boot:
--    média 4,3 s, p90 10,3 s, máx 48 s. Aqui: versão compacta (4 campos).
--  * Policies de RLS que chamam função sem "(select ...)": o Postgres avalia
--    a função uma vez POR LINHA em vez de uma vez por consulta. As de
--    deal_activities e deal_stage_history pesam em followups/kanban/relatórios.
--  * escard_marcar_parceiros varre os 43 mil deals com regex a cada 10 min
--    (até 58 s). Passa a rodar de hora em hora — é idempotente.
--
-- Nada aqui muda resultado de consulta, só custo. Rollback no final.

-- 1) RLS: função avaliada uma vez por consulta (initplan) ---------------------
alter policy activities_usuario_ativo on public.deal_activities
  using ((select public.current_user_active()))
  with check ((select public.current_user_active()));

alter policy dsh_select on public.deal_stage_history
  using ((select public.audit_usuario_e_admin()) or owner_id = (select auth.uid()));

alter policy metas_select on public.metas
  using ((select public.rel_pode_ver_equipe()) or owner_id = (select auth.uid()));

alter policy audit_log_select_admin on public.audit_log
  using ((select public.audit_usuario_e_admin()));

alter policy deal_owner_history_admin_read on public.deal_owner_history
  using ((select public.is_admin()));

alter policy system_events_select_admin on public.system_events
  using ((select public.audit_usuario_e_admin()));

alter policy triagem_telefone_select on public.triagem_telefone
  using ((select public.rel_pode_ver_equipe()));

alter policy app_settings_update on public.app_settings
  using ((select public.audit_usuario_e_admin()))
  with check ((select public.audit_usuario_e_admin()));

-- 2) Índice ICP compacto ------------------------------------------------------
-- Uma linha = [deal_id, tier, mascara, score]
--   mascara: 1 = produto de entrada Benefícios · 2 = Cobrança
--            4 = afinidade Private Alta ou Média · 8 = afinidade Alta
-- Mesma regra de icpProdutosDe() no front. RLS da view (dono/admin) vale igual.
-- Detalhes (motivo, roadmap, rota...) o modal busca só do lead aberto.
create or replace function public.icp_indice_compacto()
returns jsonb
language sql
stable
set search_path = public, pg_temp
as $$
  select coalesce(jsonb_agg(jsonb_build_array(
           v.deal_id,
           v.tier,
           (case when lower(coalesce(v.produto_entrada,'')) like '%benef%' then 1 else 0 end)
         + (case when lower(coalesce(v.produto_entrada,'')) like '%cobran%' then 2 else 0 end)
         + (case when v.afinidade_private in ('Alta','Média','Media') then 4 else 0 end)
         + (case when v.afinidade_private = 'Alta' then 8 else 0 end),
           v.score)), '[]'::jsonb)
    from public.vw_sdr_priorizacao_escard v;
$$;

revoke all on function public.icp_indice_compacto() from public, anon;
grant execute on function public.icp_indice_compacto() to authenticated;

-- 3) Cron de parceiros: de 10 em 10 min para de hora em hora -------------------
select cron.alter_job(
  (select jobid from cron.job where jobname = 'escard_marcar_parceiros'),
  schedule := '7 * * * *'
);

-- ROLLBACK (rodar sozinho):
-- alter policy activities_usuario_ativo on public.deal_activities using (public.current_user_active()) with check (public.current_user_active());
-- alter policy dsh_select on public.deal_stage_history using (public.audit_usuario_e_admin() or owner_id = auth.uid());
-- alter policy metas_select on public.metas using (public.rel_pode_ver_equipe() or owner_id = auth.uid());
-- alter policy audit_log_select_admin on public.audit_log using (public.audit_usuario_e_admin());
-- alter policy deal_owner_history_admin_read on public.deal_owner_history using (public.is_admin());
-- alter policy system_events_select_admin on public.system_events using (public.audit_usuario_e_admin());
-- alter policy triagem_telefone_select on public.triagem_telefone using (public.rel_pode_ver_equipe());
-- alter policy app_settings_update on public.app_settings using (public.audit_usuario_e_admin()) with check (public.audit_usuario_e_admin());
-- drop function if exists public.icp_indice_compacto();
-- select cron.alter_job((select jobid from cron.job where jobname='escard_marcar_parceiros'), schedule := '*/10 * * * *');
