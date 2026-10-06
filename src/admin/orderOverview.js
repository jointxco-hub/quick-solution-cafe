const dayFormatter = new Intl.DateTimeFormat('en-CA', { timeZone: 'Africa/Johannesburg', year: 'numeric', month: '2-digit', day: '2-digit' })
export function orderDay(value) {
  if (!value || Number.isNaN(new Date(value).getTime())) return ''
  return dayFormatter.format(new Date(value))
}
export function filterOrders(queue, filter, now = new Date()) {
  return queue.filter(item => filter === 'today' ? orderDay(item.submittedAt) === orderDay(now) : filter === 'attention' ? ['blocked', 'failed'].includes(item.handoffStatus) : true)
    .sort((a, b) => new Date(b.submittedAt) - new Date(a.submittedAt))
}
