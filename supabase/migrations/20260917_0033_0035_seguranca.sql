-- =============================================================================
-- 0033 + 0034 + 0035 — Endurecimento de seguranca e policy unica em profiles
-- APLICADAS EM PRODUCAO em 17/09/2026 via Supabase MCP.
--
-- ACHADO (linter do Supabase):
--   12 funcoes SECURITY DEFINER chamaveis SEM LOGIN, via
--   /rest/v1/rpc/<nome>, usando apenas a chave publica do projeto.
--
-- DUAS FICAM ABERTAS DE PROPOSITO — nao revogar:
--   processar_descadastro      -> link de descadastro do e-mail e anonimo
--   registrar_evento_tracking  -> pixel de abertura/clique e anonimo
--   Revogar essas duas quebra o funil de e-mail do SDR SIX.
--
-- ARMADILHA QUE CUSTOU UMA MIGRATION:
--   A 0033 revogou de `anon` e `authenticated` e o linter continuou acusando.
--   O grant real nao era nominal, era do papel PUBLIC (`=X/postgres` na ACL).
--   Todo papel herda de PUBLIC, entao revogar nominalmente nao tira nada.
--   A 0035 revoga de PUBLIC e devolve o EXECUTE a `authenticated` onde precisa.
-- =============================================================================

-- ---- 0035 (o que efetivamente fecha) ---------------------------------------
-- Funcoes de trigger: nao recebem nada de volta. Gatilho roda com o privilegio
-- do dono da tabela, nao de quem disparou o comando.
revoke execute on function public.fn_audit()                       from public;
revoke execute on function public.fn_etapa_automatica()            from public;
revoke execute on function public.fn_followup_coerente()           from public;
revoke execute on function public.fn_stage_history_entrada()       from public;
revoke execute on function public.fn_stage_history_mudanca()       from public;
revoke execute on function public.fn_deal_terminal_sem_followup()  from public;

-- Auxiliares: fechadas para o anonimo, abertas para quem esta logado.
revoke execute on function public.app_setting_int(text, integer)   from public;
revoke execute on function public.audit_usuario_e_admin()          from public;
revoke execute on function public.current_user_active()            from public;
revoke execute on function public.rel_owner_efetivo(uuid)          from public;

grant execute on function public.app_setting_int(text, integer)    to authenticated;
grant execute on function public.audit_usuario_e_admin()           to authenticated;
grant execute on function public.current_user_active()             to authenticated;
grant execute on function public.rel_owner_efetivo(uuid)           to authenticated;

-- ---- 0034 — profiles: duas policies permissivas viraram uma -----------------
-- Ambas eram avaliadas em TODA consulta a profiles, que e lida no boot e em
-- todo join de dono. A regra foi preservada: ve o proprio perfil, ou e admin,
-- ou tem visao de equipe. Aplicada via DO block que leu as expressoes das
-- policies originais e as uniu com OR, sem reescrever a regra a mao.
-- Resultado em producao:
--   profiles_select_unificada:
--     ((id = (select auth.uid())) or (select is_admin()) or rel_pode_ver_equipe())

notify pgrst, 'reload schema';


-- =============================================================================
-- CONFERENCIA (aplicada, resultado registrado)
-- =============================================================================
-- select p.proname,
--        has_function_privilege('anon', p.oid, 'execute')          as anon_pode,
--        has_function_privilege('authenticated', p.oid, 'execute') as logado_pode
--   from pg_proc p join pg_namespace n on n.oid = p.pronamespace
--  where n.nspname = 'public' and p.proname in (...);
--
-- Resultado: 6 triggers com anon=false e logado=false;
--            4 auxiliares com anon=false e logado=true;
--            processar_descadastro e registrar_evento_tracking seguem abertas.
--
-- Gatilhos conferidos apos o revoke: os 9 triggers de deals e deal_activities
-- seguem habilitados (tgenabled = 'O').


-- =============================================================================
-- ROLLBACK — NAO executar junto.
-- =============================================================================
-- grant execute on function public.fn_audit() to public;
-- grant execute on function public.fn_etapa_automatica() to public;
-- grant execute on function public.fn_followup_coerente() to public;
-- grant execute on function public.fn_stage_history_entrada() to public;
-- grant execute on function public.fn_stage_history_mudanca() to public;
-- grant execute on function public.fn_deal_terminal_sem_followup() to public;
-- grant execute on function public.app_setting_int(text, integer) to public;
-- grant execute on function public.audit_usuario_e_admin() to public;
-- grant execute on function public.current_user_active() to public;
-- grant execute on function public.rel_owner_efetivo(uuid) to public;
--
-- Policies de profiles: recriar as duas originais e remover a unificada.
