-- =====================================================================
-- CRM-ESCARD · Migration 0042 · 2026-09-21  ·  JA APLICADA EM PRODUCAO
-- Dashboard em branco apos a base passar de 19.176 para 43.537 leads.
-- =====================================================================
--
-- DIAGNOSTICO
--
-- Sintoma: Dashboard abria com os tres paineis vazios (sem cards de metrica,
-- sem funil, sem ranking). Nenhum erro no console, nenhuma query falhando.
--
-- Medicao no navegador, antes:
--   select count(*) em deals ......... 4.160 ms
--   rpc kanban_contagem .............. 4.023 ms
--   carregarKanban() ................. 9.303 ms
--
-- Chamar renderDashboard() a mao, depois que carregarKanban() terminava,
-- preenchia tudo. Ou seja: nao era dado ausente, era corrida — o boot
-- renderizava o dashboard antes de os dados chegarem, e nao re-renderizava.
-- Com 19 mil leads o carregamento cabia na janela do boot; com 43 mil, nao.
--
-- CAUSA RAIZ
--
-- A policy RESTRICTIVE active_users_only chamava current_user_active()
-- diretamente no USING/WITH CHECK. Sem o wrapper (select ...), o Postgres
-- trata a chamada como dependente da linha e reavalia a funcao PARA CADA
-- LINHA — 43.537 execucoes por consulta, cada uma com um lookup em profiles.
--
-- As demais policies de deals ja estavam na forma InitPlan
--   ((owner_id = (select auth.uid())) or (select is_admin()))
-- e a migration 0024 ja tinha corrigido o mesmo padrao na view de
-- priorizacao. Esta policy, criada depois, passou batido.
--
-- A CORRECAO
--
-- Envolver a chamada em (select ...). Semantica de seguranca identica:
-- a funcao continua sendo avaliada, so que uma unica vez por consulta.
-- Nenhuma permissao muda.
--
-- RESULTADO MEDIDO, depois:
--   select count(*) em deals ......... 1.044 ms   (4x)
--   rpc kanban_contagem .............. 1.139 ms   (3,5x)
--   carregarKanban() ..................  749 ms   (12x)
--   Dashboard carrega sozinho no boot.
-- =====================================================================

drop policy if exists active_users_only on public.deals;
create policy active_users_only on public.deals
  as restrictive for all to authenticated
  using ((select public.current_user_active()))
  with check ((select public.current_user_active()));

drop policy if exists active_users_only on public.deal_notes;
create policy active_users_only on public.deal_notes
  as restrictive for all to authenticated
  using ((select public.current_user_active()))
  with check ((select public.current_user_active()));

drop policy if exists active_users_only on public.companies;
create policy active_users_only on public.companies
  as restrictive for all to authenticated
  using ((select public.current_user_active()))
  with check ((select public.current_user_active()));

drop policy if exists active_users_only on public.contacts;
create policy active_users_only on public.contacts
  as restrictive for all to authenticated
  using ((select public.current_user_active()))
  with check ((select public.current_user_active()));

drop policy if exists active_users_only on public.pipeline_stages;
create policy active_users_only on public.pipeline_stages
  as restrictive for all to authenticated
  using ((select public.current_user_active()))
  with check ((select public.current_user_active()));


-- =====================================================================
-- CONFERENCIA
-- =====================================================================
-- As cinco devem aparecer com (SELECT current_user_active()) no qual:
--
-- select tablename, policyname, permissive, cmd, qual, with_check
--   from pg_policies
--  where schemaname='public' and policyname='active_users_only'
--  order by tablename;
--
-- Teste de acesso, obrigatorio apos aplicar:
--   1. Entrar como admin  -> ve todos os leads
--   2. Entrar como vendedor -> ve so os proprios
--   3. Usuario com profiles.active = false -> continua sem acesso


-- =====================================================================
-- ROLLBACK  ·  volta a forma anterior (lenta, mas funcional)
-- =====================================================================
-- drop policy if exists active_users_only on public.deals;
-- create policy active_users_only on public.deals
--   as restrictive for all to authenticated
--   using (public.current_user_active())
--   with check (public.current_user_active());
-- (idem para deal_notes, companies, contacts, pipeline_stages)


-- =====================================================================
-- PENDENTE — nao resolvido por esta migration
-- =====================================================================
-- 1. A corrida do boot continua existindo: o dashboard renderiza uma vez
--    e nao re-renderiza quando os dados chegam. Hoje cabe na janela porque
--    carregarKanban() leva 749 ms, mas volta a aparecer quando a base
--    crescer de novo. A correcao definitiva e chamar renderDashboard()
--    no fim do carregamento, nao em paralelo com ele.
--
-- 2. loadDeals() em producao so recarrega os leads ja presentes em memoria
--    ("guarda contra sessao muito longa"): com a lista vazia ele retorna em
--    0 ms sem buscar nada. Quem popula o funil e carregarKanban().
--    Nao e bug hoje, mas e uma armadilha para quem mexer nesse fluxo.
--
-- 3. rel_metricas e os relatorios nao foram medidos com 43 mil leads.
--    A CTE de dormentes ja estourou statement_timeout uma vez (migration 0021).
