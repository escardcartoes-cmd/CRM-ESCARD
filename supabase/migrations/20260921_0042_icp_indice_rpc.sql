-- 0042 — Priorização ICP numa chamada só
-- APLICADA EM PRODUÇÃO em 21/09/2026 via MCP. Documentação + rollback.
-- O front paginava vw_sdr_priorizacao_escard em blocos de 1000, em fila
-- (~12 idas × ~350 ms ≈ 4 s travando a abertura). A RPC devolve o índice num JSON
-- só (~200 ms), com o mesmo filtro da view (dono ou admin). security invoker.
create or replace function public.icp_indice()
returns jsonb language sql stable security invoker
set search_path to 'public', 'pg_temp'
as $function$
  select coalesce(jsonb_agg(jsonb_build_object(
           'deal_id', v.deal_id, 'tier', v.tier, 'prioridade', v.prioridade,
           'produto_entrada', v.produto_entrada, 'produto_roadmap', v.produto_roadmap,
           'afinidade_private', v.afinidade_private, 'motivo_afinidade', v.motivo_afinidade,
           'score', v.score, 'rota', v.rota, 'municipio', v.municipio)), '[]'::jsonb)
    from public.vw_sdr_priorizacao_escard v;
$function$;
revoke all on function public.icp_indice() from public, anon;
grant execute on function public.icp_indice() to authenticated;

-- ROLLBACK (rodar separado; o front volta sozinho para a paginação antiga):
-- drop function if exists public.icp_indice();
