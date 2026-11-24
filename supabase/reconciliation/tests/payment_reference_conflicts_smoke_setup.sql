-- Synthetic Postgres 17 smoke harness only. Never point at staging or production.
-- Provides the minimum objects needed to parse and exercise the DRAFT.
CREATE ROLE anon NOLOGIN;
CREATE ROLE authenticated NOLOGIN;
CREATE ROLE service_role NOLOGIN;
-- Reproduce the v7 recorder-owner pattern with a different migration owner.
CREATE ROLE supabase_admin NOLOGIN SUPERUSER;
CREATE SCHEMA auth;
CREATE SCHEMA commerce;

CREATE FUNCTION auth.role()
RETURNS text LANGUAGE sql STABLE
AS $$ SELECT nullif(current_setting('request.jwt.claim.role',true),'') $$;

CREATE FUNCTION auth.uid()
RETURNS uuid LANGUAGE sql STABLE
AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;

CREATE TABLE public.tenants(
    id uuid PRIMARY KEY,
    slug text NOT NULL,
    status text NOT NULL
);

CREATE TABLE public.orders(
    id uuid PRIMARY KEY,
    tenant_id uuid NOT NULL REFERENCES public.tenants(id),
    payment_status text NOT NULL DEFAULT 'pending',
    deposit_paid numeric NOT NULL DEFAULT 0,
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE commerce.service_orders(
    id uuid PRIMARY KEY,
    tenant_id uuid NOT NULL REFERENCES public.tenants(id),
    order_number text NOT NULL UNIQUE,
    total_amount numeric NOT NULL CHECK (total_amount>0),
    payment_status text NOT NULL DEFAULT 'unpaid',
    opps_order_id uuid REFERENCES public.orders(id),
    source_metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE commerce.service_order_payments(
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL REFERENCES public.tenants(id),
    service_order_id uuid NOT NULL REFERENCES commerce.service_orders(id),
    provider text NOT NULL,
    status text NOT NULL,
    amount numeric NOT NULL,
    pf_payment_id text,
    raw_itn jsonb,
    completed_at timestamptz,
    staff_reference text,
    UNIQUE (provider,pf_payment_id)
);

CREATE TABLE commerce.service_order_handoffs(
    service_order_id uuid PRIMARY KEY REFERENCES commerce.service_orders(id),
    status text NOT NULL,
    preview_payload jsonb NOT NULL DEFAULT '{}'::jsonb,
    blockers jsonb NOT NULL DEFAULT '[]'::jsonb,
    warnings jsonb NOT NULL DEFAULT '[]'::jsonb,
    last_previewed_at timestamptz,
    failure_message text,
    updated_at timestamptz
);

CREATE FUNCTION commerce.qs_build_opps_handoff_preview(uuid)
RETURNS jsonb LANGUAGE sql
AS $$ SELECT '{}'::jsonb $$;

-- No Finance or invoice projection is performed in this pure schema harness.
-- The real projection and concurrency behavior remains subject to v8 tests
-- against the full restore and the existing Step 29 evidence.
CREATE FUNCTION commerce.qs_project_manual_receipt(uuid)
RETURNS void LANGUAGE sql
AS $$ SELECT NULL::void $$;

CREATE FUNCTION commerce.qs_apply_payfast_payment(
    uuid,numeric,text,jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb LANGUAGE sql
AS $ SELECT '{}'::jsonb $;
ALTER FUNCTION commerce.qs_apply_payfast_payment(uuid,numeric,text,jsonb)
    OWNER TO supabase_admin;

CREATE FUNCTION public.has_tenant_capability(uuid,text)
RETURNS boolean LANGUAGE sql STABLE
AS $$ SELECT coalesce(current_setting('test.has_capability',true),'')='true' $$;

CREATE FUNCTION public.has_tenant_permission(uuid,text)
RETURNS boolean LANGUAGE sql STABLE
AS $$ SELECT false $$;
