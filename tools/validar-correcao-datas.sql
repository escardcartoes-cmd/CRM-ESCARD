-- =============================================================================
-- VALIDAÇÃO DA CORREÇÃO DE DATAS (0017b)
-- Confere, contra a tabela de backup, que cada registro foi para a data em que
-- foi digitado — e mostra o antes e depois por dia.
-- Só leitura.
-- =============================================================================

-- 1) O BACKUP EXISTE E COBRE TUDO?
--    Esperado: o mesmo número de registros que estavam com data futura.
select count(*)                                                          as registros_no_backup,
       count(*) filter (where channel = 'telefone')                      as ligacoes,
       min(date(occurred_at at time zone 'America/Sao_Paulo'))           as data_errada_mais_antiga,
       max(date(occurred_at at time zone 'America/Sao_Paulo'))           as data_errada_mais_recente,
       min(backup_em)                                                    as quando_foi_o_backup
  from public.bkp_occurred_futuro_20260828;


-- 2) CADA UM FOI PARA A DATA EM QUE FOI DIGITADO?
--    Esperado: divergentes = 0 em todas as linhas.
--    Se houver divergente, alguém editou o registro depois da correção.
select b.channel,
       count(*)                                              as qtd,
       count(*) filter (where a.occurred_at =  b.created_at) as bateu_com_o_created_at,
       count(*) filter (where a.occurred_at <> b.created_at) as divergentes,
       count(*) filter (where a.id is null)                  as sumiram
  from public.bkp_occurred_futuro_20260828 b
  left join public.deal_activities a on a.id = b.id
 group by 1 order by 2 desc;


-- 3) ANTES x DEPOIS, DIA A DIA
--    A coluna data_antiga é onde o registro estava (errado); data_nova é onde
--    ele está agora. Confira se data_nova faz sentido como dia de trabalho.
select date(b.occurred_at at time zone 'America/Sao_Paulo') as data_antiga,
       date(a.occurred_at at time zone 'America/Sao_Paulo') as data_nova,
       b.channel,
       coalesce(p.full_name, '(sem autor)')                 as quem,
       count(*)                                             as qtd
  from public.bkp_occurred_futuro_20260828 b
  join public.deal_activities a on a.id = b.id
  left join public.profiles p   on p.id = b.author_id
 group by 1,2,3,4
 order by 2, 3, 5 desc;


-- 4) A HORA TAMBÉM FAZ SENTIDO?
--    Registro de contato deve cair em horário comercial. Se aparecer madrugada,
--    o created_at não é boa aproximação para aquele registro.
select date(a.occurred_at at time zone 'America/Sao_Paulo')            as dia,
       extract(hour from a.occurred_at at time zone 'America/Sao_Paulo') as hora,
       count(*)
  from public.bkp_occurred_futuro_20260828 b
  join public.deal_activities a on a.id = b.id
 where b.channel = 'telefone'
 group by 1,2 order by 1,2;


-- 5) COMO FICARAM AS LIGAÇÕES DO MÊS, POR DIA E POR QUEM DISCOU
--    É o que o gráfico "Ligações por dia" mostra agora.
select date(coalesce(a.occurred_at, a.created_at) at time zone 'America/Sao_Paulo') as dia,
       coalesce(p.full_name, '(sem autor)') as quem,
       count(*)                              as ligacoes,
       count(*) filter (where a.outcome = 'atendeu') as atendidas
  from public.deal_activities a
  left join public.profiles p on p.id = a.author_id
 where a.channel = 'telefone'
   and coalesce(a.occurred_at, a.created_at) >= date_trunc('month', now())
 group by 1,2 order by 1, 3 desc;


-- 6) A META DE HOJE, DEPOIS DE TUDO
--    Compare com o painel. Agora tem que bater.
with janela as (
  select (now() at time zone 'America/Sao_Paulo')::date as hoje
),
realizado as (
  select a.author_id as pid, count(*) as n
    from public.deal_activities a, janela j
   where a.channel = 'telefone'
     and (coalesce(a.occurred_at, a.created_at) at time zone 'America/Sao_Paulo')::date = j.hoje
   group by 1
)
select p.full_name,
       coalesce(r.n, 0) as ligacoes_hoje,
       m.valor          as meta_diaria,
       case when m.valor > 0 then round(100.0 * coalesce(r.n, 0) / m.valor, 1) end as pct
  from public.metas m
  join public.profiles p on p.id = m.owner_id
  left join realizado r  on r.pid = m.owner_id
 where m.indicador = 'ligacoes' and m.periodicidade = 'diaria' and m.valor > 0
 order by 2 desc;


-- =============================================================================
-- SE PRECISAR DESFAZER
-- =============================================================================
-- begin;
--   alter table public.deal_activities disable trigger trg_atividade_data_valida;
--   update public.deal_activities a
--      set occurred_at = b.occurred_at
--     from public.bkp_occurred_futuro_20260828 b
--    where a.id = b.id;
--   alter table public.deal_activities enable trigger trg_atividade_data_valida;
-- commit;
