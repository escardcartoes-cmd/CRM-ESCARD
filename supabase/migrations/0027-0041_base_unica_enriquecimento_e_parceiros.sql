-- =====================================================================
-- CRM-ESCARD · Migrations 0027 a 0041 · 2026-09-21
-- Importacao da Base Unica, enriquecimento sem fonte paga e marcacao
-- de leads PARCEIRO.
--
-- TODAS JA APLICADAS EM PRODUCAO via MCP (projeto heevguvboffziehftucp).
-- Este arquivo e o registro versionado: DDL completo (funcoes, triggers,
-- cron) + descricao dos UPDATEs em massa + conferencia + rollback.
--
-- NAO REEXECUTAR os blocos marcados [JA APLICADO - DADOS].
-- Os blocos [DDL] sao idempotentes e seguros para recriar o schema.
--
-- Fontes usadas, nenhuma paga:
--   escard.cnpj_dados  · BrasilAPI, ja baixada no banco
--   Base Unica.xlsx    · planilha do proprio Roberto
--   public.deals       · derivacao interna
--
-- Nada alterou stage_id, owner_id, next_followup_date, cadencia ou
-- deal_stage_history, com uma excecao declarada na 0041.
-- A trilha de auditoria (trg_audit_deals) permaneceu LIGADA o tempo todo.
-- =====================================================================


-- =====================================================================
-- BACKUPS  [JA APLICADO]
-- =====================================================================
-- 0027: public.bkp_enriq_0027_20260921
--       id, cnpj, contact_email, contact_name, whatsapp, city, bairro,
--       socios, cnae, porte, faixa_faturamento, razao_social, updated_at
--       19.176 linhas (estado anterior a qualquer alteracao de hoje)
--
-- 0037: public.bkp_enriq_0037_20260921
--       id, cnae, porte, socios, razao_social, city, updated_at
--
-- 0039: public.bkp_parceiro_0039_20260921
--       id, lista_origem, source
--
-- Os tres foram criados com RLS habilitado e REVOKE ALL de anon/authenticated.
-- Padrao para recriar, se necessario:
--
--   create table public.bkp_<nome>_<data> as select <colunas> from public.deals;
--   alter table public.bkp_<nome>_<data> enable row level security;
--   revoke all on public.bkp_<nome>_<data> from anon, authenticated;


-- =====================================================================
-- 0027 · FASE A — propagacao do dado que ja estava no banco  [JA APLICADO - DADOS]
-- =====================================================================
-- O enriquecimento por CNPJ ja tinha baixado 11.293 empresas, mas esses
-- campos nunca chegaram ao lead. Preenchido SO onde estava vazio:
--
--   cnae         <- escard.cnpj_dados.cnae_principal          +2.117
--   porte        <- cnpj_dados.porte normalizado ME/EPP/Demais +2.117
--   socios       <- cnpj_dados.socios, separador "|"           +2.110
--   razao_social <- cnpj_dados.razao_social                    +8.082
--   whatsapp     <- contact_phone quando ja era celular        +1.219
--
-- E a limpeza de encoding que a migration 0022 nao cobriu:
--   update public.deals set cnae = public.fn_desmojibake(cnae)
--    where cnae ~ '[ÃÂ]';                                      10.708
--   update public.deals set faixa_faturamento = public.fn_desmojibake(faixa_faturamento)
--    where faixa_faturamento ~ '[ÃÂ]';                          9.817


-- =====================================================================
-- 0028 · CAUSA RAIZ DO MOJIBAKE  [DDL]
-- =====================================================================
-- escard.fn_enriquecer_lote grava o corpo da BrasilAPI sem normalizar o
-- encoding, entao o defeito voltaria a cada lote novo. Em vez de reescrever
-- a funcao inteira, saneia na entrada da tabela.

create or replace function escard.fn_cnpj_dados_saneia()
returns trigger
language plpgsql
set search_path to 'public'
as $$
begin
  new.razao_social   := public.fn_desmojibake(new.razao_social);
  new.nome_fantasia  := public.fn_desmojibake(new.nome_fantasia);
  new.cnae_principal := public.fn_desmojibake(new.cnae_principal);
  new.socios         := public.fn_desmojibake(new.socios);
  new.municipio      := public.fn_desmojibake(new.municipio);
  return new;
end $$;

drop trigger if exists trg_cnpj_dados_saneia on escard.cnpj_dados;
create trigger trg_cnpj_dados_saneia
before insert or update on escard.cnpj_dados
for each row execute function escard.fn_cnpj_dados_saneia();


-- =====================================================================
-- 0029 a 0034 · FASE B — o que so a planilha tinha  [JA APLICADO - DADOS]
-- =====================================================================
-- Casamento por telefone normalizado, com CNPJ como chave preferencial.
-- Preenchido SO onde estava vazio:
--
--   cnpj          +932   -> destrava o cron gratuito de enriquecimento
--   contact_email +997
--   city          +428
--   whatsapp      +173
--   contact_name   +38   (nomes de vendedores da equipe foram excluidos:
--                         a coluna Contato da planilha trazia o proprio
--                         Roberto em varios registros)
--
-- Forma dos UPDATEs, para referencia:
--   update public.deals d set <campo> = v.x
--     from (values ('<id8>','<valor>'), ...) as v(i,x)
--    where substr(d.id::text,1,8) = v.i and coalesce(d.<campo>,'') = '';


-- =====================================================================
-- 0035 · SANEAMENTO  [DDL/DADOS - reexecutavel, idempotente]
-- =====================================================================

-- Dominios com erro de digitacao evidente na origem
update public.deals set contact_email = regexp_replace(lower(contact_email), '@otmail\.com$', '@hotmail.com')
 where lower(contact_email) ~ '@otmail\.com$';
update public.deals set contact_email = regexp_replace(lower(contact_email), '@hotmla\.com$', '@hotmail.com')
 where lower(contact_email) ~ '@hotmla\.com$';
update public.deals set contact_email = regexp_replace(lower(contact_email), '@gamil\.com$', '@gmail.com')
 where lower(contact_email) ~ '@gamil\.com$';
update public.deals set contact_email = regexp_replace(lower(contact_email), '@gmial\.com$', '@gmail.com')
 where lower(contact_email) ~ '@gmial\.com$';
update public.deals set contact_email = regexp_replace(lower(contact_email), 'combr$', 'com.br')
 where lower(contact_email) ~ '[^.]combr$';

-- E-mails fora do padrao ou placeholder -> null   (327 removidos)
update public.deals set contact_email = null
 where coalesce(contact_email,'') <> ''
   and (contact_email !~ '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$'
        or lower(contact_email) in ('a@aaaa.com','teste@teste.com','email@email.com','x@x.com'));

-- Cidade: unifica grafias divergentes (acento e caixa) pela forma mais usada.
-- Sem isso o filtro por cidade lista "Serra", "SERRA" e "Santa Maria De Jetiba"
-- como municipios diferentes.  (0038 repetiu este bloco apos a importacao)
with base as (
  select city, count(*) n,
         lower(translate(city,'ÁÀÂÃÄÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇáàâãäéèêëíìîïóòôõöúùûüç',
                              'aaaaaeeeeiiiiooooouuuucaaaaaeeeeiiiiooooouuuuc')) chave
    from public.deals where coalesce(city,'') <> '' group by city
), canonica as (
  select distinct on (chave) chave, city from base order by chave, n desc, city
)
update public.deals d
   set city = c.city
  from canonica c
 where lower(translate(d.city,'ÁÀÂÃÄÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇáàâãäéèêëíìîïóòôõöúùûüç',
                              'aaaaaeeeeiiiiooooouuuucaaaaaeeeeiiiiooooouuuuc')) = c.chave
   and coalesce(d.city,'') <> ''
   and d.city is distinct from c.city;


-- =====================================================================
-- 0036 · PROPAGACAO DO ENRIQUECIMENTO PARA A FICHA DO LEAD  [DDL]
-- =====================================================================
-- Diagnostico: o enriquecedor gravava em escard.cnpj_dados e parava ali.
-- deals.cnae / porte / socios / razao_social / city nunca recebiam o dado,
-- e a ficha que o vendedor abre ficava vazia. Este trigger fecha o circuito.

create or replace function escard.fn_propagar_para_deals()
returns trigger
language plpgsql
security definer
set search_path to 'escard','public'
as $$
begin
  update public.deals d
     set cnae         = coalesce(nullif(d.cnae,''),         new.cnae_principal),
         porte        = coalesce(nullif(d.porte,''),
                                 case when upper(new.porte) like 'MICRO%'    then 'ME'
                                      when upper(new.porte) like '%PEQUENO%' then 'EPP'
                                      when new.porte is not null             then 'Demais' end),
         socios       = coalesce(nullif(d.socios,''),       nullif(replace(new.socios, ', ', '|'),'')),
         razao_social = coalesce(nullif(d.razao_social,''), new.razao_social),
         city         = coalesce(nullif(d.city,''),         initcap(lower(new.municipio)))
   where regexp_replace(coalesce(d.cnpj,''),'\D','','g') = new.cnpj
     and (coalesce(d.cnae,'')='' or coalesce(d.porte,'')='' or coalesce(d.socios,'')=''
          or coalesce(d.razao_social,'')='' or coalesce(d.city,'')='');
  return null;
end $$;

drop trigger if exists trg_cnpj_dados_propaga on escard.cnpj_dados;
create trigger trg_cnpj_dados_propaga
after insert or update on escard.cnpj_dados
for each row execute function escard.fn_propagar_para_deals();

-- [JA APLICADO - DADOS] No mesmo bloco: 2.110 CNPJs do primeiro lote
-- (21/08), anteriores a migration 0023, voltaram para a fila. Estavam
-- marcados 'ok' com situacao_cadastral e telefone vazios e, por isso,
-- nunca seriam revisitados:
--
--   update escard.enriquecimento e set status='pendente', tentativas=0
--     from escard.cnpj_dados c
--    where c.cnpj = e.cnpj and e.status='ok'
--      and coalesce(c.situacao_cadastral,'')='' and coalesce(c.telefone_1,'')='';


-- =====================================================================
-- 0037 · BACKFILL DA PROPAGACAO  [JA APLICADO - DADOS]
-- =====================================================================
-- O trigger 0036 so age em dado novo. Backfill unico para os leads cujo
-- CNPJ ja estava enriquecido, com a mesma regra de "so campo vazio":
--
--   cnae <- cnae_principal · porte <- normalizado · socios <- com "|"
--   razao_social <- razao_social · city <- initcap(municipio)


-- =====================================================================
-- 0039 · LEADS PARCEIROS (canal, nao cliente final)  [DDL]
-- =====================================================================
-- Contabilidade e seguros nao sao cliente final de cartao beneficio: sao
-- canal de distribuicao. Recebem rotulo visivel, viram filtro e ganham
-- orientacao de abordagem na ficha.
--
-- Idempotente: pode rodar quantas vezes quiser, so pega quem ainda nao
-- esta marcado. Preserva a lista anterior no campo source.

create or replace function escard.fn_marcar_parceiros()
returns table(contabilidade integer, seguros integer)
language plpgsql
security definer
set search_path to 'escard','public'
as $$
declare v_cont int := 0; v_seg int := 0; v_autor uuid;
begin
  select id into v_autor from public.profiles where email = 'roberto@escardcartoes.com.br';

  with alvo as (
    select d.id,
           case
             when substring(coalesce(nullif(d.cnae,''), cd.cnae_principal) from '(\d{4})') = '6920' then 'Contabilidade'
             when substring(coalesce(nullif(d.cnae,''), cd.cnae_principal) from '(\d{4})')
                  in ('6511','6512','6520','6530','6541','6542','6550','6622') then 'Seguros'
             when upper(coalesce(d.title,'')||' '||coalesce(d.razao_social,''))
                  ~ 'CONTABIL|CONTABILIDADE|CONTADOR|CONTABEIS' then 'Contabilidade'
             when upper(coalesce(d.title,'')||' '||coalesce(d.razao_social,''))
                  ~ 'SEGURADORA|SEGUROS|PLANO DE SAUDE|PLANOS DE SAUDE|UNIMED|PREVIDENCIA|ODONTOPREV' then 'Seguros'
           end as tipo,
           d.lista_origem, d.source
      from public.deals d
      left join escard.cnpj_dados cd on cd.cnpj = regexp_replace(coalesce(d.cnpj,''),'\D','','g')
     where coalesce(d.lista_origem,'') not like 'PARCEIRO%'
  ), upd as (
    update public.deals d
       set source = coalesce(nullif(d.source,''), nullif(a.lista_origem,'')),
           lista_origem = 'PARCEIRO · ' || a.tipo
      from alvo a
     where a.id = d.id and a.tipo is not null
    returning d.id, a.tipo
  )
  select count(*) filter (where tipo='Contabilidade'), count(*) filter (where tipo='Seguros')
    into v_cont, v_seg from upd;

  insert into public.deal_notes (deal_id, author_id, note)
  select d.id, v_autor,
         case when d.lista_origem = 'PARCEIRO · Contabilidade' then
           '[PARCEIRO] Canal, nao cliente final. Escritorio de contabilidade atende dezenas de empresas com folha e e quem responde quando o cliente pergunta sobre beneficio. A ligacao nao e para vender cartao para este CNPJ: e para abrir parceria de indicacao. Pergunte quantos clientes com carteira assinada ele atende.'
         else
           '[PARCEIRO] Canal, nao cliente final. Corretora / seguros ja esta sentada na mesa do RH vendendo plano de saude. A ligacao e para entrar como produto complementar na carteira dela, nao para vender cartao para este CNPJ. Pergunte quantas empresas ela atende hoje.'
         end
    from public.deals d
   where d.lista_origem like 'PARCEIRO%'
     and not exists (select 1 from public.deal_notes n where n.deal_id = d.id and n.note like '[PARCEIRO]%')
     and v_autor is not null;

  return query select v_cont, v_seg;
end $$;


-- =====================================================================
-- 0040 · AGENDAMENTO  [DDL]
-- =====================================================================
-- Pega os lotes novos quando entrarem e os leads que ganharem CNAE pelo
-- enriquecimento, sem reprocessar quem ja esta marcado.
--
-- select cron.schedule('escard_marcar_parceiros', '*/10 * * * *',
--                      $$select escard.fn_marcar_parceiros();$$);
--
-- Crons ativos apos esta migration:
--   purga_auditoria_crm      0 4 1 * *
--   escard_enriquecer        */3 * * * *
--   escard_reclassificar     */15 * * * *
--   escard_marcar_parceiros  */10 * * * *


-- =====================================================================
-- 0041 · REPAROS DA IMPORTACAO  [JA APLICADO - DADOS]
-- =====================================================================
-- 1) O importador descartou 1 dos 24.361 leads do arquivo, sem bater com
--    nenhuma regra de descarte conhecida (tinha nome, telefone e e-mail).
--    Inserido a mao: TANIA M P PIACENTINI, (27) 99874-6244, Lote 5.
--
-- 2) Cinco telefones com digitos repetidos furaram a validacao de origem
--    (99999999999, 88988888888, 22999999999, 2722222222, 2727272727).
--    Movidos para Perdidos com loss_reason 'Outro' e nota explicativa.
--    UNICA alteracao de etapa desta sequencia. Feita dentro de
--    set_config('app.mov_automatica','on',true) para o historico registrar
--    como movimentacao de sistema e nao creditar nenhum vendedor.
--
--    Deteccao, para reaproveitar em importacoes futuras:
--      (select count(distinct ch) from unnest(string_to_array(
--         regexp_replace(coalesce(contact_phone,''),'\D','','g'), null)) ch) <= 2


-- =====================================================================
-- CONFERENCIA
-- =====================================================================
-- select count(*) total,
--   count(*) filter (where coalesce(cnae,'')='')         sem_cnae,
--   count(*) filter (where coalesce(socios,'')='')       sem_socios,
--   count(*) filter (where coalesce(razao_social,'')='') sem_razao,
--   count(*) filter (where coalesce(whatsapp,'')='')     sem_whats,
--   count(*) filter (where coalesce(city,'')='')         sem_cidade,
--   count(*) filter (where cnae ~ '[ÃÂ]' or city ~ '[ÃÂ]'
--                       or faixa_faturamento ~ '[ÃÂ]')   mojibake,
--   count(*) filter (where lista_origem like 'PARCEIRO%') parceiros,
--   count(*) filter (where owner_id is null or stage_id is null) orfaos
--   from public.deals;
--
-- Estado em 21/09/2026, fim da sequencia:
--   total 43.537 · importados hoje 24.361 · parceiros 1.824
--   mojibake 0 · orfaos 0 · duplicatas criadas 0
--   fila de enriquecimento 16.780 · cnpj_dados 12.013
--
-- select * from escard.fn_marcar_parceiros();   -- roda sob demanda


-- =====================================================================
-- ROLLBACK  ·  NUNCA executar junto com os blocos acima
-- =====================================================================
-- Parceiros (0039 / 0040):
--   select cron.unschedule('escard_marcar_parceiros');
--   delete from public.deal_notes where note like '[PARCEIRO]%';
--   update public.deals d set lista_origem = b.lista_origem, source = b.source
--     from public.bkp_parceiro_0039_20260921 b where b.id = d.id;
--   drop function if exists escard.fn_marcar_parceiros();
--
-- Propagacao (0036 / 0037):
--   drop trigger if exists trg_cnpj_dados_propaga on escard.cnpj_dados;
--   drop function if exists escard.fn_propagar_para_deals();
--   update public.deals d
--      set cnae = b.cnae, porte = b.porte, socios = b.socios,
--          razao_social = b.razao_social, city = b.city, updated_at = b.updated_at
--     from public.bkp_enriq_0037_20260921 b where b.id = d.id;
--
-- Saneamento de encoding (0028):
--   drop trigger if exists trg_cnpj_dados_saneia on escard.cnpj_dados;
--   drop function if exists escard.fn_cnpj_dados_saneia();
--
-- Enriquecimento completo (0027 a 0035) — volta os 12 campos ao estado
-- anterior a qualquer alteracao de 21/09:
--   update public.deals d
--      set cnpj = b.cnpj, contact_email = b.contact_email,
--          contact_name = b.contact_name, whatsapp = b.whatsapp,
--          city = b.city, bairro = b.bairro, socios = b.socios,
--          cnae = b.cnae, porte = b.porte,
--          faixa_faturamento = b.faixa_faturamento,
--          razao_social = b.razao_social, updated_at = b.updated_at
--     from public.bkp_enriq_0027_20260921 b where b.id = d.id;
--
-- ATENCAO: o rollback acima NAO remove os 24.361 leads importados.
-- Para isso: delete from public.deals where lista_origem in
--   ('Lote 01','Lote 02','Lote 3','Lote 4','Lote 5')
--    or (lista_origem like 'PARCEIRO%' and source in
--        ('Lote 01','Lote 02','Lote 3','Lote 4','Lote 5'));
