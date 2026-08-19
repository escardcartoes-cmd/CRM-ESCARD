# spec-relatorios.md — Aba Relatórios (Fase 4)

**Status das fases anteriores:** 0001, 0002 e 0003 aplicadas no banco. Esta spec cobre
somente a camada de interface no `index.html`. Nenhuma alteração de banco é necessária.

---

## 1. Regras inegociáveis

1. **Edição cirúrgica.** Nunca reescrever `index.html` inteiro. Inserir blocos novos e
   tocar o mínimo no que existe.
2. **Zero regressão.** Nenhuma função, listener ou variável existente pode ser renomeada,
   movida ou removida. A aba é aditiva.
3. **iOS Safari.** Sem arrow function, sem template literal, sem optional chaining, sem `??`.
   Usar `function`, concatenação com `+`, `&&`/`||`.
4. **Sem dependência nova.** Gráficos em SVG gerado por JS. Não adicionar Chart.js nem
   qualquer CDN. O mockup em `docs/mockup-dashboard-produtividade.html` já traz as funções
   de desenho prontas — reaproveitar, não reinventar.
5. **Light mode.** Reutilizar os tokens CSS que já existem no arquivo. Não criar paleta nova.
6. **`node --check`** no bloco de script antes de qualquer commit.
7. **Sem `console.log`** na versão final.

---

## 2. Referência visual

`docs/mockup-dashboard-produtividade.html` — layout, hierarquia, cores, comportamento das
abas e das barras. É referência de **aparência e estrutura**, não de dados: o mockup usa
dados fictícios, a implementação consome as RPCs.

---

## 3. Contratos das RPCs

Todas já existem no banco. Chamar via `supabase.rpc(nome, params)`.
Todas aplicam permissão no servidor — **não filtrar por vendedor no front**.

### 3.1 `relatorio_produtividade(p_de date, p_ate date, p_owner uuid)`

Retorna um único objeto JSON:

```json
{
  "periodo": { "de": "2026-07-20", "ate": "2026-08-19", "dias": 31 },
  "carteira": 57,
  "trabalhados": 32,
  "trabalhados_carteira": 30,
  "cobertura_pct": 52.6,
  "primeiro_contato_h": 207.5,
  "leads_criados": 61,
  "followup_em_dia_pct": 33.3,
  "dormentes": 11,
  "dormentes_dias": 14,
  "ganhos": 3,
  "perdidos": 2,
  "conversao_pct": 60.0,
  "valor_ganho": 3222,
  "ciclo_medio_dias": 2.0,
  "atividades": 64,
  "atividades_efetivas": 32,
  "taxa_efetiva_pct": 50.0,
  "contatos_invalidos": 0,
  "por_canal":     { "telefone": 108, "whatsapp": 83, "email": 35 },
  "por_desfecho":  { "atendeu": 15, "nao_atendeu": 61 },
  "motivos_perda": { "Sem interesse": 12, "(não preenchido)": 4 },
  "top_municipios": [ { "city": "Vitória", "leads": 539 } ]
}
```

`primeiro_contato_h` e `ciclo_medio_dias` podem vir `null` quando não há amostra.
Tratar como "—", nunca como zero.

`p_owner` é ignorado para quem não é admin. Enviar assim mesmo.

### 3.2 `serie_atividades(p_de date, p_ate date, p_owner uuid)`

Uma linha por dia, incluindo dias sem atividade:

```
dia (date) | total (int) | efetivas (int)
```

### 3.3 `funil_periodo(p_de date, p_ate date, p_owner uuid)`

Uma linha por etapa, na ordem de `order_index`:

```
stage_id | etapa | order_index | is_won | is_lost | leads_agora | entradas | saidas | dias_medio
```

- `leads_agora` — quantos estão na etapa **neste momento**
- `entradas` / `saidas` — movimentação **no período**
- `dias_medio` — média de permanência antes de sair; `null` quando não houve saída

Conversão etapa a etapa: `entradas` da etapa seguinte ÷ `entradas` da etapa atual,
apenas entre etapas com `is_won = false` e `is_lost = false`.

### 3.4 `ranking_equipe(p_de date, p_ate date)`

```
owner_id | nome | e_voce | trabalhados | cobertura | conversao | valor_ganho
```

Para vendedor com `ranking_aberto_vendedor = false` (padrão), retorna exatamente duas
linhas: a dele (`e_voce = true`) e uma com `owner_id = null` e nome "Média da equipe".
**O front não precisa tratar isso** — apenas renderizar o que vier.

### 3.5 `auditoria_consulta(p_de, p_ate, p_tabela, p_actor, p_limit, p_offset)`

Admin apenas. Erro 42501 para os demais.

```
id | created_at | autor | tabela | acao | rotulo | campos (jsonb) | txid | no_lote
```

- `campos` — `{ "value": { "de": 18000, "para": 12400 } }`
- `no_lote` — quantos registros compartilham o mesmo `txid`. Quando `> 1`, exibir a
  primeira linha do lote com a marcação "lote de N registros" e ocultar as demais.
- `autor` — já resolvido pelo servidor; vem "Sistema" para integrações.

### 3.6 `registrar_evento(p_event_type, p_entidade, p_entidade_id, p_metadata)`

Chamar em: `login`, `export`, `import`, `bulk_transfer`.
Tipos aceitos: `login`, `logout`, `page_view`, `search`, `export`, `import`,
`deal_open`, `bulk_transfer`, `password_reset`. Outro valor gera erro.

Registrar exportação é **exigência de LGPD** — não é opcional.

---

## 4. Interface

### 4.1 Ponto de entrada

Novo item na navegação principal, ao lado das abas existentes:

- Admin: **"Relatórios"**
- Vendedor: **"Meu desempenho"**

Usar o mesmo mecanismo de troca de aba que o CRM já usa. Não criar roteador novo.

### 4.2 Filtros (topo, fixos para toda a aba)

| Filtro | Opções | Visível para |
|---|---|---|
| Período | 7 / 30 / 90 dias + intervalo personalizado | todos |
| Vendedor | Toda a equipe + lista de ativos | **admin apenas** |

Um botão "Aplicar" dispara as chamadas. Não recarregar a cada mudança de select.

### 4.3 Sub-abas

| Sub-aba | Conteúdo | Vendedor |
|---|---|---|
| Visão geral | 7 cards de KPI, série diária, painel "Precisa de atenção" | ✅ |
| Produtividade | Ranking, atividades por canal, por desfecho, municípios | ✅ |
| Funil | Funil por etapa com conversão, motivos de perda, tempo por etapa | ✅ |
| Auditoria | Trilha de alterações paginada | ❌ ocultar |
| Acessos | Uso do sistema por pessoa | ❌ ocultar |

Ocultar significa **não renderizar o botão**. A RPC já barra no servidor; o front só
evita mostrar um caminho que vai dar erro.

### 4.4 Os 7 cards da Visão geral

1. Leads trabalhados — `trabalhados`, rodapé "de {carteira} na carteira"
2. Cobertura da carteira — `cobertura_pct` + "%"
3. Tempo até 1º contato — `primeiro_contato_h` + "h"
4. Follow-ups em dia — `followup_em_dia_pct` + "%"
5. Leads dormentes — `dormentes`, rodapé "sem atividade há mais de {dormentes_dias} dias"
6. Taxa de conversão — `conversao_pct` + "%"
7. Valor ganho — `valor_ganho` em BRL

### 4.5 Gráficos

- **Série diária** — linha com área, SVG. Função `desenharLinha` do mockup.
- **Distribuições** (canal, desfecho, município, motivo de perda) — barras horizontais.
  Função `desenharBarras` do mockup.
- **Funil** — barras proporcionais com a conversão entre etapas abaixo de cada uma.

Sinalização por cor, como no mockup: cobertura abaixo de 50% em vermelho, acima de 70%
em verde; tempo de 1º contato acima de 12h em vermelho, abaixo de 6h em verde.

### 4.6 Estados

- **Carregando** — esqueleto ou spinner por painel, nunca a tela toda travada.
- **Vazio** — "Nenhuma atividade registrada neste período." Nunca zeros mudos.
- **Erro** — mensagem clara com botão "Tentar novamente". Todo `await` em `try/catch`.

---

## 5. Exportação (admin)

Botão "Exportar XLSX" gerando uma planilha com uma aba por bloco: KPIs, ranking, funil,
série diária.

Antes do download, chamar obrigatoriamente:

```js
await supabase.rpc('registrar_evento', {
  p_event_type: 'export',
  p_entidade: 'relatorio',
  p_metadata: { formato: 'xlsx', de: dataDe, ate: dataAte }
});
```

Se o CRM já carrega SheetJS, reutilizar. Se não carregar, gerar CSV — **não adicionar
biblioteca nova**.

---

## 6. Checklist de aceite

```
[ ] Segurança  — nenhum filtro de permissão no front; RPC decide
[ ] Segurança  — exportação registra evento antes do download
[ ] Frontend   — semântico, aria em filtros e abas, light mode, foco visível
[ ] Frontend   — testado em 320px de largura
[ ] iOS        — sem arrow function, template literal, optional chaining ou ??
[ ] Backend    — todo await em try/catch, erro exibido ao usuário
[ ] QA         — cards conferidos contra o retorno cru da RPC no SQL Editor
[ ] QA         — perfil vendedor não vê Auditoria, Acessos nem filtro de vendedor
[ ] QA         — período sem dados mostra estado vazio, não zeros
[ ] QA         — sem console.log
[ ] Regressão  — Kanban, Follow-up, Importação e Dashboard intactos
[ ] node --check no bloco de script
```

---

## 7. Observação de contexto

A base tem cerca de 3.010 leads e 228 atividades registradas. Nas primeiras semanas os
indicadores de cobertura vão aparecer próximos de zero. **Isso é o retrato correto da
operação, não um bug do painel.** Não "ajustar" cálculo, não inventar mínimo, não
esconder número baixo. O painel existe justamente para tornar isso visível.
