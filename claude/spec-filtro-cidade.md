# Especificação — Filtro por cidade no Funil e no Follow-up

Projeto: CRM Funil de Vendas (Escard)
Migration: `supabase/migrations/20260910_0026_filtro_cidade.sql`
Frontend: `index.html`
Data: 10/09/2026

**Status:** migration **aplicada em produção em 10/09/2026** via MCP
(`apply_migration`, nome `filtro_cidade_0026`). Assinaturas conferidas: cada
uma das cinco funções aparece **uma vez só** no catálogo, ACL igual à anterior
(`authenticated` + `service_role`, nada para `anon`). Frontend entregue,
**falta commit + push** para `main` (Cloudflare Pages publica sozinho).

---

## 1. Diagnóstico

Não havia filtro por cidade em nenhuma tela. A busca texto também não alcança
cidade: `kanban_cards`/`kanban_contagem` procuram em `title`, `contact_name`,
`contact_email`, `contact_phone`; `followups_list` em `title`, `contact_name`,
`cnpj`. Digitar "Linhares" na busca não retornava nada.

O dado já estava pronto: `deals.city` preenchido em **17.864 dos 18.508 leads
abertos** (96,5%), **871 cidades distintas**, zero variantes de caixa/espaço
(a 0022 limpou o mojibake e o importador normaliza via `normalizarMunicipio`),
índice `idx_deals_city` existente.

Ou seja: filtro faltando, não dado faltando.

---

## 2. Decisões

### Mesmo desenho do filtro por lista (migration 0010)

As quatro RPCs ganham **um** parâmetro, `p_cidade text default null`. Com o
default, o comportamento é byte a byte o de antes — um frontend antigo continua
funcionando sem alteração.

O frontend só envia `p_cidade` **quando há filtro ativo** (`paramsCidade()`).
Deploy tolerante à ordem: se o banco for revertido, o sistema inteiro continua
funcionando e só quem mexer no campo recebe erro.

### Igualdade exata, não `ilike`

`d.city = p_cidade`. A coluna é normalizada e indexada; `ilike '%x%'` jogaria
fora o índice e ainda misturaria "Serra" com "Serra Talhada". A resolução de
grafia acontece no cliente (seção 3).

### Predicado no `ON` do left join em `kanban_contagem`

No `WHERE` ele mataria as etapas sem nenhum lead da cidade e a coluna sumiria
do Kanban. No `ON`, a coluna aparece zerada. Conferido em produção: com
`p_cidade = 'Linhares'` as 7 etapas continuam no retorno, 3 delas com 0,
total 598 — igual ao `count(*)` direto em `deals`.

### DROP + CREATE, e a ACL refeita

`CREATE OR REPLACE` com um parâmetro a mais cria **sobrecarga** — o PostgREST
devolve `PGRST203` e o Kanban para. Dropar e recriar na mesma transação é
atômico. Como `DROP` zera os grants, a migration os refaz explicitamente.

### `cidades_disponiveis()` sem `security definer`

Roda com a RLS de quem chamou: o vendedor só enxerga as cidades em que **ele**
tem lead, igual a `listas_importadas()`. Retorna `(cidade, total)` ordenado por
volume — a ordem do datalist.

### Empresas / Pessoas ficam de fora

`city` é atributo de `deals`. Filtrar em Empresas exigiria join ou coluna
espelhada, e os leads gerados a partir de uma empresa já são o filtro do funil.

---

## 3. Frontend

### Campo, não `<select>`

871 opções num `<select>` puro é inutilizável no celular. Cada barra (Funil e
Follow-up) ganha um `<input type="search" list="cidades-datalist">` — o usuário
digita e o navegador filtra. Um único `<datalist>` alimenta os dois campos.
Escondidos enquanto não houver cidade nenhuma — mesmo critério dos filtros de
lista e ICP.

O datalist é montado **por propriedade** (`opt.value = nome`), nunca por
interpolação em HTML.

### Resolução de grafia (`resolverCidade`)

O banco exige a grafia exata. Quem digita sem escolher no datalist ganha a
canônica, nesta ordem:

| Digitado | Resolve para | Regra |
|---|---|---|
| `vitoria`, `  VITÓRIA ` | `Vitória` | igualdade sem caixa e sem acento |
| `cachoeiro` | `Cachoeiro de Itapemirim` | prefixo **único** |
| `sao` | `sao` (vai como está) | prefixo ambíguo (São Mateus, São Gabriel…) |
| `Xyz` | `Xyz` (vai como está) | sem correspondência |
| vazio | `null` (filtro desligado) | — |

Sem correspondência o resultado vazio é honesto, e um toast avisa
*"Nenhum lead na cidade X"*. O campo é reescrito com a grafia que o banco vai
receber. Nove casos validados em Node antes da entrega.

### Eventos

`change` aplica o filtro (escolha no datalist, Enter, blur). O botão nativo de
limpar do `type="search"` — e apagar tudo — dispara `input` com valor vazio
sem `change`: esse caso zera o filtro na hora. Trocar o filtro zera
`kanbanCards`: a profundidade de "Carregar mais" não sobrevive à troca de
recorte, igual ao filtro de lista.

### Onde entra no ciclo

- Boot: `carregarCidades()` sem `await` — só alimenta o datalist, não bloqueia
  o primeiro render e trata o próprio erro (a auditoria já apontou as chamadas
  em série antes da tela útil; esta não entra na fila).
- Após importação: `carregarCidades()` — cidade nova entra no datalist.
- A ficha do lead não edita cidade, então salvar lead não recarrega.

### O que NÃO mudou

Busca texto, filtro de vendedor, filtro de lista, chips ICP, ordenação,
paginação, retorno das RPCs, Relatórios. O bloco de Relatórios (ES5) não foi
tocado. SheetJS idêntico byte a byte.

---

## 4. Ordem de deploy

1. ~~Migration 0026 no Supabase~~ — **feito em 10/09 via MCP**
2. Commit de `index.html` + `supabase/migrations/20260910_0026_filtro_cidade.sql`
   + `claude/spec-filtro-cidade.md` → push em `main` → Cloudflare Pages
3. Validar em janela anônima com cache-buster (`?v=` aleatório):
   Kanban carrega, Follow-up carrega, campo "Cidade" aparece nas duas barras

**Rollback do frontend:** commit anterior. **Rollback do banco:** seção
comentada no fim da migration (dropar as assinaturas novas **antes** de
reexecutar a 0010, senão sobrecarga).

---

## 5. Checklist

- [x] **Segurança** — nenhuma RPC `security definer`; RLS do chamador; ACL
      refeita igual (sem `anon`); datalist por propriedade; `maxlength=120`;
      igualdade exata (sem `ilike` com entrada do usuário); nenhum segredo
- [x] **Arquitetura** — single-file preservado; padrão da 0010 replicado;
      parâmetro só enviado quando ativo (deploy tolerante)
- [x] **Backend** — DROP + CREATE atômico; predicado no `ON` em
      `kanban_contagem`; `carregarCidades` com erro tratado e falha silenciosa
- [x] **Frontend** — `aria-label` nos dois campos; light mode; CSS
      `appearance:textfield` para o Safari não desenhar o campo de busca
      arredondado fora do padrão dos outros inputs
- [x] **Dados** — índice `idx_deals_city` já existente; coluna normalizada;
      migration versionada com conferência e rollback separados
- [x] **DevOps** — migration antes do frontend (já aplicada); um arquivo a
      publicar; rollback documentado
- [x] **QA** — `node --check` nos 4 blocos `<script>` (extraídos sem mascarar
      comentários — SheetJS passa); CRLF preservado (6.588 linhas, zero LF
      solto); nenhum `console.log`; `resolverCidade` com 9 casos em Node;
      contagem de `kanban_contagem` conferida em produção (598 = 598, 7 etapas)
- [ ] **Teste manual** — Funil: digitar "linhares" → cabeçalhos das colunas
      mudam, colunas vazias continuam aparecendo com 0, "Carregar mais"
      respeita a cidade. Follow-up: cards e etapas recontam. Limpar o campo
      volta ao total. Celular: datalist abre ao digitar.

### Fora do escopo, anotado

- Filtro por cidade em **Relatórios** (o gráfico "Top municípios" existe, mas
  os KPIs não recortam por cidade) — exigiria `p_cidade` em `rel_metricas` e
  nos invólucros; pedido separado.
- **UF / região / rota**: a view de priorização ICP já expõe `rota` e
  `municipio` por lead; um filtro por rota de visita seria o próximo passo
  natural para a equipe de campo.
