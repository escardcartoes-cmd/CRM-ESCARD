-- 0054 — CNPJ que perdeu o zero à esquerda na importação (Excel grava número).
-- Ex.: SPELTA 9199443000128 -> 09.199.443/0001-28. Só corrige quem, completado
-- até 14 dígitos, passa no dígito verificador. CPF (11 díg.) não é tocado.
-- Alcance medido em 24/09/2026: 2.219 deals (13 díg.: 2.101 · 12: 116 · 10: 2).
-- Rodar cada seção SEPARADA, na ordem. Nunca rodar a seção 4 junto com a 2.

-- ============ SEÇÃO 1 — BACKUP (0054a) ============
create table if not exists public.bkp_0054_cnpj_zero as
select id, cnpj, updated_at, now() as backup_em
from public.deals
where length(regexp_replace(coalesce(cnpj,''),'\D','','g')) in (10,12,13);
alter table public.bkp_0054_cnpj_zero enable row level security;
revoke all on public.bkp_0054_cnpj_zero from anon, authenticated;

-- ============ SEÇÃO 2 — CORREÇÃO (0054) ============
alter table public.deals disable trigger deals_set_updated_at; -- não mexe em updated_at
with p as (
  select id, lpad(regexp_replace(cnpj,'\D','','g'),14,'0') c
  from public.deals
  where length(regexp_replace(coalesce(cnpj,''),'\D','','g')) in (10,12,13)
), v as (
  select id, c from p
  where c !~ '^(\d)\1{13}$'
    and (select case when s%11<2 then 0 else 11-s%11 end
           from (select sum(substr(c,i,1)::int*(array[5,4,3,2,9,8,7,6,5,4,3,2])[i]) s
                   from generate_series(1,12) i) a) = substr(c,13,1)::int
    and (select case when s%11<2 then 0 else 11-s%11 end
           from (select sum(substr(c,i,1)::int*(array[6,5,4,3,2,9,8,7,6,5,4,3,2])[i]) s
                   from generate_series(1,13) i) a) = substr(c,14,1)::int
)
update public.deals d
   set cnpj = regexp_replace(v.c,'^(\d{2})(\d{3})(\d{3})(\d{4})(\d{2})$','\1.\2.\3/\4-\5')
  from v
 where d.id = v.id;
alter table public.deals enable trigger deals_set_updated_at;

-- ============ SEÇÃO 3 — CONFERÊNCIA ============
-- Esperado: nenhuma linha com 10/12/13 dígitos válidos; SPELTA = 09.199.443/0001-28
select length(regexp_replace(coalesce(cnpj,''),'\D','','g')) dig, count(*)
  from public.deals group by 1 order by 1;
select id, title, cnpj from public.deals where cnpj = '09.199.443/0001-28';
select count(*) as restaurados
  from public.deals d join public.bkp_0054_cnpj_zero b on b.id = d.id
 where d.cnpj is distinct from b.cnpj;

-- ============ SEÇÃO 4 — ROLLBACK (só se precisar; rodar sozinha) ============
-- alter table public.deals disable trigger deals_set_updated_at;
-- update public.deals d set cnpj = b.cnpj from public.bkp_0054_cnpj_zero b where d.id = b.id;
-- alter table public.deals enable trigger deals_set_updated_at;
