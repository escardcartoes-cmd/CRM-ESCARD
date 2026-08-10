# CRM — Funil de Vendas (Escard)

Orientações para o Claude Code neste repositório.

---

## Contexto crítico — leia antes de qualquer alteração

**Este sistema está em produção e é usado diariamente por uma equipe de vendas.**
Usuários reais: Roberto (admin), Heloísa e Tiago (vendedores). Dados reais de clientes,
negócios e faturamento passam por aqui.

**Zero regressão é requisito duro, não preferência.** Uma alteração que quebra o login,
o Kanban ou o carregamento de leads deixa a equipe sem ferramenta de trabalho até o
rollback. Prefira sempre não entregar a entregar algo com risco não avaliado.

---

## O que é

CRM de funil de vendas em arquivo único: `index.html` (~586 KB).

Bibliotecas de terceiros (CDN), estilos, markup e toda a lógica vivem nesse arquivo.
Sem build, sem `package.json`, sem framework, sem bundler.

Idioma de UI, comentários e identificadores: **português brasileiro**. Mantenha.

### A arquitetura single-file é deliberada

Não é dívida técnica. Não separe CSS/JS em arquivos externos. Não introduza build step,
bundler, framework ou gerenciador de pacotes. O fluxo de deploy inteiro depende de ser
um arquivo só. Se você identificar um motivo forte para mudar isso, **proponha e espere
aprovação** — nunca execute.

---

## Stack

| Camada | Tecnologia |
|---|---|
| Frontend | HTML + CSS + JS vanilla, arquivo único |
| Backend | Supabase — projeto `heevguvboffziehftucp` |
| Auth | Supabase Auth (e-mail/senha, recuperação de senha) |
| Banco | PostgreSQL com RLS ativo em todas as tabelas |
| Realtime | Supabase Realtime (canal de deals) |
| Repositório | GitHub `escardcartoes-cmd/CRM-ESCARD` |
| Deploy | **Cloudflare Pages** (`crm-72a.pages.dev`) |

### Deploy

Push na branch `main` → Cloudflare Pages publica automaticamente.

**Não é Vercel.** Se encontrar referência a Vercel em qualquer contexto deste projeto,
está errado.

---

## Acesso ao banco

Use **exclusivamente** o servidor MCP `supabase-crm`.

Ele está registrado em escopo local neste repositório, autenticado por Personal Access
Token e travado em `--project-ref=heevguvboffziehftucp`, em modo `--read-only`.

**Se aparecer qualquer outro servidor Supabase na lista (ex.: `claude.ai Supabase`),
não use.** Conectores via OAuth já autenticaram na organização errada neste ambiente,
retornando dados de projetos que não são este — com aparência de sucesso. Nome diferente,
banco diferente.

Para escrita no banco (migrations), o `--read-only` precisa ser removido deliberadamente
pelo Roberto. Não contorne. Não sugira contornar.

---

## Regras de alteração

1. **Diagnosticar antes de codar.** Leia a região relevante do arquivo. Não presuma a
   estrutura a partir de memória de turnos anteriores.

2. **Nunca reescreva `index.html` por inteiro.** Só edições cirúrgicas, por substituição
   de trecho único e verificável. Um arquivo de 586 KB reescrito do zero perde conteúdo
   silenciosamente.

3. **Mudança mínima e estritamente aditiva.** Não refatore o que não foi pedido. Não
   "melhore" código adjacente. Não renomeie identificadores existentes.

4. **Cruze todos os IDs de elemento** referenciados antes de editar. O JS depende de
   `getElementById` em dezenas de pontos; um ID alterado quebra em silêncio.

5. **Valide o JS antes de declarar pronto.** Extraia os blocos `<script>` e rode
   `node --check`. Sem exceção.

6. **Light mode sempre.** Tokens de design em `:root`. Sem estilo inline novo, sem
   `!important`.

7. **Sem `console.log` no código final.**

8. **Segredos.** Apenas a `anon key` do Supabase pode estar no `index.html` — é pública
   por design e protegida por RLS. Nenhuma `service_role key`, nenhum token de API,
   nenhuma credencial de terceiros. Nunca.

9. **Toda tabela nova nasce com RLS ativo** e política explícita. Sem exceção.

10. **Todo `async` com erro tratado.** Falha silenciosa em produção é pior que erro visível.

---

## Armadilhas conhecidas deste código

Problemas já enfrentados e resolvidos. Não reintroduza:

- **`onAuthStateChange` + `await`:** não faça chamadas ao banco com `await` dentro do
  callback. O cliente Supabase segura um lock durante o evento e isso causa deadlock em
  alguns navegadores. A inicialização roda fora do callback, via `setTimeout(..., 0)`.

- **Recuperação de senha:** `window.location.hash` precisa ser lido **sincronamente** no
  carregamento, antes da inicialização assíncrona do Supabase — senão o hash é limpo e o
  fluxo quebra. Existe workaround no código; preserve.

- **Limite de 1.000 linhas:** o Supabase pagina por padrão em 1.000 registros. Consultas
  que precisam de tudo carregam em blocos. Não remova essa lógica.

- **Cache do navegador:** falhas de login após deploy costumam ser cache. Testar em janela
  anônima antes de investigar o código.

- **Configuração de Auth não é acessível por MCP.** Redirect URLs, site URL, SMTP e JWT
  só mudam pelo dashboard do Supabase ou Management API. Não tente via `execute_sql`.

---

## Checklist antes de qualquer commit

Aplique o crivo de cada papel. Não declare pronto sem passar por todos:

- **Segurança** — input validado · nenhum segredo exposto · RLS ativo · sem XSS
- **Arquitetura** — single-file preservado · responsabilidades no lugar
- **Backend** — todo `async` com erro tratado · transações consistentes
- **Frontend** — semântico · acessível · responsivo · light mode
- **Dados** — tipagem correta · migration versionada se houve DDL
- **DevOps** — não derruba produção · rollback possível
- **QA** — casos de borda · cálculos conferidos · sem `console.log`

E a pergunta final: **isto pode quebrar algo que funcionava?** Se a resposta não for um
"não" fundamentado, não comite.

---

## Fluxo de trabalho

1. Editar `index.html` localmente
2. Extrair blocos `<script>` e rodar `node --check`
3. Rodar o checklist acima
4. `git add` → `git commit` com mensagem descritiva → `git push`
5. Cloudflare Pages publica em ~1 min
6. Validar em janela anônima

Mensagens de commit descrevem a mudança, não o arquivo. "Update index.html" não diz nada.
