-- Read-only release audit. Run separately against the explicitly selected project.
-- A mismatch is a review item, never authorization to invent or overwrite a receipt.
with cafe as (
  select service_order_id, sum(amount) as paid
  from commerce.service_order_payments
  where status = 'completed'
  group by service_order_id
), opps as (
  select tenant_id, order_id, sum(amount) as paid
  from public.transactions
  where type = 'income' and payment_status = 'completed'
  group by tenant_id, order_id
)
select so.id as service_order_id, so.order_number, so.tenant_id,
       so.opps_order_id, coalesce(c.paid, 0) as cafe_paid,
       coalesce(o.paid, 0) as opps_paid,
       case
         when so.opps_order_id is null then 'PAID_WITHOUT_PRODUCTION_HANDOFF'
         when linked.id is null then 'INVALID_TENANT_OR_ORDER_LINK'
         else 'PAYMENT_BALANCE_MISMATCH'
       end as finding
from commerce.service_orders so
left join cafe c on c.service_order_id = so.id
left join public.orders linked on linked.id = so.opps_order_id
  and linked.tenant_id = so.tenant_id and linked.source = 'quick_solution'
left join opps o on o.order_id = linked.id and o.tenant_id = so.tenant_id
where (so.opps_order_id is null and coalesce(c.paid, 0) > 0)
   or (so.opps_order_id is not null and
       (linked.id is null or coalesce(c.paid, 0) <> coalesce(o.paid, 0)))
order by so.order_number;
