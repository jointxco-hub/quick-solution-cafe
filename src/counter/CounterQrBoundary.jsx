import React from 'react'

// Fault isolation: the QR is an optional payment display. Its rendering must
// never break Cash/Card, the order detail, or the rest of the Counter PWA.
export default class CounterQrBoundary extends React.Component {
  constructor(props) {
    super(props)
    this.state = { error: null }
  }
  static getDerivedStateFromError(error) {
    return { error: String(error?.message || 'Unknown QR rendering error').slice(0,240) }
  }
  componentDidCatch(error, info) {
    console.error('[counter-qr] display error', error, info?.componentStack)
  }
  componentDidUpdate(previous) {
    if (previous.orderId !== this.props.orderId && this.state.error) {
      this.setState({ error: null })
    }
  }
  render() {
    if (this.state.error) {
      return <div className="qsc-qr-fallback" role="alert">
        <strong>QR display unavailable</strong>
        <p>Your order has not been marked paid. Do not create another payment until staff checks the original order.</p>
        <details><summary>Technical error</summary><code>{this.state.error}</code></details>
      </div>
    }
    return this.props.children
  }
}
