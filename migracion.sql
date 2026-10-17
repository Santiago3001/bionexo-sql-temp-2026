-- BioNexo NEA: módulo BioNexo Carbon dentro de "Reporte de Impacto".
--
-- Guarda (1) análisis ambientales del material con su trazabilidad y
-- (2) acuerdos de reparto de eventuales beneficios por créditos de carbono
-- entre comprador y vendedor, más la demanda agregada de compradores.
--
-- IMPORTANTE: estas tablas NO representan créditos certificados. Un análisis
-- o un acuerdo no generan créditos: sólo quedan registrados impacto estimado
-- y potencial de certificación.

-- ============================================================
-- 1. ANÁLISIS AMBIENTALES (trazabilidad del material)
-- ============================================================

create table if not exists public.carbon_analyses (
  id bigint generated always as identity primary key,
  user_id uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  offer_id bigint references public.offers(id) on delete set null,
  product text not null,
  tons numeric(12,2) not null default 0 check (tons >= 0),
  source text not null default 'reglas' check (source in ('reglas', 'ia')),
  model text,
  summary text not null default '',
  pathway text not null default '',
  -- Evitación siempre null sin línea base verificable.
  co2_avoided numeric(12,3),
  -- Almacenamiento potencial (teórico), nunca un crédito.
  co2_stored numeric(12,3),
  certification_level text not null default 'bajo'
    check (certification_level in ('bajo', 'medio', 'alto')),
  certification_requirements jsonb not null default '[]'::jsonb,
  destinations jsonb not null default '[]'::jsonb,
  warnings jsonb not null default '[]'::jsonb,
  created_at timestamptz not null default now()
);

create index if not exists carbon_analyses_user_idx
  on public.carbon_analyses (user_id, created_at desc);
create index if not exists carbon_analyses_offer_idx
  on public.carbon_analyses (offer_id);

alter table public.carbon_analyses enable row level security;

drop policy if exists "analisis_select_own" on public.carbon_analyses;
create policy "analisis_select_own" on public.carbon_analyses
for select using (user_id = (select auth.uid()));

drop policy if exists "analisis_insert_own" on public.carbon_analyses;
create policy "analisis_insert_own" on public.carbon_analyses
for insert with check (user_id = (select auth.uid()));

drop policy if exists "analisis_update_own" on public.carbon_analyses;
create policy "analisis_update_own" on public.carbon_analyses
for update using (user_id = (select auth.uid()))
with check (user_id = (select auth.uid()));

drop policy if exists "analisis_delete_own" on public.carbon_analyses;
create policy "analisis_delete_own" on public.carbon_analyses
for delete using (user_id = (select auth.uid()));

-- ============================================================
-- 2. ACUERDOS DE REPARTO DE BENEFICIOS (comprador ↔ vendedor)
-- ============================================================

create table if not exists public.carbon_agreements (
  id bigint generated always as identity primary key,
  conversation_id uuid references public.conversations(id) on delete cascade,
  contract_id uuid references public.contracts(id) on delete set null,
  offer_id bigint references public.offers(id) on delete set null,
  seller_id uuid not null references public.profiles(id) on delete cascade,
  buyer_id uuid not null references public.profiles(id) on delete cascade,
  product text not null,
  tons numeric(12,2) not null default 0 check (tons >= 0),
  seller_share_pct numeric(5,2) not null default 50 check (seller_share_pct between 0 and 100),
  buyer_share_pct numeric(5,2) not null default 50 check (buyer_share_pct between 0 and 100),
  status text not null default 'propuesto'
    check (status in ('propuesto', 'aceptado', 'rechazado', 'archivado')),
  proposed_by uuid not null default auth.uid(),
  notes text not null default '',
  responded_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint carbon_shares_suman_100 check (seller_share_pct + buyer_share_pct = 100),
  constraint carbon_partes_distintas check (seller_id <> buyer_id)
);

create index if not exists carbon_agreements_vendedor_idx
  on public.carbon_agreements (seller_id, created_at desc);
create index if not exists carbon_agreements_comprador_idx
  on public.carbon_agreements (buyer_id, created_at desc);
create index if not exists carbon_agreements_conversacion_idx
  on public.carbon_agreements (conversation_id);

drop trigger if exists carbon_agreements_set_updated_at on public.carbon_agreements;
create trigger carbon_agreements_set_updated_at before update on public.carbon_agreements
for each row execute function public.set_updated_at();

alter table public.carbon_agreements enable row level security;

drop policy if exists "acuerdo_select_partes" on public.carbon_agreements;
create policy "acuerdo_select_partes" on public.carbon_agreements
for select using (seller_id = (select auth.uid()) or buyer_id = (select auth.uid()));

drop policy if exists "acuerdo_insert_parte" on public.carbon_agreements;
create policy "acuerdo_insert_parte" on public.carbon_agreements
for insert with check (
  (seller_id = (select auth.uid()) or buyer_id = (select auth.uid()))
  and proposed_by = (select auth.uid())
);

drop policy if exists "acuerdo_update_partes" on public.carbon_agreements;
create policy "acuerdo_update_partes" on public.carbon_agreements
for update using (seller_id = (select auth.uid()) or buyer_id = (select auth.uid()))
with check (seller_id = (select auth.uid()) or buyer_id = (select auth.uid()));

drop policy if exists "acuerdo_delete_proponente" on public.carbon_agreements;
create policy "acuerdo_delete_proponente" on public.carbon_agreements
for delete using (proposed_by = (select auth.uid()) and status = 'propuesto');

-- ============================================================
-- 3. NOTIFICACIONES (misma vía que los mensajes del chat)
-- ============================================================

create or replace function public.notify_carbon_agreement()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  target uuid;
  link_destino text;
begin
  link_destino := case
    when new.conversation_id is not null then '/mensajes/' || new.conversation_id
    else '/vendedor/impacto'
  end;

  if tg_op = 'INSERT' then
    -- Avisa a la otra parte de la propuesta.
    target := case when new.seller_id = new.proposed_by then new.buyer_id else new.seller_id end;
    insert into public.notifications (user_id, type, title, body, link)
    values (
      target,
      'sistema',
      'Propuesta de acuerdo BioNexo Carbon',
      'Reparto propuesto para ' || new.product || ': vendedor ' ||
        (case when position('.' in new.seller_share_pct::text) = 0 then new.seller_share_pct::text
              else rtrim(rtrim(new.seller_share_pct::text, '0'), '.') end) ||
        '% / comprador ' ||
        (case when position('.' in new.buyer_share_pct::text) = 0 then new.buyer_share_pct::text
              else rtrim(rtrim(new.buyer_share_pct::text, '0'), '.') end) || '%.',
      link_destino
    );
  elsif new.status <> old.status and new.status in ('aceptado', 'rechazado') then
    -- Avisa al proponente la respuesta.
    insert into public.notifications (user_id, type, title, body, link)
    values (
      new.proposed_by,
      'sistema',
      case when new.status = 'aceptado'
        then 'Acuerdo BioNexo Carbon aceptado'
        else 'Acuerdo BioNexo Carbon rechazado' end,
      'Contrato ambiental de ' || new.product || ' (' ||
        (case when position('.' in new.seller_share_pct::text) = 0 then new.seller_share_pct::text
              else rtrim(rtrim(new.seller_share_pct::text, '0'), '.') end) ||
        '% vendedor / ' ||
        (case when position('.' in new.buyer_share_pct::text) = 0 then new.buyer_share_pct::text
              else rtrim(rtrim(new.buyer_share_pct::text, '0'), '.') end) || '% comprador).',
      link_destino
    );
  end if;
  return new;
end;
$$;

drop trigger if exists carbon_agreements_notify on public.carbon_agreements;
create trigger carbon_agreements_notify after insert or update on public.carbon_agreements
for each row execute function public.notify_carbon_agreement();

-- ============================================================
-- 4. DEMANDA AGREGADA DE COMPRADORES (sin datos personales)
--
-- Las necesidades de compra son privadas de cada comprador por RLS; este
-- RPC devuelve sólo conteos y volúmenes agregados por producto para que el
-- vendedor pueda identificar compradores disponibles sin exponer datos.
-- Los compradores con nombre propio sólo se muestran si ya hay conversación.
-- ============================================================

create or replace function public.demanda_por_producto()
returns table (
  product text,
  compradores bigint,
  toneladas numeric,
  ciudades jsonb
)
language sql
security definer
set search_path = ''
stable
as $$
  select
    pn.product,
    count(*)::bigint,
    coalesce(sum(pn.quantity_tons), 0)::numeric,
    coalesce(jsonb_agg(distinct pn.delivery_city), '[]'::jsonb)
  from public.purchase_needs pn
  where pn.status = 'active'
  group by pn.product
  order by pn.product;
$$;

revoke all on function public.demanda_por_producto() from public, anon;
grant execute on function public.demanda_por_producto() to authenticated;

-- ============================================================
-- 5. REALTIME de los acuerdos (para el chat y el panel)
-- ============================================================

do $$
begin
  begin
    alter publication supabase_realtime add table public.carbon_agreements;
  exception when duplicate_object then null;
  end;
end;
$$;
