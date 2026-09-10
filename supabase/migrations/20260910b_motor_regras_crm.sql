-- =====================================================================
-- MOTOR DE INTELIGÊNCIA — parte 2: motor de regras dentro do CRM
-- Aditiva. Não altera public.deals. Complementa 20260910_motor_inteligencia.sql.
--
-- Cria:  escard.intel_frases, escard.intel_objecoes (banco editável)
--        public.vw_intel_frases, public.vw_intel_objecoes, public.vw_intel_aprendizado
--        public.fn_intel_contexto(uuid)  -> tudo que o card precisa, em 1 chamada
--        public.fn_intel_feedback(...)   -> grava pitch + resultado num só passo
-- Ajusta: políticas de INSERT (admin também pode registrar feedback)
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. BANCO DE FRASES (editável no Supabase, sem redeploy do CRM)
--    arquetipo NULL  = vale para qualquer arquétipo
--    gatilho_tipo NULL = frase "por fit" (sem gatilho)
--    hook ou proposta podem vir vazios: o CRM escolhe cada um pela linha mais específica
--    Placeholders: {empresa} {decisor} {cidade} {sinal} {dias}
-- ---------------------------------------------------------------------
create table if not exists escard.intel_frases (
  id            uuid primary key default gen_random_uuid(),
  arquetipo     text,
  angulo        text not null check (angulo in ('dono','financeiro','rh')),
  gatilho_tipo  text check (gatilho_tipo in (
                  'expansao','captacao','vaga','lideranca','reclamacao_beneficio',
                  'dissidio','transporte','custo_logistico','tecnologia','outro')),
  hook          text,
  proposta      text,
  ativo         boolean not null default true,
  criado_em     timestamptz not null default now(),
  constraint intel_frases_conteudo check (hook is not null or proposta is not null)
);
create index if not exists idx_intel_frases_sel on escard.intel_frases (angulo, arquetipo, gatilho_tipo) where ativo;

create table if not exists escard.intel_objecoes (
  id         uuid primary key default gen_random_uuid(),
  arquetipo  text,
  objecao    text not null,
  resposta   text not null,
  ativo      boolean not null default true,
  criado_em  timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- 2. SEED — frases escritas dentro das regras travadas:
--    sem "grátis"/"sem custo"; PAT só como pergunta (regime desconhecido);
--    private label = crediário organizado, risco do lojista; voz/WhatsApp.
-- ---------------------------------------------------------------------
insert into escard.intel_frases (arquetipo, angulo, gatilho_tipo, hook, proposta) values
-- ===== Empregador puro =====
('Empregador puro','dono',null,'{decisor}, aqui é da Escard, em Vitória. Como vocês fazem hoje o vale-alimentação da equipe?',
 'A Escard é o cartão de benefício com rede local e gente que atende o telefone aqui no ES. Carga previsível, contrato claro, sem surpresa no boleto. Consigo passar aí 20 minutos esta semana para mostrar como fica para a sua equipe?'),
('Empregador puro','dono',null,'{decisor}, rapidinho: a equipe da {empresa} recebe vale em cartão ou ainda é em dinheiro?',
 'Cartão da Escard resolve o vale sem você ficar administrando envelope: carga mensal, funcionário usa no mercado do bairro, e você fala direto com a gente quando precisa. Posso mandar a proposta no seu WhatsApp e ligar amanhã para tirar dúvida?'),
('Empregador puro','dono',null,'{decisor}, sou da Escard. Quem cuida do benefício dos funcionários aí na {empresa}, é você mesmo?',
 'Trabalhamos com PME de {cidade} há anos: cartão alimentação com rede credenciada local e atendimento regional. Custo previsível e sem burocracia de multinacional. Vale uma visita de 20 minutos?'),
('Empregador puro','financeiro',null,'{decisor}, uma pergunta objetiva: a {empresa} está no Simples ou no Lucro Real?',
 'Se for Lucro Real, o vale-alimentação pelo PAT reduz até 4% do IRPJ devido — dá para colocar isso em número na proposta. Se for Simples, o ganho é operacional: carga única mensal em vez de folha e envelope. Me diz o regime que eu monto a conta certa.'),
('Empregador puro','financeiro',null,'{decisor}, quanto tempo a {empresa} gasta por mês administrando vale da equipe?',
 'Com a Escard vira uma carga mensal, um boleto, um relatório. Sem gestão de envelope e sem ligação para 0800. Posso mostrar a simulação com o número de funcionários de vocês?'),
('Empregador puro','rh',null,'{decisor}, a equipe da {empresa} reclama do vale que tem hoje, ou está tranquilo?',
 'Benefício em cartão com rede local costuma ser o item mais barato de retenção que existe: o funcionário sente no dia a dia. A Escard monta o pacote no tamanho da sua equipe. Marco 20 minutos para você ver as opções?'),
('Empregador puro','rh',null,'{decisor}, quantos CLT a {empresa} tem hoje? Pergunto porque temos plano para equipe pequena.',
 'Nossa carga mínima é baixa e a rede é a do bairro, não só shopping. Dá para começar com uma parte da equipe e crescer. Te mando a proposta por WhatsApp?'),

-- ===== Prestador de recorrência =====
('Prestador de recorrência','dono',null,'{decisor}, aqui é da Escard. Vocês têm equipe em campo e mandam vale para o pessoal?',
 'Para quem tem gente na rua, cartão com rede local em toda a Grande Vitória resolve alimentação e combustível no mesmo lugar. Carga previsível, atendimento aqui perto. Posso mostrar em 20 minutos?'),
('Prestador de recorrência','dono',null,'{decisor}, seus clientes pagam vocês mensalmente? A Escard organiza cobrança recorrente em cartão próprio.',
 'Contrato recorrente com atraso vira caixa preso. A gente coloca régua de cobrança, aviso automático e negativação quando precisa — a decisão continua sua. Vale 20 minutos para ver como fica?'),
('Prestador de recorrência','financeiro',null,'{decisor}, qual o percentual de inadimplência nos contratos recorrentes da {empresa}?',
 'Cobrança organizada com régua e negativação costuma recuperar parte do que hoje fica parado. Sem mexer no seu processo comercial. Me passa uma estimativa e eu volto com número na proposta.'),
('Prestador de recorrência','rh',null,'{decisor}, a equipe de campo da {empresa} recebe vale-alimentação ou combustível hoje?',
 'Cartão único para alimentação e combustível, com rede local, evita ter dois fornecedores. Carga mensal previsível. Mando a proposta no WhatsApp?'),

-- ===== Varejista =====
('Varejista','dono',null,'{decisor}, aqui é da Escard. A {empresa} vende a prazo, carnê ou crediário próprio?',
 'A gente transforma o seu crediário em cartão da própria loja: cliente compra no cartão da {empresa}, a régua de cobrança é nossa, a decisão de crédito continua sua. Fideliza e organiza. Posso passar aí para mostrar?'),
('Varejista','dono',null,'{decisor}, quanto do seu faturamento está parado em carnê atrasado hoje?',
 'Cartão private label da Escard coloca régua de cobrança, aviso automático e negativação por trás do seu crediário. Você para de correr atrás e o cliente volta para comprar. Vale 20 minutos na loja?'),
('Varejista','dono',null,'{decisor}, cliente da {empresa} que compra parcelado no cartão de banco é cliente do banco, não seu. Já pensou no cartão da loja?',
 'Com o cartão próprio, o histórico de compra fica com você, o limite é seu e a cobrança é organizada pela Escard. Sem maquininha intermediando o seu melhor cliente. Marco uma visita?'),
('Varejista','financeiro',null,'{decisor}, quanto a {empresa} paga de taxa na maquininha nas vendas parceladas?',
 'No cartão da própria loja você não paga taxa de crédito de adquirente e ainda organiza a cobrança. O risco continua seu, como já é no carnê hoje — só que com régua e negativação. Posso mostrar a conta com o volume de vocês?'),
('Varejista','rh',null,'{decisor}, a equipe da loja recebe vale-alimentação em cartão?',
 'Além do cartão da loja, a Escard fornece o vale da equipe com rede no bairro. Um fornecedor só, aqui de Vitória. Te mando as duas propostas?'),

-- ===== Varejo-empregador =====
('Varejo-empregador','dono',null,'{decisor}, aqui é da Escard. Vocês vendem a prazo e têm equipe CLT, certo? Dá para resolver os dois com a gente.',
 'Cartão da própria loja para o cliente, com cobrança organizada, e cartão alimentação para a equipe, tudo processado aqui em Vitória. Um fornecedor, um contato. Posso passar aí em 20 minutos?'),
('Varejo-empregador','dono',null,'{decisor}, o crediário da {empresa} ainda é carnê de papel?',
 'A Escard transforma o carnê em cartão da loja, com régua de cobrança e negativação. A decisão de crédito continua sua. E o vale da equipe entra no mesmo contrato. Vale uma visita?'),
('Varejo-empregador','financeiro',null,'{decisor}, quanto está parado em crediário atrasado e quanto vai de taxa de maquininha por mês?',
 'Os dois números caem com o cartão próprio da loja: sem MDR de crédito e com cobrança organizada. Me passa uma estimativa que eu volto com a conta.'),
('Varejo-empregador','rh',null,'{decisor}, quantos CLT tem na {empresa} hoje?',
 'Vale-alimentação com rede local para a equipe, no mesmo contrato do cartão da loja. Carga previsível e atendimento regional. Mando a proposta no WhatsApp?'),

-- ===== Genéricas (qualquer arquétipo) =====
(null,'dono',null,'{decisor}, aqui é da Escard, cartão de benefício e crediário com atendimento em Vitória. Posso te fazer duas perguntas rápidas?',
 'Trabalhamos com PME do ES: cartão alimentação com rede local e cartão de loja com cobrança organizada. Custo previsível e gente que atende. Vale 20 minutos?'),
(null,'financeiro',null,'{decisor}, uma pergunta direta: a {empresa} é Simples ou Lucro Real?',
 'Dependendo do regime, o benefício em cartão tem efeito fiscal (PAT, no Lucro Real) ou operacional (carga única no Simples). Me diz o regime e eu monto a conta certa para vocês.'),
(null,'rh',null,'{decisor}, a equipe da {empresa} tem benefício em cartão hoje?',
 'Benefício com rede local é o item de retenção mais barato que existe. A Escard monta no tamanho da sua equipe. Te mando a proposta?'),

-- ===== Hooks por gatilho (qualquer arquétipo; proposta vem da linha do arquétipo) =====
(null,'dono','expansao','{decisor}, vi que a {empresa} está expandindo — {sinal}. Quem vai cuidar do benefício da equipe nova?',null),
(null,'rh','expansao','{decisor}, vi a notícia da expansão da {empresa}. Equipe nova entrando já vem com vale em cartão?',null),
(null,'dono','captacao','{decisor}, vi que a {empresa} captou recurso — parabéns. Já pensaram em organizar o crediário e o benefício nessa fase?',null),
(null,'financeiro','captacao','{decisor}, com o aporte novo, faz sentido tirar taxa de maquininha e inadimplência do caminho. Posso mostrar a conta?',null),
(null,'rh','vaga','{decisor}, vi que a {empresa} está contratando. O pacote de benefício já está fechado para quem entra?',null),
(null,'dono','vaga','{decisor}, vi as vagas abertas da {empresa}. Vale em cartão com rede local ajuda a fechar contratação. Posso mostrar?',null),
(null,'rh','dissidio','{decisor}, o dissídio da categoria de vocês está chegando em {dias} dias. Já sabe se a convenção pede vale em cartão?',null),
(null,'dono','dissidio','{decisor}, dissídio de vocês vem em {dias} dias. Quer resolver o benefício antes de a convenção obrigar?',null),
(null,'dono','transporte','{decisor}, com o reajuste da passagem, o vale-transporte da {empresa} vai subir. Já viu o cartão de mobilidade da Escard?',null),
(null,'financeiro','transporte','{decisor}, a tarifa subiu — o custo de transporte da equipe vai junto. Posso mostrar como fica em cartão?',null),
(null,'dono','lideranca','{decisor}, vi que tem gente nova na direção da {empresa}. Boa hora para revisar fornecedor de benefício?',null),
(null,'dono','tecnologia','{decisor}, vi que a {empresa} está investindo em sistema. O benefício da equipe já entra nessa organização?',null),
(null,'dono','outro','{decisor}, vi a {empresa} no jornal essa semana — {sinal}. Aproveito para perguntar: como está o benefício da equipe?',null);

insert into escard.intel_objecoes (arquetipo, objecao, resposta) values
('Empregador puro','Já tenho VR / Alelo / Ticket.','Entendo. A diferença é quem atende quando dá problema: aqui é telefone de Vitória, não 0800. Posso só te mostrar o comparativo de custo?'),
('Empregador puro','Não tenho verba para benefício agora.','Não é gasto novo — é o mesmo vale que você já dá, em cartão. Se hoje não dá nada, começamos com uma carga pequena e você cresce depois.'),
('Prestador de recorrência','Meu pessoal é PJ, não tem vale.','Então a dor está na cobrança dos seus contratos, não no benefício. Posso te mostrar a régua de cobrança recorrente?'),
('Varejista','Meu cliente já paga no cartão de crédito.','E paga taxa de adquirente para isso, e o cliente vira do banco. No cartão da loja o histórico é seu e não tem MDR de crédito. Vale ver a conta?'),
('Varejista','Não quero assumir risco de crédito.','Você já assume no carnê hoje. A diferença é que com a Escard tem régua, aviso e negativação — o risco fica menor, não maior.'),
('Varejo-empregador','É muita coisa para mudar de uma vez.','Começa por um: cartão da loja ou vale da equipe. O segundo entra depois no mesmo contrato, quando fizer sentido.'),
(null,'Me manda por email.','Mando pelo WhatsApp agora e te ligo amanhã às 10 para tirar dúvida. Pode ser?'),
(null,'Não é comigo, fala com o RH / financeiro.','Perfeito. Qual o nome e o WhatsApp da pessoa? Digo que foi você quem indicou.');

-- ---------------------------------------------------------------------
-- 3. WRAPPERS PÚBLICOS (o CRM só fala com o schema public)
-- ---------------------------------------------------------------------
create or replace view public.vw_intel_frases as
  select id, arquetipo, angulo, gatilho_tipo, hook, proposta
  from escard.intel_frases where ativo;

create or replace view public.vw_intel_objecoes as
  select id, arquetipo, objecao, resposta
  from escard.intel_objecoes where ativo;

create or replace view public.vw_intel_aprendizado as
  select * from escard.vw_intel_aprendizado;

revoke all on public.vw_intel_frases, public.vw_intel_objecoes, public.vw_intel_aprendizado from anon;
grant select on public.vw_intel_frases, public.vw_intel_objecoes, public.vw_intel_aprendizado to authenticated;

-- ---------------------------------------------------------------------
-- 4. CONTEXTO DO DEAL — 1 chamada, tudo que o motor precisa
--    SECURITY DEFINER com checagem explícita de dono/admin: não exige
--    grants amplos em escard.* para a vendedora.
-- ---------------------------------------------------------------------
create or replace function public.fn_intel_contexto(p_deal_id uuid)
returns jsonb
language plpgsql stable security definer
set search_path = public, escard
as $$
declare
  d record; st record; c record; rf record; cct record;
  v_cnpj text; v_excluido boolean; v_sinais jsonb; v_dias int; v_alvo date;
begin
  if auth.uid() is null then return null; end if;   -- NULL <> x é NULL: bloquear explícito
  select id, cnpj, city, cnae, stage_changed_at, owner_id, contact_name
    into d from public.deals where id = p_deal_id;
  if not found then return null; end if;
  if not (d.owner_id = auth.uid() or public.is_admin()) then return null; end if;

  v_cnpj := regexp_replace(coalesce(d.cnpj,''), '\D', '', 'g');

  select name, is_won, is_lost into st from public.pipeline_stages s
   join public.deals dd on dd.stage_id = s.id where dd.id = p_deal_id;

  select tier, arquetipo, produto_entrada, faixa_func, setor_crediario, score, confianca
    into c from escard.deal_classificacao where deal_id = p_deal_id;

  select situacao_cadastral, matriz_filial, quantidade_funcionarios, socios
    into rf from escard.cnpj_dados where cnpj = v_cnpj;

  v_excluido := (v_cnpj = '58411199000120')
             or exists (select 1 from escard.exclusao_icp where cnpj = v_cnpj);

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', s.id, 'categoria', s.categoria, 'tipo', s.tipo, 'descricao', s.descricao,
           'fonte', s.fonte, 'url', s.url, 'data_evento', s.data_evento, 'peso', s.peso,
           'escopo', case when s.cnpj is not null then 'empresa'
                          when s.municipio is not null then 'regional' else 'setorial' end)), '[]'::jsonb)
    into v_sinais
    from escard.fn_sinais_do_deal(p_deal_id) s;

  v_dias := null;
  if d.cnae is not null then
    select mes_dissidio, sindicato, exige_va_vr, fonte into cct
      from escard.cct_calendario
     where cnae_divisao = left(regexp_replace(d.cnae,'\D','','g'),2)
       and uf = 'ES' and deleted_at is null;
    if found then
      v_alvo := make_date(extract(year from current_date)::int, cct.mes_dissidio, 1);
      if v_alvo < current_date then v_alvo := v_alvo + interval '1 year'; end if;
      v_dias := v_alvo - current_date;
    end if;
  end if;

  return jsonb_build_object(
    'deal_id', d.id,
    'cnpj', nullif(v_cnpj,''),
    'stage', st.name, 'is_won', coalesce(st.is_won,false), 'is_lost', coalesce(st.is_lost,false),
    'perdido_ha_dias', case when coalesce(st.is_lost,false) and d.stage_changed_at is not null
                            then (current_date - d.stage_changed_at::date) else null end,
    'tier', c.tier, 'arquetipo', c.arquetipo, 'produto_entrada', c.produto_entrada,
    'faixa_func', c.faixa_func, 'setor_crediario', c.setor_crediario, 'score_icp', c.score, 'confianca', c.confianca,
    'situacao_cadastral', rf.situacao_cadastral, 'matriz_filial', rf.matriz_filial,
    'qtd_funcionarios_rf', rf.quantidade_funcionarios,
    'socio', nullif(split_part(coalesce(rf.socios,''), ',', 1), ''),
    'excluido', v_excluido,
    'sinais', v_sinais,
    'cct', case when v_dias is null then null else jsonb_build_object(
              'dias', v_dias, 'sindicato', cct.sindicato, 'exige_va_vr', cct.exige_va_vr, 'fonte', cct.fonte) end
  );
end;
$$;
revoke all on function public.fn_intel_contexto(uuid) from public, anon;
grant execute on function public.fn_intel_contexto(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- 5. FEEDBACK — grava o pitch mostrado + o resultado, num só passo
-- ---------------------------------------------------------------------
create or replace function public.fn_intel_feedback(
  p_deal_id uuid, p_angulo text, p_canal text, p_resultado text, p_objecao text,
  p_payload jsonb, p_health int, p_fit int, p_timing int, p_acesso int,
  p_segmento text, p_produto text, p_sinais uuid[]
) returns uuid
language plpgsql security definer
set search_path = public, escard
as $$
declare v_owner uuid; v_cnpj text; v_pitch uuid; v_fb uuid;
begin
  if auth.uid() is null then raise exception 'não autenticado'; end if;
  select owner_id, regexp_replace(coalesce(cnpj,''),'\D','','g') into v_owner, v_cnpj
    from public.deals where id = p_deal_id;
  if not found then raise exception 'deal não encontrado'; end if;
  if not (v_owner = auth.uid() or public.is_admin()) then raise exception 'sem permissão'; end if;
  if p_resultado = 'objecao' and coalesce(trim(p_objecao),'') = '' then raise exception 'objeção exige texto'; end if;

  insert into escard.intel_pitch (deal_id, cnpj, versao_prompt, health_score, score_fit, score_timing, score_acesso,
                                  segmento, produto_recomendado, payload, sinais_ids, modelo)
  values (p_deal_id, nullif(v_cnpj,''), 'regras-v1', greatest(0, least(100, p_health)), p_fit, p_timing, p_acesso,
          p_segmento, p_produto, p_payload, coalesce(p_sinais, '{}'), 'regras')
  returning id into v_pitch;

  insert into escard.intel_feedback (pitch_id, deal_id, angulo_usado, canal, resultado, objecao, registrado_por)
  values (v_pitch, p_deal_id, p_angulo, p_canal, p_resultado, nullif(trim(p_objecao),''), auth.uid())
  returning id into v_fb;

  return v_fb;
end;
$$;
revoke all on function public.fn_intel_feedback(uuid,text,text,text,text,jsonb,int,int,int,int,text,text,uuid[]) from public, anon;
grant execute on function public.fn_intel_feedback(uuid,text,text,text,text,jsonb,int,int,int,int,text,text,uuid[]) to authenticated;

-- ---------------------------------------------------------------------
-- 6. RLS — leitura do feedback/pitch também para admin (já havia); tabelas novas
-- ---------------------------------------------------------------------
alter table escard.intel_frases   enable row level security;
alter table escard.intel_objecoes enable row level security;
revoke all on escard.intel_frases, escard.intel_objecoes from anon, authenticated;
-- (leitura só pelas views públicas; edição pelo SQL Editor / service role)

-- grants extras (MCP roda como supabase_read_only_user; service_role para o Worker)
grant execute on function public.fn_intel_contexto(uuid) to service_role, postgres, supabase_read_only_user;
grant execute on function public.fn_intel_feedback(uuid,text,text,text,text,jsonb,int,int,int,int,text,text,uuid[]) to service_role, postgres;
grant select on public.vw_intel_frases, public.vw_intel_objecoes, public.vw_intel_aprendizado to service_role;
