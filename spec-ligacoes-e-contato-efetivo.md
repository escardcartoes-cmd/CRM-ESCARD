# Especificação — Volume de ligação e contato efetivo

Projeto: CRM Funil de Vendas (Escard)
Migration: `supabase/migrations/20260828_0011_ligacoes_e_contato_efetivo.sql`
**Status:** aplicada em produção em 28/08/2026.

---

## O diagnóstico

O pedido foi: "o SDR liga, marca *Não atendeu*, e isso tem que constar".

**A tentativa sempre constou.** O registro grava `channel='telefone'`,
`outcome='nao_atendeu'`, e não existe nenhum ponto no código que a exclua. Ela
entra na meta `ligacoes`, no total de atividades, no gráfico por canal, no
gráfico por desfecho, na série diária, em "leads trabalhados", na cobertura da
carteira e na timeline do lead. O único lugar que a exclui é a linha "efetivas",
que por definição é "o cliente atendeu ou respondeu".

Os números do mês, lidos direto do banco, confirmam:

| Indicador | Agosto/2026 |
|---|---|
| Ligações | **539** |
| Atendidas | **97** |
| Taxa de atendimento | **18,0%** |
| `nao_atendeu` registrados | **111** |
| Leads trabalhados | **1.108** |
| Leads alcançados (contato efetivo) | **122** |
| Carteira | 13.565 |
| Cobertura (qualquer toque) | 3,9% |
| Alcance (contato efetivo) | 0,6% |

O problema era outro, e são três:

1. **O relatório não mostrava volume de ligação como número em lugar nenhum.**
   Para saber quantas ligações a equipe fez era preciso ler uma barra de gráfico.
2. **"Leads trabalhados" trata tentativa e conversa como a mesma coisa.**
   1.108 trabalhados contra 122 alcançados — a distância entre discar e falar
   era invisível.
3. **No Follow-up, ligar e não ser atendido zerava o "dias parado"** e tirava o
   lead da fila. O SDR perdia de vista justamente o lead com quem não conseguiu
   falar.

---

## Contato efetivo

Daqui em diante, **contato efetivo** é `outcome in ('atendeu','respondeu','realizada')`:
alguém do outro lado apareceu.

Tentativa continua sendo trabalho e continua contando em `trabalhados`. Ela só
não vale mais como **alcance**.

---

## 1. Relatórios — dois KPIs novos

| Card | O que mostra |
|---|---|
| **Ligações** | Tentativas no período · quantas foram atendidas · taxa de atendimento |
| **Leads alcançados** | Leads distintos com contato efetivo · % da carteira (vermelho abaixo de 50%, verde acima de 70%) |

"Leads trabalhados" **não muda de conta** — muda de rótulo: o rodapé passa a
dizer *"qualquer toque — inclui tentativa sem resposta"*. Os dois números vivem
lado a lado, que foi a decisão tomada: `trabalhados` mede esforço, `alcançados`
mede alcance. Trocar um pelo outro esconderia metade da operação.

Chaves novas em `rel_metricas`: `ligacoes`, `ligacoes_atendidas`,
`ligacoes_taxa_pct`, `alcancados`, `alcance_pct`. Nada foi removido — frontend
antigo não quebra.

---

## 2. Follow-up — "dias parado" vira "dias sem contato"

`followups_list` e `followups_contadores` passam a calcular `dias_parado` sobre
o **último contato efetivo**, não sobre a última atividade.

Efeito prático: telefone tocando no vazio não tira mais o lead da esteira. Ele
continua aparecendo no "7+ dias sem contato" até alguém realmente falar com ele.

`ultima_atividade` e `total_atividades` **não mudam**: continuam contando toda
tentativa. É o que mostra o esforço na linha do lead. Uma linha pode legitimamente
dizer *"12d sem contato · 6 atividades"* — seis tentativas, nenhuma conversa. É
exatamente a informação que faltava.

Na interface o selo passa a dizer **"12d sem contato"** (com tooltip explicando)
e o seletor vira **"7+ dias sem contato"**.

### O que NÃO mudou de propósito

`dormentes`, no relatório, continua sendo *"sem nenhuma atividade há N dias"*.
Mudar o critério junto inflaria a contagem de dormentes de um dia para o outro
sem que nada tivesse acontecido na operação. Se fizer sentido depois, é uma
linha — mas é decisão separada, tomada olhando o número.

---

## 3. Deploy

Nenhuma RPC mudou de assinatura — as três são `create or replace` puro, sem
`drop`, sem risco de sobrecarga.

Ordem: migration (**já aplicada**) → push do `index.html`.

Rollback: reexecutar `20260827_0009` (rel_metricas) e `20260827_0010`
(followups). Como nenhuma assinatura mudou, é replace direto.

---

## 4. Checklist

- [x] **Segurança** — nenhuma policy nova; `followups_*` seguem sem `security definer`,
      rodando com a RLS de quem chamou; nenhum segredo novo
- [x] **Arquitetura** — single-file preservado; nenhuma dependência nova
- [x] **Backend** — `create or replace` sem drop; `rel_metricas` só ganha chaves
- [x] **Frontend** — rótulos revistos para não mentir; `title` no selo; light mode
- [x] **Dados** — migration versionada; conferido contra os números reais de agosto
- [x] **DevOps** — migration antes do frontend; rollback é reexecutar 0009 e 0010
- [x] **QA** — `node --check` nos 4 blocos; SQL validado pelo parser do Postgres
      (statements externos e os três corpos); CRLF preservado; sem `console.log`
- [ ] **Teste manual** — registrar uma ligação "Não atendeu" num lead e conferir
      que ele **continua** na fila do Follow-up, que o contador de dias não zerou,
      e que o KPI "Ligações" subiu
