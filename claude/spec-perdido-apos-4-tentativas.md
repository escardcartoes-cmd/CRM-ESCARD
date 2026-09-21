# Especificação — Perdido após 4 tentativas sem resposta

Migration: `supabase/migrations/20260921_0041_perdido_apos_4_tentativas.sql` (aplicada em produção 21/09)
Frontend: `index.html`

## Regra
| Item | Decisão |
|---|---|
| O que conta | registro de **telefone, WhatsApp ou e-mail** sem contato efetivo |
| Janela | tentativas **consecutivas** desde o último contato efetivo (atendeu, respondeu, realizada, reunião agendada/realizada) |
| Não conta | nota, presencial |
| Gatilho | 4ª tentativa → etapa **Perdidos**, motivo **"Sem resposta"**, sem follow-up |
| Etapas onde age | Leads Novos, Sem Contato, Contato Feito. Reunião/Negociação seguem a régua de 5 toques |
| Crédito | movimento gravado como `sistema` — não entra em meta de ninguém |
| Volta | não volta sozinho; reabrir é decisão de gente |

## Por que no banco
Trigger `trg_perdido_por_tentativas` em `deal_activities`. O front lança atividade por três telas; regra no front diverge. O front só **relê a etapa** depois de salvar para avisar o SDR e sincronizar o modal aberto.

## Front
- Prévia no registro: "4ª tentativa sem resposta — ao salvar, o lead vai para Perdidos".
- Após salvar, relê `deals.stage_id`; se virou Perdidos: não agenda régua, atualiza cache, e se o modal do lead estiver aberto ajusta etapa/motivo/follow-up — senão o próximo "Salvar" reverteria o lead.
- `tentativasConsecutivas` passou a contar igual ao banco (só 3 canais; reunião agendada zera).

## Trava extra
`fn_deal_terminal_sem_followup` agora anula `next_followup_date` e `cadencia_esgotada_em` em **qualquer** update de lead terminal, não só na troca de etapa.

## Backfill
155 leads movidos (backup `bkp_0041_perdido_tentativas`): 130 Sem Contato, 15 Contato Feito, 10 Leads Novos · 141 Ludmylla, 14 Heloísa.

## QA
- [x] Teste em produção com rollback forçado: atendeu → Contato Feito; nota não conta; 3 tentativas mantêm; 4ª → Perdidos, motivo "Sem resposta", histórico `sistema`; front gravando follow-up/esgotada depois é anulado
- [x] `node --check` nos 4 blocos; 4 testes da contagem
- [ ] Manual no preview: lead de "Sem Contato" com 3 tentativas → registrar a 4ª com o modal aberto → toast, etapa Perdidos no select, "Salvar" do modal não reverte
