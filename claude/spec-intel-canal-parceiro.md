# Spec — Motor de Inteligência para parceiros de canal (contabilidade e seguros)

Data: 24/09/2026 · Arquivos: `index.html`, `0043` (aplicada), `0044` (aplicar após o push)

## Problema
Os 2.528 leads marcados por `escard.fn_marcar_parceiros` (`lista_origem` = `PARCEIRO · Contabilidade` / `PARCEIRO · Seguros`)
eram classificados pelo CNAE como **Empregador puro** e recebiam roteiro de venda de cartão para o próprio CNPJ.
Parceiro não compra: indica. O roteiro tem que vender a parceria.

## Decisões
| Questão | Decisão |
|---|---|
| Quem é parceiro | Só o marcador `lista_origem` (fonte única, já roda no cron `escard_marcar_parceiros`) |
| Arquétipos | `Canal contábil` e `Canal seguros` — conversas diferentes (DP/folha × carteira/renovação) |
| Tier | `A` fixo (fit 40), inclusive sem CNPJ enriquecido. Descarte continua Descarte |
| Rota | `Parceria` |
| Genéricos | Para canal, só a abertura herda o genérico (cumprimento e "NUNCA abra assim"). Demais blocos, argumentos, objeção e consultivo: só conteúdo próprio |
| Concorrência | Oculta para canal (parceiro não troca de operadora) |
| Comissão | Script nunca fala percentual nem valor; alerta aponta para a tabela oficial de Parceiro |
| Carteira (Ganho) | Parceiro ativo → foco na primeira indicação, não na carga |

## Ordem de deploy
1. `0043` — conteúdo. **Já aplicada em produção (inerte: nenhum deal tem o arquétipo ainda).**
2. Push do `index.html`.
3. `0044` — ativa no classificador e reclassifica.

## Checklist
- [x] Segurança — nenhuma policy, grant ou assinatura alterada; texto do banco passa por `escapeHtml`
- [x] Arquitetura — um set `INTEL_ARQ_CANAL` decide o comportamento; nenhum outro arquétipo muda
- [x] Backend — 0044 com trocas conferidas (cada trecho ocorre exatamente 1 vez) e abortando se não bater; idempotente
- [x] Frontend — ES5 (sem arrow, template, `?.`, `??`), light mode herdado
- [x] Dados — conteúdo conferido por bloco (abertura 2, cerca 2, descobrir 6, fechar 3, porta 7, recepção 4, por arquétipo)
- [x] DevOps — conteúdo antes, front no meio, ativação por último
- [x] QA — `node --check` nos 4 blocos; 19 testes unitários (canal e não-canal, todos os modos)
- [ ] Teste manual — abrir um lead `PARCEIRO · Contabilidade` e um Empregador comum depois da 0044
