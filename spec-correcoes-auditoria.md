# Especificação — Correções pendentes da auditoria

Projeto: CRM Funil de Vendas (Escard)
Frontend: `index.html` (somente frontend — nenhuma migration)
Data: 28/08/2026

Origem: `claude/auditoria-crm-2026-08-27.md`, itens 16, 12 e o achado do Kanban.

---

## 1. O teto de 100% na conversão do funil — removido

Eu tinha colocado `Math.min(100, ...)` para evitar "180% avançam". Era o
conserto errado: **escondia o sinal em vez de corrigir a conta**.

`entradas(n+1) ÷ entradas(n)` não é conversão entre etapas — são coortes
diferentes, e a etapa seguinte recebe lead que nunca passou pela anterior
(importação direta na etapa, salto de etapa, movimentação manual). Limitado em
100%, o gestor lia *"nada se perde"*. Cru, ele lê que entrou gente por fora.

Agora, acima de 100% o texto muda de tom e de cor:

> ↳ 180% — entrou lead por fora de Contato Feito

com `title` explicando a origem. Abaixo de 100% segue *"N% avançam para X"*.

A conta certa exige coorte sobre `deal_stage_history` — quantos dos que entraram
em A chegaram em B. Fica para quando houver volume que justifique.

---

## 2. Mover card por toque — resolvido

HTML5 Drag & Drop **não dispara por toque** no Safari iOS nem no Chrome Android.
A equipe usa celular: mover um lead exigia abrir a ficha e achar o `select` de
etapa dentro do modal.

Cada card ganha um seletor **"Mover para"**, visível apenas em
`(hover: none), (max-width: 900px)` — celular e tablet. Em desktop o arrastar
continua sendo o caminho e o card fica limpo.

O `<select>` nativo abre o seletor do sistema no celular, que é a melhor
experiência possível ali — nada de popover próprio.

**Detalhe que quebraria tudo:** o card inteiro tem `click` que abre a ficha.
Sem `stopPropagation` no `label` e no `select`, tocar para escolher a etapa
abriria o lead. Está tratado nos dois níveis.

**Ganho de arquitetura:** a movimentação virou `moverDeal(dealId, de, para)`,
usada pelo `drop` e pelo seletor. A regra (gravar `stage_changed_at` junto,
recarregar contagem e as duas colunas) fica escrita uma vez só. Antes ela existia
apenas dentro do handler de `drop`.

Se o `update` falhar, o `select` volta para a etapa de origem — a tela não pode
mostrar um estado que o banco não tem.

---

## 3. O bloco de erro passa a dizer o que aconteceu

*"Não foi possível carregar este bloco"* obrigava abrir o F12 para descobrir se
era sessão expirada, permissão ou função faltando — e as três têm conserto
diferente. Aconteceu hoje: todos os painéis de Relatórios caíram de uma vez e o
diagnóstico levou várias trocas de mensagem.

`estadoErro(alvo, err)` agora imprime a mensagem real abaixo do botão, com
`textContent` (mensagem de erro é dado, não HTML).

E o caso mais comum ganha tradução: erro `42501` ou mensagem contendo
"autenticado" vira **"Sua sessão expirou. Saia e entre de novo."** — que é o
conserto de dez segundos.

---

## 4. O soft-delete de usuário — não existe no código

A auditoria pediu que o fluxo de exclusão gravasse `active = false` junto com
`deleted_at`. **Esse fluxo não existe no `index.html` atual.**

A tela de Administração só troca o papel entre admin e vendedor. Não há botão de
desativar, não há exclusão, e as strings `deleted_at`, `Resetar` e `Desativar`
não aparecem em lugar nenhum do arquivo. O agente que levantou o achado leu uma
cópia desatualizada do repositório e avisou disso no próprio relatório.

Consequência: o furo do `is_admin()` sem `deleted_at` **continua real no banco**
(a coluna existe e as policies a ignoram), mas o risco prático é menor do que a
auditoria pintou — ninguém consegue excluir usuário pela interface. A correção
da 0013 e o passo manual do `is_admin()` seguem valendo como defesa em
profundidade.

---

## Checklist

- [x] **Segurança** — nome de etapa e título do lead escapados no seletor; mensagem de erro por `textContent`, nunca `innerHTML`
- [x] **Arquitetura** — `moverDeal()` vira caminho único das duas vias de movimentação
- [x] **Backend** — nada alterado; nenhuma migration
- [x] **Frontend** — CSS por token, sem inline; `aria-label` no seletor; `(hover:none)` em vez de só largura, para pegar tablet
- [x] **Dados** — falha no `update` reverte o seletor
- [x] **DevOps** — deploy de um arquivo
- [x] **QA** — 12 testes unitários (opções do seletor, etapa selecionada, escape de nome e título, tradução do erro de sessão, erro técnico cru, string, objeto vazio); `node --check` nos 4 blocos; render mobile conferido em captura a 390px
- [ ] **Teste manual** — abrir o Kanban no celular e mover um card pelo seletor; conferir que tocar no seletor NÃO abre a ficha do lead
