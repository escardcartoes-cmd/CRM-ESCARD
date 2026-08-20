-- =============================================================================
-- MIGRATION 20260819_0007 — Campos B2B e deduplicação por CNPJ
-- Projeto: CRM Funil de Vendas (Escard) · Supabase heevguvboffziehftucp
-- Depende de: 0001 a 0006
-- =============================================================================
-- Motivação: listas de prospecção B2B (Receita/Casa dos Dados) trazem razão
-- social, CNAE, porte e faixa de faturamento — dado de segmentação que hoje se
-- perde na importação porque não há onde guardar.
--
-- Também prepara a deduplicação: importar 4.734 empresas numa base de 3.010 sem
-- checar CNPJ produz carteira duplicada, que é pior que carteira pequena.
--
-- Aditiva. Todas as colunas são nullable. Nenhum registro existente é alterado.
-- =============================================================================

begin;

-- =============================================================================
-- 1. COLUNAS
-- =============================================================================
alter table public.deals add column if not exists razao_social       text;
alter table public.deals add column if not exists cnae               text;
alter table public.deals add column if not exists porte              text;
alter table public.deals add column if not exists faixa_faturamento  text;
alter table public.deals add column if not exists bairro             text;
alter table public.deals add column if not exists socios             text;

comment on column public.deals.razao_social      is 'Razão social. O campo title guarda o nome fantasia, ou a razão social quando não há fantasia.';
comment on column public.deals.cnae              is 'CNAE principal, no formato "código - descrição".';
comment on column public.deals.porte             is 'Porte declarado: ME, EPP ou Demais.';
comment on column public.deals.faixa_faturamento is 'Faixa de faturamento estimada da lista de origem.';
comment on column public.deals.socios            is 'Quadro societário separado por |. O primeiro sócio pessoa física vira contact_name na importação.';


-- =============================================================================
-- 2. CNPJ NORMALIZADO — chave de deduplicação
-- =============================================================================
-- CNPJ chega com e sem máscara. A comparação precisa ser feita sobre os dígitos.
create or replace function public.fn_cnpj_digitos(p_cnpj text)
returns text
language sql
immutable
as $$
  select nullif(regexp_replace(coalesce(p_cnpj, ''), '\D', '', 'g'), '');
$$;

comment on function public.fn_cnpj_digitos(text) is
  'Devolve só os dígitos do CNPJ, ou null quando vazio. Base da deduplicação.';

-- Índice funcional: torna a checagem de duplicidade instantânea mesmo com
-- dezenas de milhares de leads. NÃO é unique de propósito — a base atual pode
-- ter duplicidade legítima ou histórica, e a migration não deve falhar por isso.
create index if not exists idx_deals_cnpj_digitos
  on public.deals (public.fn_cnpj_digitos(cnpj))
  where cnpj is not null;

create index if not exists idx_deals_porte             on public.deals (porte);
create index if not exists idx_deals_faixa_faturamento on public.deals (faixa_faturamento);


-- =============================================================================
-- 3. RPC DE VERIFICAÇÃO DE DUPLICIDADE
-- =============================================================================
-- Recebe a lista de CNPJs do arquivo e devolve os que já existem, com o dono
-- atual. O importador usa isso ANTES de inserir, numa chamada só — nunca em
-- laço, que seria uma consulta por linha.
create or replace function public.cnpjs_existentes(p_cnpjs text[])
returns table (
  cnpj_digitos text,
  deal_id      uuid,
  titulo       text,
  responsavel  text,
  etapa        text
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
  if auth.uid() is null then
    raise exception 'Verificação exige usuário autenticado.' using errcode = '42501';
  end if;
  if p_cnpjs is null or array_length(p_cnpjs, 1) is null then
    return;
  end if;
  if array_length(p_cnpjs, 1) > 20000 then
    raise exception 'Lista excede 20.000 CNPJs.' using errcode = '22023';
  end if;

  return query
  select public.fn_cnpj_digitos(d.cnpj),
         d.id,
         d.title,
         coalesce(p.full_name, '—'),
         coalesce(s.name, '—')
    from public.deals d
    left join public.profiles p        on p.id = d.owner_id
    left join public.pipeline_stages s on s.id = d.stage_id
   where public.fn_cnpj_digitos(d.cnpj) = any (
           select public.fn_cnpj_digitos(x) from unnest(p_cnpjs) x
         );
end;
$$;

revoke all on function public.cnpjs_existentes(text[]) from public, anon;
grant execute on function public.cnpjs_existentes(text[]) to authenticated;

commit;

-- =============================================================================
-- ROLLBACK
-- =============================================================================
-- begin;
--   drop function if exists public.cnpjs_existentes(text[]);
--   drop index if exists public.idx_deals_cnpj_digitos;
--   drop index if exists public.idx_deals_porte;
--   drop index if exists public.idx_deals_faixa_faturamento;
--   drop function if exists public.fn_cnpj_digitos(text);
--   alter table public.deals drop column if exists razao_social;
--   alter table public.deals drop column if exists cnae;
--   alter table public.deals drop column if exists porte;
--   alter table public.deals drop column if exists faixa_faturamento;
--   alter table public.deals drop column if exists bairro;
--   alter table public.deals drop column if exists socios;
-- commit;
