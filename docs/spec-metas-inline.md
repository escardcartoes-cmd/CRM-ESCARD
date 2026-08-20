# spec-metas-inline.md — Edição de metas no painel de Relatórios

**Pré-requisito:** migrations 0004 e 0006 aplicadas. Nenhuma alteração de banco.

Objetivo: permitir que o admin ajuste metas sem sair da tela de Relatórios, onde
está vendo o progresso. A grade em Administração continua existindo e é a mesma
fonte — não duplicar lógica.

---

## Regras

Edição cirúrgica · zero regressão · iOS-safe na IIFE · sem dependência nova ·
`node --check` · sem `console.log` · você não commita.

---

## 1. Onde

No cabeçalho do painel **"Progresso das metas"**, à direita, um botão **"Editar metas"**.

**Só para admin.** Vendedor não vê o botão. A RPC `metas_salvar` já recusa quem não
é admin, mas o botão não deve aparecer — não oferecer caminho que vai dar erro.

Quando o admin estiver com um vendedor selecionado no filtro do topo, editar as metas
**daquele** vendedor. Com "Toda a equipe" selecionado, o editor precisa do próprio
seletor de vendedor — não faz sentido editar meta de equipe, meta é individual.

---

## 2. Comportamento

Ao clicar em "Editar metas", o painel alterna para modo de edição **no lugar**, sem
modal e sem trocar de aba:

- Cada linha de progresso vira uma linha editável: rótulo, campo numérico com o valor
  atual, e o realizado ao lado como referência.
- Mostrar **todos os 9 indicadores × 3 periodicidades**, inclusive os que estão em 0 —
  é justamente onde o admin vai querer ligar uma meta nova.
- Botão "Concluir" volta ao modo de visualização e recarrega o progresso.

Reaproveitar o componente da grade de Administração se isso for possível sem
refatoração grande. Se não for, reutilizar ao menos `METAS_IND` e a função de salvar —
**não criar um segundo caminho de escrita.**

---

## 3. Salvamento automático

Salvar no evento `change` do campo (quando perde o foco ou o valor muda), não a cada
tecla digitada — digitar "200" dispararia três chamadas.

```js
db.rpc('metas_salvar', {
  p_owner: ownerId,
  p_indicador: indicador,
  p_periodicidade: periodicidade,
  p_valor: Number(valor)
})
```

**Retorno visual obrigatório.** Salvamento silencioso é pior que salvamento manual: o
usuário não sabe se funcionou.

| Estado | Sinal |
|---|---|
| Salvando | campo esmaecido ou spinner discreto |
| Salvo | ✓ verde ao lado do campo, some após ~2s |
| Erro | borda vermelha + mensagem, e o campo volta ao valor anterior |

Não recarregar o painel inteiro a cada salvamento — só a linha alterada.

---

## 4. Validação antes de chamar a RPC

- Vazio ou não numérico → tratar como 0
- Negativo → não chamar a RPC, marcar erro no campo
- Valor igual ao atual → não chamar a RPC (evita escrita à toa)

A RPC também valida (erro 22023 para negativo, 42501 para não-admin). Tratar os dois.

---

## 5. Ao concluir

Recarregar `metas_progresso` e voltar ao modo de visualização. As barras devem refletir
as metas novas imediatamente.

---

## Checklist

```
[ ] Botão só aparece para admin
[ ] Com "Toda a equipe", o editor tem seletor próprio de vendedor
[ ] Todos os 9 indicadores aparecem, inclusive os zerados
[ ] Salva no change, não a cada tecla
[ ] Feedback visual de salvando / salvo / erro
[ ] Valor negativo bloqueado antes da RPC
[ ] Valor inalterado não dispara chamada
[ ] Erro reverte o campo ao valor anterior
[ ] Um único caminho de escrita, compartilhado com a grade de Administração
[ ] Concluir recarrega o progresso
[ ] iOS-safe · node --check · sem console.log
[ ] Regressão: grade de Administração continua funcionando igual
```
