import React from 'react'
import Icon from './Icon.jsx'

// QS-18 — lightweight, non-blocking, first-visit-only prompt. Never a
// modal/overlay: it does not block interaction with the rest of the
// page, and dismissing it (the × or simply not answering) leaves the
// mode at its existing default ('simple' - see languageMode.js) rather
// than forcing a choice.
export default function LanguageModePrompt({ onChoose, onDismiss }) {
  return (
    <div className="qs18-mode-prompt shell" role="status">
      <div className="qs18-mode-prompt-copy">
        <strong>How would you like things explained?</strong>
      </div>
      <div className="qs18-mode-prompt-actions">
        <button type="button" className="qs18-mode-prompt-choice" onClick={() => onChoose('simple')}>
          <span>Simple</span>
          <small>Everyday language</small>
        </button>
        <button type="button" className="qs18-mode-prompt-choice" onClick={() => onChoose('pro')}>
          <span>Pro</span>
          <small>Print &amp; production terms</small>
        </button>
      </div>
      <button type="button" className="qs18-mode-prompt-dismiss" onClick={onDismiss} aria-label="Dismiss">
        <Icon name="xCircle" size={18}/>
      </button>
    </div>
  )
}
