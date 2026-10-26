// Read-only presentation for the upcoming authorized OPPS work-queue RPC.
// The server, not this client, resolves tenant membership and authoritative balance.
// Deliberately separate from counterOrders.js: OPPS documents are not counter sales.
import { formatMoney } from './pricing.js'

const TYPES = new Set(['invoice', 'order'])
export function describeOppsCafeWorkItem(item) {
  if (!item || !TYPES.has(item.sourceType) || typeof item.sourceId !== 'string' || !item.sourceId) return null
  const balance = Number(item.balanceDue)
  const hasBalance = Number.isFinite(balance) && balance > 0
  const isPaid = item.paymentStatus === 'paid' || (Number.isFinite(balance) && balance <= 0)
  return {
    key: item.sourceType + ':' + item.sourceId,
    sourceId: item.sourceId,
    sourceType: item.sourceType,
    number: item.number || '—',
    customer: item.customerName || 'Customer',
    status: item.status || '—',
    total: Number.isFinite(Number(item.total)) ? formatMoney(Number(item.total)) : '—',
    balance: Number.isFinite(balance) ? formatMoney(Math.max(0, balance)) : '—',
    paymentLabel: isPaid ? 'Paid' : hasBalance ? 'Outstanding' : 'Review payment',
    canRequestPayment: Boolean(item.paymentEligible) && hasBalance && !isPaid,
    handoffStatus: item.handoffStatus || 'not_sent'
  }
}

export async function loadOppsCafeWorkQueue(load) {
  try {
    const response = await load()
    if (!response || !Array.isArray(response.items)) return { status: 'error', message: 'Unexpected work queue response.' }
    const items = response.items.map(describeOppsCafeWorkItem).filter(Boolean)
    return { status: items.length ? 'ready' : 'empty', items }
  } catch (error) {
    return { status: 'error', message: error instanceof Error ? error.message : 'Unable to load the work queue.' }
  }
}
