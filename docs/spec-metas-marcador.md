# spec-metas-marcador.md — Fase 5

**Pré-requisito:** migration `20260819_0004_metas_timeline.sql` aplicada.
Nenhuma alteração de banco é necessária nesta fase.

Três entregas: marcador de movimentação no card (A), linha do tempo dentro do lead (B),
metas com progresso no painel (C + D).

---

## Regras (as mesmas de sempre)

Edição cirúrgica · zero regressão · iOS Safari (sem arrow, template literal, optional
chaining, `??`) · sem dependência nova · `node --check` · sem `console.log` · você não commita.

---

## A. Marcador de movimentação no card do Kanban

**Não precisa de RPC.** Os dois campos já existem em `deals` e já vêm na consulta atual:

- `updated_at` — qualquer alteração salva no lead
- `stage_changed_at` — última mudança de etapa

> A migration 0004 restaurou `updated_at`, que tinha sido sobrescrito pelo backfill de
> município. Os valores agora são reais. Não recalcular nem inferir de outro campo.

No card, abaixo do nome do responsável, uma linha discreta:

| Situação | Exibir |
|---|---|
| Alterado hoje | `● editado hoje` |
| Alterado há 1–7 dias | `● editado há Nd` |
| Alterado há mais de 7 dias | não exibir |

Ponto colorido: verde até 2 dias, âmbar de 3 a 7. Usar os tokens que já existem.

O marcador de "parado" que já existe no card (`⏱ 55d parado`) continua como está — são
coisas diferentes: um é inatividade na etapa, outro é edição recente. Não misturar.

---

## B. Linha do tempo dentro do lead

Nova seção no modal/painel de edição do lead, abaixo dos campos, recolhida por padrão
("Ver histórico"). Ao expandir, chamar:

```js
db.rpc('lead_timeline', { p_deal_id: dealId })
```

Retorno, já ordenado do mais recente para o mais antigo:

```
quando (timestamptz) | tipo | autor | titulo | detalhe (jsonb)
```

`tipo` assume três valores, cada um com ícone próprio:

| tipo | Ícone | Exemplo de `titulo` | `detalhe` |
|---|---|---|---|
| `atividade` | 💬 | `whatsapp · nao_atendeu` | `{ "nota": "..." }` |
| `etapa` | ➡️ | `Novo lead → Contato feito` | `{ "dias_na_etapa_anterior": 9.0 }` |
| `alteracao` | ✏️ | `Campos alterados` / `Lead criado` | `{ "value": { "de": 0, "para": 5000 } }` |

Para `alteracao`, renderizar cada chave de `detalhe` como `campo: de → para`, com o valor
antigo riscado. Quando `detalhe` vier `{}`, mostrar só o título.

`autor` já vem resolvido — traz "Sistema" quando a operação foi de integração.

**Permissão:** a RPC recusa lead de outro dono para quem não é admin (erro 42501). Trate o
erro com mensagem clara; não é preciso esconder o botão.

---

## C. Tela de definição de metas (admin)

Nova seção em **Administração**, não no painel de relatórios — é configuração, não análise.

Tabela editável: uma linha por vendedor ativo, colunas para cada combinação de indicador e
periodicidade. Salvar por célula:

```js
db.rpc('metas_salvar', {
  p_owner: ownerId,
  p_indicador: 'atividades',      // atividades | trabalhados | movimentacoes | ganhos | valor_ganho
  p_periodicidade: 'diaria',      // diaria | semanal | mensal
  p_valor: 20
})
```

**Valor 0 significa meta desligada** — não aparece no painel do vendedor. É o padrão de
todas as 45 combinações semeadas pela migration. O admin liga só o que vai usar.

Rótulos:

| indicador | Rótulo |
|---|---|
| `atividades` | Contatos registrados |
| `trabalhados` | Leads trabalhados |
| `movimentacoes` | Movimentações de etapa |
| `ganhos` | Leads ganhos |
| `valor_ganho` | Valor ganho (R$) |

Sugestão de layout, para não virar uma grade de 45 campos: um seletor de vendedor no topo
e 5 linhas × 3 colunas abaixo. Só as metas daquele vendedor por vez.

RPC recusa quem não é admin e valor negativo. Tratar os dois erros.

---

## D. Progresso das metas no painel

Novo painel na sub-aba **Visão geral**, acima dos cards de KPI:

```js
db.rpc('metas_progresso', { p_owner: ownerSelecionado })  // null = equipe, para admin
```

Retorno — **só metas com valor maior que zero**:

```
owner_id | vendedor | indicador | periodicidade | meta | realizado | pct
```

Renderizar uma barra por linha:

```
Contatos registrados · hoje        12 / 20        60%   [████████░░░░]
```

Cores: vermelho abaixo de 50%, âmbar de 50 a 89%, verde a partir de 90%.

Agrupar por periodicidade — Hoje · Esta semana · Este mês.

`valor_ganho` formata em BRL. Os demais, número inteiro.

**Se a RPC retornar vazio**, mostrar: "Nenhuma meta definida." — e, para admin, um link para
a seção de metas em Administração. Não exibir barras zeradas.

Este painel **ignora o filtro de período** do topo: metas são sempre relativas a hoje, à
semana corrente e ao mês corrente. Deixar isso claro nos rótulos.

---

## E. Métrica extra (opcional, se couber sem esforço)

`leads_alterados(p_de, p_ate, p_owner)` retorna quantos leads distintos foram alterados por
usuários reais no período — exclui backfill e integrações. Cabe como oitavo card de KPI,
rótulo "Leads alterados".

---

## Checklist de aceite

```
[ ] A — marcador aparece só até 7 dias, não colide com o "Nd parado" existente
[ ] B — linha do tempo abre recolhida, os 3 tipos renderizam com ícone
[ ] B — vendedor abrindo lead de outro dono vê mensagem de erro clara
[ ] C — metas só em Administração, só admin
[ ] C — valor 0 salva e some do painel
[ ] D — painel agrupado por periodicidade, cores por faixa
[ ] D — sem meta definida mostra estado vazio, não barras zeradas
[ ] iOS — sem arrow, template literal, optional chaining, ??
[ ] Todo await em try/catch
[ ] node --check · sem console.log
[ ] Regressão: Kanban, Follow-up, Importação, Dashboard, Relatórios intactos
```
