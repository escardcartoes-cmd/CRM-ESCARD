# spec-importador-b2b.md — Importação de listas B2B

**Pré-requisito:** migration `20260819_0007_importacao_b2b.sql` aplicada.

Objetivo: reconhecer listas de prospecção B2B (Receita Federal / Casa dos Dados) sem
exigir que o usuário renomeie colunas na planilha, e impedir duplicidade por CNPJ.

Arquivo analisado como referência: 4.734 empresas, 26 colunas, separador `;`, UTF-8.

---

## Regras

Edição cirúrgica · zero regressão · iOS-safe · sem dependência nova (SheetJS já está
no arquivo) · `node --check` · sem `console.log` · você não commita.

**A importação atual não pode quebrar.** Planilhas com os títulos antigos (`nome`,
`contato`, `telefone`…) continuam funcionando exatamente como hoje.

---

## 1. Reconhecimento de colunas por sinônimo

Hoje o importador exige títulos exatos. Passa a aceitar uma lista de sinônimos por
campo, comparando de forma **normalizada**: minúsculas, sem acento, sem espaço,
sem underscore. Assim `Razão Social`, `razaoSocial` e `RAZAO_SOCIAL` casam igual.

| Campo destino | Sinônimos aceitos |
|---|---|
| `title` | nome, nomefantasia, fantasia, empresa, nomeempresa |
| `razao_social` | razaosocial, razao, socialname |
| `cnpj` | cnpj, cnpjcpf, documento |
| `contact_name` | contato, socios, socio, responsavel, representante |
| `contact_phone` | telefone, telefone1, fone, telefonefixo |
| `whatsapp` | whatsapp, celular, telefone2, telefonecelular |
| `contact_email` | email, emails, contatoemail |
| `city` | municipio, cidade |
| `bairro` | bairro |
| `cnae` | cnaeprincipal, cnae, atividade, atividadeprincipal |
| `porte` | porte |
| `faixa_faturamento` | faixafaturamento, faturamento, receita |
| `socios` | socios, quadrosocietario |
| `value` | valor |
| `origem` | origem, fonte |

Colunas não reconhecidas são **ignoradas em silêncio** — a lista tem 26 colunas e a
maioria não interessa ao CRM.

---

## 2. Regras de transformação

Estas são o coração da entrega. Sem elas, 41% dos leads entram sem nome.

### 2.1 `title` — nome do lead

```
title = nomeFantasia se preenchido, senão razaoSocial
```

No arquivo de referência, `nomeFantasia` está vazio em **41,2%** dos registros
(1.952 de 4.734), e **todos** esses têm `razaoSocial`. Sem o fallback, quase metade
da importação entra sem identificação.

`razao_social` guarda sempre a razão social, mesmo quando ela também virou o `title`.

### 2.2 `contact_name` — primeiro sócio pessoa física

O campo `socios` traz o quadro societário separado por `|`, misturando pessoas e
empresas:

```
Asc Servicos E Participacoes Ltda|Csa Participacoes Ltda|Andre Savergnini Ceccon
```

Pegar o **primeiro item que não seja pessoa jurídica**. Descartar o que contiver:
`ltda`, `s.a`, `s. a`, `participacoes`, `eireli`, `epp`, `sociedade`, `holding`,
`empreendimentos`, `servicos`, `s/a`.

No arquivo de referência isso identifica pessoa física em **98%** dos registros.
Se nenhum item passar no filtro, deixar `contact_name` vazio — nunca gravar razão
social de holding como nome de contato.

Se a planilha tiver uma coluna `contato` explícita, ela **tem prioridade** sobre
`socios`.

### 2.3 Telefone e WhatsApp

O `telefone_1` da lista é predominantemente **fixo**: 3.526 fixos contra 989
celulares. Preencher `whatsapp` com ele produziria WhatsApp inválido em 77% dos casos.

Regra, avaliando `telefone_1`, `telefone_2` e `outrosTelefones` (este último é uma
lista separada por vírgula):

```
whatsapp       = primeiro número com 11 dígitos cujo 3º dígito seja 9
contact_phone  = primeiro número restante (preferir 10 dígitos)
```

Normalizar para dígitos antes de comparar. `outrosTelefones` traz número que não
está em `telefone_1` nem `telefone_2` em **1.107 registros** — é onde estão os
celulares que faltam. Descartar duplicatas entre os campos.

### 2.4 Município

Aplicar a mesma normalização que a migration 0003 fez no banco: preposição em
minúscula. No arquivo há **547 registros** com `De`, `Do`, `Da` maiúsculos
(`Cachoeiro De Itapemirim` → `Cachoeiro de Itapemirim`).

Sem isso, a lista de municípios do painel volta a ter valores duplicados.

### 2.5 E-mail

`email` pode trazer múltiplos separados por vírgula. Usar o primeiro.

---

## 3. Deduplicação por CNPJ — obrigatória

**Antes de inserir qualquer linha**, uma única chamada:

```js
db.rpc('cnpjs_existentes', { p_cnpjs: arrayDeCnpjsDoArquivo })
```

Retorna os que já existem, com dono e etapa atual:

```
cnpj_digitos | deal_id | titulo | responsavel | etapa
```

A RPC compara por dígitos — funciona com ou sem máscara. Limite de 20.000 por chamada.

**Uma chamada para o arquivo inteiro. Nunca uma por linha.**

### Tela de confirmação

Depois da leitura do arquivo e antes de gravar, mostrar:

```
Arquivo: 4.734 empresas
  4.512 novas
    222 já existem no CRM

[ ] Ignorar as que já existem  (padrão, marcado)
[ ] Importar mesmo assim, criando duplicata
```

Listar as 10 primeiras duplicadas com título, responsável e etapa, para o usuário
entender o que está descartando. Nunca decidir sozinho por ele.

Linhas **sem CNPJ** não passam pela deduplicação — importar normalmente.

---

## 4. Prévia antes de gravar

Com 4.734 linhas, errar o mapeamento e descobrir depois é caro. Antes de importar,
mostrar as **5 primeiras linhas já transformadas**, com os nomes dos campos do CRM:

```
Nome            MBA TRANSPORTES
Razão social    MBA TRANSPORTES LTDA
Contato         Joelson Doano
Telefone        27 998000506
WhatsApp        27998000506
Município       Linhares
Porte           ME
```

E o resumo do mapeamento: quais colunas do arquivo foram reconhecidas e quais foram
ignoradas.

---

## 5. Desempenho

4.734 linhas em `INSERT` individual é inviável. Inserir em **lotes de 500** via
`db.from('deals').insert(array)`, com barra de progresso.

Cada lote é uma transação, então compartilha o mesmo `txid` — a trilha de auditoria
vai agrupar corretamente, e o painel mostrará "lote de N registros" em vez de 4.734
linhas soltas.

Se um lote falhar, **parar** e informar quantos entraram. Não continuar às cegas.

Ao final, registrar o evento:

```js
db.rpc('registrar_evento', {
  p_event_type: 'import',
  p_entidade: 'deals',
  p_metadata: { total: n, ignorados_duplicados: d, arquivo: nomeDoArquivo }
});
```

---

## 6. Separador de CSV

O arquivo de referência usa `;`, não `,`. Detectar automaticamente: contar
ocorrências de `;` e `,` na primeira linha e usar o mais frequente. Planilhas
brasileiras exportam com `;` na maioria dos casos.

---

## Checklist

```
[ ] Planilha no formato antigo continua importando igual
[ ] Sinônimos casam ignorando acento, caixa, espaço e underscore
[ ] nomeFantasia vazio cai para razaoSocial
[ ] contact_name pega o primeiro sócio pessoa física, nunca holding
[ ] Coluna "contato" explícita tem prioridade sobre socios
[ ] whatsapp recebe só celular (11 dígitos, 3º = 9)
[ ] outrosTelefones é considerado
[ ] Município normalizado (preposição minúscula)
[ ] cnpjs_existentes chamada UMA vez, não por linha
[ ] Tela de confirmação com contagem e as 10 primeiras duplicadas
[ ] Prévia de 5 linhas transformadas antes de gravar
[ ] Inserção em lotes de 500 com progresso
[ ] Lote falho interrompe e informa o que entrou
[ ] registrar_evento('import') ao final
[ ] Separador ; e , detectados automaticamente
[ ] iOS-safe · node --check · sem console.log
[ ] Regressão: Kanban, Follow-up, Relatórios intactos
```
