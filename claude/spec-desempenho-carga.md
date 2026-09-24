# Desempenho da carga do CRM — diagnóstico e correção (24/09/2026)

## Medição (antes)
Fonte: edge logs das últimas 24 h + pg_stat_statements desde 10/08.

| Requisição | Média | p90 | Máx |
|---|---|---|---|
| icp_indice (7,3 MB por chamada) | 4,3 s | 10,3 s | 48 s |
| followups_contadores | 1,8 s | 3,9 s | 34 s |
| cidades_disponiveis | 1,5 s | 3,7 s | 31 s |
| dashboard_stats | 1,2 s | 3,0 s | 38 s |
| listas_importadas | 1,2 s | 3,1 s | 38 s |
| kanban_contagem | 1,1 s | 2,8 s | 30 s |
| vw_intel_aprendizado | 1,8 s | 4,8 s | 25 s |

Isoladas, com o banco livre, as mesmas consultas levam 20–400 ms. A lentidão vem
de concorrência: o banco (instância pequena, 2 vCPU compartilhadas) recebe ~25
consultas pesadas ao mesmo tempo a cada abertura do app.

## Causa raiz
1. **Boot repetido.** `onAuthStateChange` chamava `loadProfileAndInit()` em todo
   evento com sessão. O supabase-js emite `SIGNED_IN` sempre que a aba volta a
   ficar visível e `TOKEN_REFRESHED` a cada hora. Resultado: 643 boots em 24 h
   para ~6 usuários — cada troca de aba refazia a carga inteira.
2. **Índice ICP gigante.** 26.482 objetos com 10 campos (7,3 MB) por boot, para
   alimentar filtro de produto e legenda que só usam 4 campos. Quando falhava,
   o fallback paginado disparava mais 27 consultas.
3. **RLS avaliada por linha.** 8 policies chamavam função sem `(select …)`;
   em `deal_activities` isso pesa em Follow-up, Kanban e Relatórios.
4. **Cron de parceiros** varrendo os 43 mil deals com regex a cada 10 min.

## Correção
| Onde | O quê | Efeito |
|---|---|---|
| index.html | Boot único por usuário (`bootUsuarioId`) | Volta à aba e renovação de token não recarregam mais nada |
| index.html | Índice ICP compacto + detalhe só do lead aberto | 7,3 MB → 1,4 MB; 528 ms → 187 ms (quente) |
| index.html | Sem paginação de fallback | Falha do índice não gera mais 27 consultas |
| index.html | Motor de inteligência carrega 2,5 s depois | Funil e Dashboard não disputam o banco na abertura |
| 0057 | 8 policies com `(select …)` | Função avaliada 1× por consulta |
| 0057 | `icp_indice_compacto()` | Nova RPC; a antiga continua para abas antigas |
| 0057 | Cron de parceiros de hora em hora | Menos varredura durante o expediente |

## Crivo
- Segurança: RLS com a mesma regra, só mudou a forma de avaliar; nova RPC é invoker (RLS da view vale).
- Dados: nenhuma consulta muda resultado; máscara reproduz `icpProdutosDe()`.
- Frontend: ES5 no código novo; `node --check` nos 4 blocos; CRLF preservado.
- DevOps: 0057 aplicada em produção; rollback no fim do arquivo.
- QA: medir de novo em 24 h (edge logs) — meta: boots/dia ≈ nº de aberturas reais, p90 do Funil < 1 s.
