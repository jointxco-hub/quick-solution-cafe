// Separate customer session: never reads, replaces or clears staff credentials.
export const CUSTOMER_SESSION_KEY = 'qsc_customer_session_v1'

export function parseGuestTrackingLink(value) {
  try {
    const url = new URL(value)
    const orderNumber = url.searchParams.get('order')?.trim()
    const trackingToken = url.searchParams.get('token')?.trim()
    if (!['https:', 'http:'].includes(url.protocol) || url.pathname !== '/track' || !orderNumber || !/^[a-f0-9]{64}$/i.test(trackingToken || '')) return null
    return { orderNumber, trackingToken }
  } catch { return null }
}

export function createCustomerClient({ url, key, fetcher = fetch, storage, location, history, now = Date.now }) {
  let refreshing = null
  const read = () => {
    try { return JSON.parse(storage.getItem(CUSTOMER_SESSION_KEY) || 'null') } catch { return null }
  }
  const clear = () => storage.removeItem(CUSTOMER_SESSION_KEY)
  const store = data => {
    if (!data?.access_token || !data?.refresh_token) throw new Error('The sign-in link did not return a valid session. Request a new link.')
    const session = { ...data, expiresAt: data.expires_at ? Number(data.expires_at) * 1000 : now() + Number(data.expires_in || 3600) * 1000 }
    storage.setItem(CUSTOMER_SESSION_KEY, JSON.stringify(session))
    return session
  }
  const request = async (path, body, token, method = 'POST') => {
    if (!url || !key) throw new Error('Customer sign-in is not available yet.')
    const headers = { apikey: key, 'Content-Type': 'application/json' }
    if (token) headers.Authorization = `Bearer ${token}`
    const response = await fetcher(`${url}${path}`, { method, headers, ...(method === 'GET' ? {} : { body: JSON.stringify(body || {}) }) })
    let data
    try { data = await response.json() } catch { data = null }
    if (!response.ok) {
      const error = new Error(data?.code === 'PGRST202' || response.status === 503
        ? 'Customer accounts are being prepared. You can still order as a guest.'
        : data?.msg || data?.message || data?.error_description || 'We could not complete that request. Please try again.')
      error.status = response.status
      throw error
    }
    return data
  }
  const session = async () => {
    const saved = read()
    if (!saved?.access_token) return null
    if (saved.expiresAt > now() + 60000) return saved
    if (!refreshing) refreshing = request('/auth/v1/token?grant_type=refresh_token', { refresh_token: saved.refresh_token })
      .then(store).catch(error => { if ([400, 401, 403].includes(error.status)) clear(); throw error }).finally(() => { refreshing = null })
    return refreshing
  }
  const rpc = async (name, body) => {
    const current = await session()
    if (!current) throw new Error('Sign in with your email link to continue.')
    return request(`/rest/v1/rpc/${name}`, body, current.access_token)
  }
  return {
    read, session, rpc,
    consumeRedirect() {
      const params = new URLSearchParams(location.hash.replace(/^#/, ''))
      if (!params.has('access_token') && !params.has('error')) return null
      history.replaceState(null, '', '/account')
      if (params.has('error')) throw new Error(params.get('error_description') || 'Your sign-in link has expired. Request a new one.')
      return store(Object.fromEntries(params))
    },
    sendLink(email) {
      return request(`/auth/v1/otp?redirect_to=${encodeURIComponent(`${location.origin}/account`)}`, {
        email: String(email || '').trim(), create_user: true
      })
    },
    async signOut() {
      const saved = read()
      try { if (saved?.access_token) await request('/auth/v1/logout?scope=local', {}, saved.access_token) }
      finally { clear() }
    },
    async checkoutContext() {
      const current = await session()
      if (!current) return { accessToken: null, email: null }
      const user = await request('/auth/v1/user', null, current.access_token, 'GET')
      return { accessToken: current.access_token, email: user.email }
    }
  }
}
