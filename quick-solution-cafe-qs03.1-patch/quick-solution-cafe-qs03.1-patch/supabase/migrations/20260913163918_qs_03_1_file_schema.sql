alter table commerce.service_orders
  add column if not exists upload_token_hash text,
  add column if not exists upload_token_expires_at timestamptz;

create table if not exists commerce.service_order_files (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete restrict,
  order_id uuid not null references commerce.service_orders(id) on delete cascade,
  order_item_id uuid not null references commerce.service_order_items(id) on delete cascade,
  storage_bucket text not null default 'uploads' check (storage_bucket = 'uploads'),
  storage_path text not null,
  original_filename text not null,
  mime_type text,
  byte_size bigint not null check (byte_size > 0 and byte_size <= 20971520),
  status text not null default 'uploaded' check (status in ('uploaded','deleted')),
  uploaded_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  unique (storage_bucket, storage_path)
);

create index if not exists idx_service_order_files_order
  on commerce.service_order_files (order_id, uploaded_at desc);
create index if not exists idx_service_order_files_item
  on commerce.service_order_files (order_item_id, uploaded_at desc);

alter table commerce.service_order_files enable row level security;
revoke all on commerce.service_order_files from anon, authenticated;

comment on table commerce.service_order_files is
  'Private files uploaded for Quick Solution service orders. Objects live in the existing private uploads bucket under a tenant-prefixed path.';
comment on column commerce.service_orders.upload_token_hash is
  'SHA-256 of a short-lived opaque token returned to the browser after order creation. Raw token is never stored.';
