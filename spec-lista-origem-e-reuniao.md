# Especificação — Etapa "Reunião", lista de origem e no-show contabilizado

Projeto: CRM Funil de Vendas (Escard)
Migrations: `supabase/migrations/20260827_0009_lista_origem_e_reuniao.sql`
· `supabase/migrations/20260827_0010_filtro_lista.sql`
Frontend: `index.html` (+188 linhas, −19)

**Status:** migrations 0009 e 0010 **aplicadas em produção em 27/08/2026**,
pelo SQL Editor do dashboard. Conferência da 0010 confirmada: as quatro RPCs
aparecem uma única vez cada, com `p_lista text, p_sem_lista boolean` no fim da
assinatura. Falta apenas o deploy do `index.html`.

---

## Decisões tomadas

| Questão | Decisão |
|---|---|
| Nome da etapa | `Qualificação` → `Reunião`, direto em `pipeline_stages` |
| Onde o no-show é contado | Card no Dashboard + KPI de comparecimento no Relatório |
| Meta `reunioes` existente | **Não alterada** — continua contando só `realizada` |
| Meta nova | `reunioes_nao_realizadas`, de teto, nasce em 0 (inerte até ser definida) |
| Onde mora o nome da lista | `deals.lista_origem` — atributo do lead, não da importação |
| Leads antigos | Ficam sem lista; o campo é editável na ficha para preenchimento manual |
| Filtro por lista | Server-side, no Funil e no Follow-up, com opção "Sem lista" |
| Rótulo do canal e-mail | `Bounce` → `Enviado` (só o rótulo; o valor gravado continua `bounce`) |

---

## 1. Etapa "Reunião"

O nome da etapa é dado, não código. Nada em `index.html` compara com a string
`'Qualificação'` — a única etapa referenciada por nome no frontend é `Prospecção`,
em `etapaProspeccao()`, que não é tocada.

```sql
update public.pipeline_stages set name = 'Reunião' where name = 'Qualificação';
```

Idempotente. Rollback é a mesma linha ao contrário. O histórico em
`deal_stage_history` guarda `stage_id`, não o nome — nenhum relatório histórico
se desloca.

---

## 2. Reunião que não aconteceu

### Por que a meta `reunioes` não muda

Somar no-show na meta `reunioes` reescreveria para cima o atingimento já
registrado deste mês, sem que ninguém tivesse feito nada diferente. Pior: apagaria
a distinção entre reunião que gerou conversa e reunião que o cliente furou —
exatamente o que se quer enxergar.

O no-show passa a ser contado **ao lado**, em três lugares:

| Onde | O que mostra |
|---|---|
| Dashboard — card `🚫 Reuniões não realizadas` | Quantas no mês, com a taxa de comparecimento no subtítulo |
| Dashboard — painel "Próximas reuniões" | Subtítulo passa a somar realizadas · não compareceu · canceladas |
| Relatórios → Visão geral | KPI "Reuniões realizadas" e KPI "Comparecimento" (vermelho abaixo de 60%, verde a partir de 80%) |

### A conta

```
comparecimento = realizadas ÷ (realizadas + não compareceu)
```

**Cancelada fica fora do denominador.** Reunião desmarcada com antecedência não é
falha de comparecimento — é reagendamento. Contá-la pune o vendedor pelo cliente
que avisou, e a taxa deixa de medir o que se quer medir. Cancelada aparece
separada, como contagem.

`rel_metricas` passa a devolver quatro chaves novas: `reunioes_agendadas`,
`reunioes_realizadas`, `reunioes_nao_realizadas`, `reunioes_canceladas` e
`reunioes_taxa_pct`. Nada é removido do retorno — se o `index.html` subir antes
da migration, os KPIs novos mostram `—` e o resto do relatório continua igual.

Linhas antigas de `presencial`, gravadas antes da migration 0008 e sem
`meeting_status`, têm a situação derivada do `outcome`. Nada do histórico se perde.

### A meta de teto — leia antes de definir um valor

`reunioes_nao_realizadas` entra como indicador de meta porque foi pedido, e nasce
em **0** para todos: `metas_progresso` só devolve linha com `valor > 0`, então
enquanto ninguém definir um teto, nenhuma tela muda.

O aviso: é uma meta que **sobe quando o desempenho piora**. A barra de progresso
do painel é a mesma dos outros indicadores — vai ficar verde quando o vendedor
tiver muito no-show. O número honesto para acompanhar é a `reunioes_taxa_pct`
do relatório, que já vem pronta.

---

## 3. Lista de origem

### Modelagem

`deals.lista_origem text` — nullable, com `check` de 1 a 120 caracteres e índice
parcial (`where lista_origem is not null`).

O campo é do **lead**, não da importação. Uma tabela `import_batches` com FK
resolveria o mesmo problema com mais peças e impediria o caso que vai acontecer:
lead classificado à mão depois, ou movido de uma lista para outra. Texto no lead,
com a lista de valores vinda de um `group by`, resolve os dois.

### RPC do seletor

```sql
create or replace function public.listas_importadas()
returns table (lista text, total bigint)
language sql stable
```

**Não é `security definer`, de propósito.** Roda com a RLS de quem chamou: o
vendedor só enxerga listas em que ele tem lead. Uma função `security definer`
aqui vazaria a existência de todas as listas da equipe para qualquer vendedor.

### Importador

- Campo **Nome da lista** no modal, logo abaixo da etapa
- Pré-preenchido com o nome do arquivo sem a extensão — só sugestão, o que o
  usuário digitar manda
- **Obrigatório.** Importar 4.700 linhas sem nome de lista é jogar a lista na base:
  no dia seguinte não há como separá-la de nada
- Vai junto no `registrar_evento('import')`, em `metadata.lista`

### Ficha do lead

Campo **Lista de origem**, entre "Etapa" e "Próximo contato", com `datalist` das
listas existentes — autocompleta o que já existe e aceita nome novo. Editável:
é por aqui que os leads antigos ganham lista, sem SQL.

O `datalist` é montado por propriedade (`opt.value = nome`), nunca por
interpolação em HTML.

---

## 4. Ordem de deploy

1. Migration no dashboard do Supabase
   `https://supabase.com/dashboard/project/heevguvboffziehftucp/sql/new`
2. Conferência:
   ```sql
   select name, order_index from public.pipeline_stages order by order_index;
   select * from public.listas_importadas();
   select public.rel_metricas(date_trunc('month', current_date)::date, current_date) -> 'reunioes_taxa_pct';
   ```
3. Push do `index.html` → Cloudflare Pages
4. Validar em janela anônima

O frontend **tolera** a ordem inversa em tudo menos a importação: os KPIs de
reunião mostram `—`, o datalist fica vazio, o campo da ficha aceita texto e falha
ao salvar. A importação quebra de verdade (`lista_origem` não existe), então a
migration vem primeiro.

---

## 5. Checklist

- [x] **Segurança** — `listas_importadas` sem `security definer` (RLS do chamador);
      `datalist` montado por propriedade, sem HTML interpolado; entrada limitada a
      120 caracteres no cliente e por `check` no banco; nenhum segredo novo
- [x] **Arquitetura** — single-file preservado; nenhuma dependência nova; nenhuma
      RPC existente muda de assinatura
- [x] **Backend** — `carregarListas` com erro tratado e falha silenciosa por decisão;
      `rel_metricas` só ganha chaves, não perde nenhuma
- [x] **Frontend** — `label for` em todos os campos novos; light mode; classe
      `.field-ajuda` em `:root` tokens; sem estilo inline novo
- [x] **Dados** — coluna nullable, `check` de tamanho, índice parcial, migration versionada
- [x] **DevOps** — migration antes do frontend; rollback é `drop column` + reexecutar 0005 e 0825_0007
- [x] **QA** — `node --check` nos 4 blocos `<script>`; SQL validado com parser do Postgres
      (statements externos e as duas queries internas); IDs novos cruzados
      (`import-lista`, `deal-lista`, `listas-datalist`); CRLF preservado; sem `console.log`
- [ ] **Teste manual** — importar uma planilha pequena com nome de lista, conferir
      na ficha, editar a lista pela ficha, registrar uma reunião como "não compareceu"
      e conferir o card e o KPI

---

## 6. Filtro por lista — Funil e Follow-up

Migration `20260827_0010_filtro_lista.sql`.

As quatro RPCs envolvidas ganham dois parâmetros, ambos com default:

| Parâmetro | Efeito |
|---|---|
| `p_lista text default null` | filtra por uma lista específica |
| `p_sem_lista boolean default false` | só os leads **sem** lista — é por aqui que o backfill manual acha o que falta |

Com os dois no default o comportamento é idêntico ao de hoje.

### Por que DROP + CREATE e não CREATE OR REPLACE

No Postgres a função é identificada por **nome + tipos dos argumentos**. Um
`create or replace` com um parâmetro a mais não substitui: cria uma **sobrecarga**.
Com duas candidatas, o PostgREST devolve `PGRST203` (ambíguo) e o Kanban para de
carregar. Dropar e recriar na **mesma transação** é atômico — chamadas
concorrentes esperam o lock, nenhuma vê a função ausente.

Os corpos vieram de `pg_get_functiondef` no banco vivo, reindentados, com **uma
linha nova de predicado em cada**. Busca, ordenação, paginação e retorno
intactos. Nenhuma das quatro é `security definer` — continua rodando com a RLS
de quem chamou.

Em `kanban_contagem` o predicado entra no `ON` do left join, não no `WHERE`: no
`WHERE` ele mataria as etapas sem nenhum lead da lista, e a coluna sumiria do
Kanban em vez de aparecer zerada.

### Frontend

Um `<select>` na barra do Funil e outro na do Follow-up: **Todas as listas** ·
cada lista · **Sem lista**. Escondidos enquanto não existir nenhuma lista —
mesmo critério do filtro ICP.

Os parâmetros só são enviados **quando há filtro ativo** (`paramsLista()`). Sem
filtro, a chamada é byte a byte a de hoje: se a migration 0010 não tiver rodado,
o sistema inteiro continua funcionando e só quem mexer no seletor recebe erro.
Isso torna a ordem de deploy tolerante — o que não valeria se o frontend
mandasse os parâmetros sempre.

Trocar o filtro zera `kanbanCards`: a profundidade de "Carregar mais" de cada
coluna não faz sentido depois de mudar o recorte.

O seletor é montado por propriedade (`option.value = nome`), nunca por
interpolação em HTML.

### Empresas / Pessoas

`lista_origem` é atributo de `deals`. As tabelas `companies` e `contacts` não
passam pela importação de listas — nenhum registro delas tem lista de origem,
então um filtro ali filtraria um campo sempre vazio. Se a intenção era filtrar
os *leads gerados* a partir de uma empresa, isso já é o filtro do funil.

---

## 7. Canal e-mail — `Bounce` vira `Enviado`

O chip de resultado do canal e-mail passa a se chamar **Enviado**, com tom
neutro em vez de negativo. Os três resultados ficam: Respondeu · Sem resposta ·
Enviado.

**O valor gravado no banco continua `bounce`.** Renomear a chave exige alterar a
constraint `resultado_valido` em `deal_activities` e dar `update` nas linhas já
gravadas — e a definição dessa constraint não está no repositório. Nenhuma
lógica lê `bounce`: ele só aparece como rótulo (chip do modal e barra de
"Composição por desfecho" no relatório), e os dois rótulos foram trocados juntos.
Dentro do sistema está consistente; o que fica pendente é o nome da chave no banco.

Para fechar isso depois, rodar no dashboard e me mandar o resultado:

```sql
select conname, pg_get_constraintdef(oid)
  from pg_constraint
 where conrelid = 'public.deal_activities'::regclass and contype = 'c';
```

---

## 8. Ordem de deploy consolidada

1. Migration **0009** no dashboard do Supabase
2. Migration **0010** (depende da coluna criada na 0009)
3. Conferência da 0010 — cada nome deve aparecer **uma vez só**:

```sql
select p.proname, pg_get_function_identity_arguments(p.oid)
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public'
   and p.proname in ('kanban_cards','kanban_contagem','followups_list','followups_contadores')
 order by 1;
```

4. Push do `index.html` → Cloudflare Pages
5. Validar em janela anônima: Kanban carrega, Follow-up carrega, seletor de
   lista aparece depois da primeira importação
