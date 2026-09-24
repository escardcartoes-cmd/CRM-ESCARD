-- 0044 — ATIVA o arquétipo de parceiro no classificador.
-- Rodar SÓ DEPOIS do index.html com INTEL_ARQ_CANAL estar em produção
-- (com o front antigo o roteiro do parceiro sairia misturado com o genérico de cobrança).
--
-- O que muda em escard.fn_classificar_deals (4 trocas pontuais, conferidas uma a uma):
--   1. lê deals.lista_origem
--   2. lista_origem 'PARCEIRO · Contabilidade' → 'Canal contábil'; 'PARCEIRO · Seguros' → 'Canal seguros'
--      (fonte única de "é parceiro": escard.fn_marcar_parceiros; Descarte continua Descarte)
--   3. tier do parceiro = 'A' (fit 40), inclusive sem CNPJ enriquecido
--   4. rota do parceiro = 'Parceria'

do $$
declare
  v_def text;
  t text[][] := array[
    array['select d.id as deal_id, d.cnpj,',
          'select d.id as deal_id, d.lista_origem, d.cnpj,'],
    array['select f.*, rc.arquetipo,',
          'select f.*, case when coalesce(rc.arquetipo,'''') <> ''Descarte'' and f.lista_origem = ''PARCEIRO · Contabilidade'' then ''Canal contábil'' when coalesce(rc.arquetipo,'''') <> ''Descarte'' and f.lista_origem = ''PARCEIRO · Seguros'' then ''Canal seguros'' else rc.arquetipo end as arquetipo,'],
    array['case when origem_dados=''sem_dados'' then null',
          'case when arquetipo like ''Canal %'' then ''A'' when origem_dados=''sem_dados'' then null'],
    array['case faixa_func when ''1-10'' then ''Canal/self-service''',
          'case when arquetipo like ''Canal %'' then ''Parceria'' else case faixa_func when ''1-10'' then ''Canal/self-service''']
  ];
  i int; n int;
begin
  v_def := pg_get_functiondef('escard.fn_classificar_deals(integer)'::regprocedure);
  if position('Canal contábil' in v_def) > 0 then
    raise notice '0044 já aplicada — nada a fazer';
    return;
  end if;
  for i in 1 .. array_length(t, 1) loop
    n := (length(v_def) - length(replace(v_def, t[i][1], ''))) / length(t[i][1]);
    if n <> 1 then raise exception '0044: troca % encontrou % ocorrências (esperado 1)', i, n; end if;
    v_def := replace(v_def, t[i][1], t[i][2]);
  end loop;
  -- fecha o case aninhado da rota
  n := (length(v_def) - length(replace(v_def, 'else ''Verificar porte'' end,', ''))) / length('else ''Verificar porte'' end,');
  if n <> 1 then raise exception '0044: fecho da rota encontrou % ocorrências', n; end if;
  v_def := replace(v_def, 'else ''Verificar porte'' end,', 'else ''Verificar porte'' end end,');
  execute v_def;
end $$;

-- reclassifica agora e atualiza a priorização (o cron faria em até 15 min)
select escard.fn_cron_reclassificar();

-- ===== Conferência (rodar separado) =====
-- select d.lista_origem, c.arquetipo, c.tier, c.rota, count(*)
--   from public.deals d join escard.deal_classificacao c on c.deal_id = d.id
--  where d.lista_origem like 'PARCEIRO%' group by 1,2,3,4 order by 1,5 desc;
-- esperado: Contabilidade → Canal contábil / A / Parceria; Seguros → Canal seguros / A / Parceria
--           (as poucas com arquétipo Descarte seguem Descarte)
-- select arquetipo, count(*) from escard.deal_classificacao group by 1 order by 2 desc;  -- demais arquétipos só perdem os parceiros

-- ===== Rollback (rodar separado, só se precisar) =====
-- do $$
-- declare v_def text;
-- begin
--   v_def := pg_get_functiondef('escard.fn_classificar_deals(integer)'::regprocedure);
--   v_def := replace(v_def, 'select d.id as deal_id, d.lista_origem, d.cnpj,', 'select d.id as deal_id, d.cnpj,');
--   v_def := replace(v_def, 'select f.*, case when coalesce(rc.arquetipo,'''') <> ''Descarte'' and f.lista_origem = ''PARCEIRO · Contabilidade'' then ''Canal contábil'' when coalesce(rc.arquetipo,'''') <> ''Descarte'' and f.lista_origem = ''PARCEIRO · Seguros'' then ''Canal seguros'' else rc.arquetipo end as arquetipo,', 'select f.*, rc.arquetipo,');
--   v_def := replace(v_def, 'case when arquetipo like ''Canal %'' then ''A'' when origem_dados=''sem_dados'' then null', 'case when origem_dados=''sem_dados'' then null');
--   v_def := replace(v_def, 'case when arquetipo like ''Canal %'' then ''Parceria'' else case faixa_func when ''1-10'' then ''Canal/self-service''', 'case faixa_func when ''1-10'' then ''Canal/self-service''');
--   v_def := replace(v_def, 'else ''Verificar porte'' end end,', 'else ''Verificar porte'' end,');
--   execute v_def;
-- end $$;
-- select escard.fn_cron_reclassificar();
