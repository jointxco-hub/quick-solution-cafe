import React from 'react'
import ReactDOM from 'react-dom/client'
import App from './App.jsx'
import './styles/app.css'
import './styles/qs03.css'
import './styles/qs031.css'
import './styles/qs04c.css'
import './styles/qs05.css'
import './styles/qs07.css'
import './styles/qs08.css'
import './styles/qs084.css'
import './styles/qs085.css'
import './styles/qs09.css'
import './styles/qs10.css'
import './styles/qs12-1.css'

class ErrorBoundary extends React.Component {
  constructor(props) {
    super(props)
    this.state = { error: null }
  }

  static getDerivedStateFromError(error) {
    return { error }
  }

  componentDidCatch(error, info) {
    console.error('Quick Solution render error:', error, info)
  }

  render() {
    if (this.state.error) {
      return (
        <div style={{ minHeight: '100vh', padding: 32, fontFamily: 'system-ui, sans-serif', background: '#f6f6f2', color: '#111' }}>
          <div style={{ maxWidth: 760, margin: '40px auto', background: '#fff', border: '1px solid #deded8', borderRadius: 20, padding: 28 }}>
            <div style={{ fontSize: 12, fontWeight: 800, textTransform: 'uppercase', letterSpacing: '.12em', color: '#008B72' }}>Quick Solution dev error</div>
            <h1 style={{ marginBottom: 12 }}>The app hit a render error.</h1>
            <p style={{ lineHeight: 1.6, color: '#555' }}>The actual error is shown below instead of leaving you with a blank screen.</p>
            <pre style={{ whiteSpace: 'pre-wrap', overflowWrap: 'anywhere', padding: 16, background: '#111', color: '#fff', borderRadius: 12 }}>{String(this.state.error?.stack || this.state.error?.message || this.state.error)}</pre>
          </div>
        </div>
      )
    }
    return this.props.children
  }
}

ReactDOM.createRoot(document.getElementById('root')).render(
  <React.StrictMode>
    <ErrorBoundary><App /></ErrorBoundary>
  </React.StrictMode>
)


import './styles/qs13.css'
import './styles/qs14-coming-soon.css'
