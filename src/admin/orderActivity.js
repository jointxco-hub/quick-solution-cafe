// Preserve immutable history when a slower view response arrives after acknowledgement.
export function mergeOrderActivity(current = [], incoming = []) {
  const entries = new Map(current.map(entry => [`${entry.actorId}:${entry.event}`, entry]))
  incoming.forEach(entry => entries.set(`${entry.actorId}:${entry.event}`, entry))
  return [...entries.values()].sort((a, b) => new Date(a.at) - new Date(b.at))
}
