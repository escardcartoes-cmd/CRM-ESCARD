-- 0043 — Conteúdo do Motor de Inteligência para PARCEIROS de canal
-- (contabilidade e seguros). Inerte até a 0044: nenhum deal tem estes arquétipos
-- antes dela. Idempotente: apaga e reinsere só as linhas dos dois arquétipos.
-- Fonte de verdade de "é parceiro": escard.fn_marcar_parceiros (lista_origem PARCEIRO · …).

begin;

insert into escard.regras_arquetipo (arquetipo, produtos, produto_entrada, cross_sell, pot_ben, pot_priv, pot_cob, gancho, atualizado_em, produto_roadmap)
values
 ('Canal contábil', 'Parceria de indicação', 'Parceria', 'Benefícios para as empresas indicadas', 'N/A', 'N/A', 'N/A',
  'Não é cliente final: o escritório indica a própria carteira e ganha por empresa que entra.', now(), null),
 ('Canal seguros', 'Parceria de indicação', 'Parceria', 'Benefícios para as empresas da carteira', 'N/A', 'N/A', 'N/A',
  'Não é cliente final: a corretora leva o benefício ao RH que já atende e ganha por empresa que entra.', now(), null)
on conflict (arquetipo) do update set
  produtos = excluded.produtos, produto_entrada = excluded.produto_entrada, cross_sell = excluded.cross_sell,
  pot_ben = excluded.pot_ben, pot_priv = excluded.pot_priv, pot_cob = excluded.pot_cob,
  gancho = excluded.gancho, atualizado_em = now();

delete from escard.intel_roteiro     where arquetipo in ('Canal contábil','Canal seguros');
delete from escard.intel_argumentos  where arquetipo in ('Canal contábil','Canal seguros');
delete from escard.intel_objecoes    where arquetipo in ('Canal contábil','Canal seguros');
delete from escard.intel_consultivo  where arquetipo in ('Canal contábil','Canal seguros');

-- Roteiro. A abertura herda do genérico o "Cumprimento + licença" (1) e o "NUNCA abra assim" (9);
-- os demais blocos são exclusivos (o front não mistura o genérico, que é de venda direta).
with r(arq, bloco, ordem, rotulo, fala, nota) as (values
 -- ===== Contabilidade =====
 ('Canal contábil','recepcao',1,'Pedir ajuda, não o responsável',
  'Oi, bom dia! Aqui é a [seu nome], da Escard, aqui de Vitória. Deixa eu te pedir uma ajuda: quem é o sócio aí do escritório, que cuida da relação com os clientes?',
  'Em escritório contábil quem fecha parceria é o sócio, não o DP. Saia com o nome dele.'),
 ('Canal contábil','recepcao',2,'Se ela perguntar do que se trata',
  'É uma parceria para o escritório — não é venda de nada para vocês não, viu? Só queria saber com quem eu falo, para não te fazer perder tempo.', null),
 ('Canal contábil','recepcao',3,'Se mandar e-mail',
  'E-mail meu se perde no meio de tanta coisa. Me diz só o melhor horário que eu ligo na hora certa.', null),
 ('Canal contábil','recepcao',4,'NUNCA desligue sem um nome', null,
  'Nome do sócio é resultado, mesmo sem falar com ele. Amanhã você liga pedindo pela pessoa e já não é estranha.'),

 ('Canal contábil','abertura',2,'Parceria, não venda + pergunta + SILÊNCIO',
  'Vou ser rápida e direta: não estou ligando para vender nada para o escritório. A gente cuida de cartão de benefício aqui do ES — alimentação, combustível, farmácia — e trabalha com contador como parceiro: vocês indicam, a gente faz todo o resto, e o escritório ganha em cima de cada empresa que entrar. Hoje, quando um cliente pergunta de benefício para funcionário, vocês mandam para quem?',
  'Conte até quatro. O contador já é consultado sobre isso e não ganha nada. Esse é o ponto — não o cartão.'),
 ('Canal contábil','abertura',8,'NUNCA com parceiro', null,
  '"quantos funcionários vocês têm?" · oferecer cartão para o próprio escritório · falar de rede e taxa antes do ganho dele. Contador que se sente alvo de venda desliga; o que se sente parceiro escuta.'),

 ('Canal contábil','descobrir',1,'1. Tamanho da carteira',
  'E hoje o escritório atende mais ou menos quantas empresas? Dessas, quantas têm funcionário registrado?',
  'É o número que define o parceiro. Se hesitar: "não precisa ser exato não, só para eu ter uma ideia."'),
 ('Canal contábil','descobrir',2,'2. O que acontece hoje — a mais importante',
  'E quando cliente pergunta de VA, VR, cartão de benefício, o que vocês fazem hoje?',
  'Escute até o fim. Se ele já indica alguém, ele já faz o trabalho — só não recebe por isso. Devolva COM A PALAVRA DELE.'),
 ('Canal contábil','descobrir',3,'3. Já tem parceria',
  'Vocês já têm alguma parceria dessas, com banco ou operadora, que paga por indicação?',
  'Se tiver, não ataque. Pergunte o que ele acha que falta nela.'),
 ('Canal contábil','descobrir',4,'4. Quem fala com o cliente',
  'E quem aí conversa com o cliente sobre folha — é você ou o pessoal do DP?',
  'O DP é quem indica no dia a dia. Precisa estar na reunião.'),
 ('Canal contábil','descobrir',5,'5. Quem decide',
  'E uma parceria dessas você fecha sozinho ou tem sócio que gosta de participar?',
  '"Gosta de participar" é melhor que "precisa aprovar" — não diminui ele.'),
 ('Canal contábil','descobrir',6,'Regra de ouro', null,
  'Parceiro não é cliente. Você não está vendendo cartão para ele: está mostrando como ele ganha com o que já faz.'),

 ('Canal contábil','fechar',1,'Convite com pauta e duas opções',
  '[Nome], pelo que você me contou faz sentido a gente sentar quinze minutinhos. Eu levo três coisas prontas: como a indicação funciona na prática, como o escritório ganha por empresa que entra, e o pouco que a gente precisa da sua parte. Quinta de manhã ou sexta à tarde, o que te atende melhor?',
  'Duração + pauta + DUAS opções. Peça para o DP participar.'),
 ('Canal contábil','fechar',2,'Se pedir material',
  'Mando com prazer. Mas material não mostra o que interessa, que é quanto a SUA carteira rende. Mando junto com o horário marcado — quinta ou sexta?', null),
 ('Canal contábil','fechar',3,'NUNCA termine com', null,
  '"vou te mandar um material" · "depois te ligo" · "qualquer coisa me chama". É exatamente aí que o parceiro esfria.'),

 ('Canal contábil','cerca',1,'Se perguntar quanto ganha',
  'O escritório ganha em cima de cada empresa que entrar — no fechamento e todo mês enquanto ela usar. Quanto, depende do tamanho de cada cliente; quem mostra é a tabela, com os seus clientes na mão. É para isso que servem os quinze minutos.',
  'Não fale percentual, não estime valor. Número dito no telefone vira promessa cobrada depois.'),
 ('Canal contábil','cerca',2,'Nunca, mesmo que ele insista', null,
  'Percentual de comissão · valor por cliente · exclusividade de região · prazo de pagamento · contrato de parceria por telefone.'),

 ('Canal contábil','porta',1,'Não tenho tempo para vender cartão',
  'Nem precisa, e é justamente isso. Você não vende nada: passa o nome, a gente liga, apresenta, implanta e dá suporte. É o que você já faz quando o cliente pergunta — só que agora ganhando. Quantos te perguntaram disso este ano?',
  'Fórmula: concordo com o sentimento → fato novo → devolvo uma pergunta.'),
 ('Canal contábil','porta',2,'Não quero expor meu cliente',
  'Faz todo sentido, cliente é o patrimônio do escritório. A gente só liga para quem você autorizar, e sabe que se der problema é o seu nome que aparece. Quer ver na reunião como é feito o primeiro contato?',
  'Não prometa formato de contato por telefone: isso se combina na reunião.'),
 ('Canal contábil','porta',3,'Já indico outra operadora',
  'Que bom, então você já sabe que funciona. Minha pergunta: o cliente pequeno, de cinco, dez funcionários, é bem atendido por ela? É esse que costuma ficar sem ninguém.',
  'Não ataque o concorrente. Ache o buraco da carteira dele.'),
 ('Canal contábil','porta',4,'Preciso ver com meu sócio',
  'Ótimo, é bom mesmo decidir junto. Marca os três então, mesmos quinze minutos. Quando ele costuma estar disponível?', null),
 ('Canal contábil','porta',5,'Vou pensar',
  'Pensa com calma. Só para eu não ficar te ligando à toa: o que você vai querer avaliar melhor? Se for como funciona, a reunião é justamente para isso; se for prioridade, a gente marca direto para o mês que vem.', null),
 ('Canal contábil','porta',6,'Estou ocupado agora',
  'Imagino, desculpa. Amanhã de manhã ou à tarde é melhor?', 'Marque. Não desligue no vago.'),
 ('Canal contábil','porta',7,'Ríspido ou irritado',
  'Desculpa incomodar, [nome]. Bom dia para você.', 'Encerre bem. Você volta em três meses. Quem discute não volta.'),

 -- ===== Seguros =====
 ('Canal seguros','recepcao',1,'Pedir ajuda, não o responsável',
  'Oi, bom dia! Aqui é a [seu nome], da Escard, aqui de Vitória. Deixa eu te pedir uma ajuda: quem é o dono da corretora, ou o corretor que cuida das empresas?',
  'Em corretora pequena o dono é o corretor. Saia com o nome dele.'),
 ('Canal seguros','recepcao',2,'Se ela perguntar do que se trata',
  'É uma parceria para a corretora — não é venda de nada para vocês não, viu? Só queria saber com quem eu falo, para não te fazer perder tempo.', null),
 ('Canal seguros','recepcao',3,'Se mandar e-mail',
  'E-mail meu se perde no meio de tanta coisa. Me diz só o melhor horário que eu ligo na hora certa.', null),
 ('Canal seguros','recepcao',4,'NUNCA desligue sem um nome', null,
  'Nome do corretor é resultado, mesmo sem falar com ele. Amanhã você liga pedindo pela pessoa e já não é estranha.'),

 ('Canal seguros','abertura',2,'Parceria, não venda + pergunta + SILÊNCIO',
  'Vou ser rápida e direta: não estou ligando para vender nada para a corretora. A gente cuida de cartão de benefício aqui do ES — alimentação, combustível, farmácia — e trabalha com corretor como parceiro: você leva para as empresas que já atende, a gente implanta e dá suporte, e a corretora ganha em cima de cada empresa que entrar. Quando o RH de um cliente seu pergunta de VA ou VR, você tem o que oferecer?',
  'Conte até quatro. Corretor já tem a porta do RH aberta. Benefício é mais um produto na mesma visita.'),
 ('Canal seguros','abertura',8,'NUNCA com parceiro', null,
  '"quer fazer um cartão para a corretora?" · explicar a operadora antes de falar do ganho dele · comparar com seguro. Corretor vive de carteira: fale de carteira.'),

 ('Canal seguros','descobrir',1,'1. Carteira empresarial',
  'E hoje sua carteira empresarial tem mais ou menos quantas empresas? E de que tamanho, em funcionário?',
  'É o número que define o parceiro. Se hesitar: "não precisa ser exato não, só para eu ter uma ideia."'),
 ('Canal seguros','descobrir',2,'2. O que vende hoje — a mais importante',
  'O que você mais vende para empresa hoje? E quando o RH pede benefício, o que você faz?',
  'Se ele manda para outro lugar, está deixando comissão na mesa. Devolva COM A PALAVRA DELE.'),
 ('Canal seguros','descobrir',3,'3. Já tem parceria',
  'Você já tem alguma parceria dessas, com banco ou operadora, que paga por indicação?',
  'Se tiver, não ataque. Pergunte o que ele acha que falta nela.'),
 ('Canal seguros','descobrir',4,'4. Quando ele visita',
  'E você costuma encontrar esses clientes quando — só na renovação, ou ao longo do ano?',
  'Renovação é a janela natural. Anote o mês das próximas.'),
 ('Canal seguros','descobrir',5,'5. Quem decide',
  'E uma parceria dessas você fecha sozinho ou tem sócio que gosta de participar?',
  '"Gosta de participar" é melhor que "precisa aprovar" — não diminui ele.'),
 ('Canal seguros','descobrir',6,'Regra de ouro', null,
  'Parceiro não é cliente. Você não está vendendo cartão para ele: está mostrando como ele ganha com o que já faz.'),

 ('Canal seguros','fechar',1,'Convite com pauta e duas opções',
  '[Nome], pelo que você me contou faz sentido a gente sentar quinze minutinhos. Eu levo três coisas prontas: como o benefício entra na visita que você já faz, como a corretora ganha por empresa que entra, e o pouco que a gente precisa da sua parte. Quinta de manhã ou sexta à tarde, o que te atende melhor?',
  'Duração + pauta + DUAS opções. Nunca "quando você pode".'),
 ('Canal seguros','fechar',2,'Se pedir material',
  'Mando com prazer. Mas material não mostra o que interessa, que é quanto a SUA carteira rende. Mando junto com o horário marcado — quinta ou sexta?', null),
 ('Canal seguros','fechar',3,'NUNCA termine com', null,
  '"vou te mandar um material" · "depois te ligo" · "qualquer coisa me chama". É exatamente aí que o parceiro esfria.'),

 ('Canal seguros','cerca',1,'Se perguntar quanto ganha',
  'A corretora ganha em cima de cada empresa que entrar — no fechamento e todo mês enquanto ela usar. Quanto, depende do tamanho de cada cliente; quem mostra é a tabela, com os seus clientes na mão. É para isso que servem os quinze minutos.',
  'Não fale percentual, não estime valor. Número dito no telefone vira promessa cobrada depois.'),
 ('Canal seguros','cerca',2,'Nunca, mesmo que ele insista', null,
  'Percentual de comissão · valor por cliente · exclusividade de região · prazo de pagamento · contrato de parceria por telefone.'),

 ('Canal seguros','porta',1,'Benefício não é meu ramo',
  'Entendo, seguro é outro produto. Mas quem compra é o mesmo RH que você já atende, na mesma conversa. Você não precisa entender de cartão: apresenta, e a gente faz o resto. Quantas empresas você visita por mês?',
  'Fórmula: concordo com o sentimento → fato novo → devolvo uma pergunta.'),
 ('Canal seguros','porta',2,'Não quero expor meu cliente',
  'Faz todo sentido, cliente é o patrimônio da corretora. A gente só fala com quem você autorizar, e sabe que se der problema é o seu nome que aparece. Quer ver na reunião como é feito o primeiro contato?',
  'Não prometa formato de contato por telefone: isso se combina na reunião.'),
 ('Canal seguros','porta',3,'Já indico outra operadora',
  'Que bom, então você já sabe que funciona. Minha pergunta: o cliente pequeno, de cinco, dez funcionários, é bem atendido por ela? É esse que costuma ficar sem ninguém.',
  'Não ataque o concorrente. Ache o buraco da carteira dele.'),
 ('Canal seguros','porta',4,'Preciso ver com meu sócio',
  'Ótimo, é bom mesmo decidir junto. Marca os três então, mesmos quinze minutos. Quando ele costuma estar disponível?', null),
 ('Canal seguros','porta',5,'Vou pensar',
  'Pensa com calma. Só para eu não ficar te ligando à toa: o que você vai querer avaliar melhor? Se for como funciona, a reunião é justamente para isso; se for prioridade, a gente marca direto para o mês que vem.', null),
 ('Canal seguros','porta',6,'Estou ocupado agora',
  'Imagino, desculpa. Amanhã de manhã ou à tarde é melhor?', 'Marque. Não desligue no vago.'),
 ('Canal seguros','porta',7,'Ríspido ou irritado',
  'Desculpa incomodar, [nome]. Bom dia para você.', 'Encerre bem. Você volta em três meses. Quem discute não volta.')
)
insert into escard.intel_roteiro (bloco, arquetipo, ordem, rotulo, fala, nota)
select bloco, arq, ordem, rotulo, fala, nota from r;

insert into escard.intel_consultivo (arquetipo, cnae_divisao, padrao, ja_tentaram, o_que_muda, pergunta) values
 ('Canal contábil', '69',
  'O cliente pergunta de benefício ao contador, e o contador indica alguém de graça ou manda procurar o banco.',
  'Parceria com banco ou operadora grande, que paga pouco, atende mal a empresa pequena e some depois da venda.',
  'Operação daqui do ES, que atende o cliente de cinco funcionários e paga o escritório pelo que ele já faz.',
  'Se você somar, quantos clientes te perguntaram de benefício este ano — e quantos você mandou para alguém sem ganhar nada?'),
 ('Canal seguros', '66',
  'Corretora vive de renovação e precisa de motivo para visitar o RH fora dela.',
  'Revender benefício de operadora grande, onde corretor pequeno tem pouco suporte.',
  'Um produto para levar na mesma visita, com suporte local e ganho no fechamento e na recorrência.',
  'Na sua carteira, quantas empresas você só vê na renovação — e o que você leva para elas no meio do ano?');

insert into escard.intel_argumentos (arquetipo, produto, ordem, titulo, fala, se_ja_tem, quando, momento) values
 ('Canal contábil','Parceria',1,'Como funciona a indicação',
  'Você me passa o nome da empresa e de quem falar, com a sua autorização. A gente liga em nome da parceria, apresenta, implanta e dá o suporte. Você acompanha tudo e não vende nada.',
  'Se já indica alguém: então é só passar a mandar para quem te paga por isso.', 'Primeira coisa da reunião.', 'reuniao'),
 ('Canal contábil','Parceria',2,'Como o escritório ganha',
  'Cada empresa que entrar gera ganho para o escritório no fechamento e todo mês enquanto usar. Vamos fazer a conta na tabela com três clientes seus.',
  null, 'Depois que ele entendeu que não precisa vender.', 'reuniao'),
 ('Canal contábil','Parceria',3,'O que o cliente dele leva',
  'Para o seu cliente é benefício com rede aqui do ES e suporte local — e o DP de vocês para de ser o balcão de reclamação de cartão.',
  null, 'Quando ele perguntar se o cliente vai gostar.', 'reuniao'),
 ('Canal contábil','Parceria',4,'Primeira lista',
  'Para começar, me passa três clientes que já te perguntaram de benefício. A gente faz esses três juntos e você vê como é antes de mandar mais.',
  null, 'Fechamento da reunião. Saia com nomes, não com promessa.', 'reuniao'),
 ('Canal seguros','Parceria',1,'Como funciona a indicação',
  'Você apresenta na visita que já faz, ou me passa o nome de quem falar, com a sua autorização. A gente implanta e dá o suporte. Você acompanha tudo e não precisa entender de cartão.',
  'Se já indica alguém: então é só passar a mandar para quem te paga por isso.', 'Primeira coisa da reunião.', 'reuniao'),
 ('Canal seguros','Parceria',2,'Como a corretora ganha',
  'Cada empresa que entrar gera ganho para a corretora no fechamento e todo mês enquanto usar. Vamos fazer a conta na tabela com três clientes seus.',
  null, 'Depois que ele entendeu que não precisa virar especialista em cartão.', 'reuniao'),
 ('Canal seguros','Parceria',3,'O que ele ganha além da comissão',
  'Para o seu cliente é benefício com rede aqui do ES e suporte local — e para você, um motivo para visitar o RH fora da renovação.',
  null, 'Quando ele perguntar por que o cliente compraria.', 'reuniao'),
 ('Canal seguros','Parceria',4,'Primeira lista',
  'Para começar, me passa três empresas com renovação mais perto. A gente faz essas três juntos e você vê como é antes de levar para o resto.',
  null, 'Fechamento da reunião. Saia com nomes, não com promessa.', 'reuniao');

insert into escard.intel_objecoes (arquetipo, objecao, resposta) values
 ('Canal contábil', 'Não quero me envolver com venda',
  'Não precisa. Você indica o nome; contato, implantação e suporte são nossos. O escritório só recebe.'),
 ('Canal seguros', 'Benefício não é meu produto',
  'Quem compra é o mesmo RH que você já atende. Você apresenta na visita que já faz; implantação e suporte são nossos.');

commit;

-- ===== Conferência (rodar separado) =====
-- select arquetipo, bloco, count(*) from escard.intel_roteiro where arquetipo like 'Canal %' group by 1,2 order by 1,2;
-- esperado: por arquétipo → abertura 2, cerca 2, descobrir 6, fechar 3, porta 7, recepcao 4

-- ===== Rollback (rodar separado, só se precisar) =====
-- delete from escard.intel_roteiro    where arquetipo in ('Canal contábil','Canal seguros');
-- delete from escard.intel_argumentos where arquetipo in ('Canal contábil','Canal seguros');
-- delete from escard.intel_objecoes   where arquetipo in ('Canal contábil','Canal seguros');
-- delete from escard.intel_consultivo where arquetipo in ('Canal contábil','Canal seguros');
-- delete from escard.regras_arquetipo where arquetipo in ('Canal contábil','Canal seguros');  -- só depois de reverter a 0044
