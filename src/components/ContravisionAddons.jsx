import React from 'react'
import { contravisionQuotePreset } from '../lib/contravisionAddons.js'

export default function ContravisionAddons({ onRequestQuote }) {
  return (
    <section className="shell contravision-addons" aria-labelledby="application-addon-title">
      <div className="plain-language-note">
        <div>
          <strong id="application-addon-title">Optional application & fitting</strong>
          <span>Application is quoted separately according to the surface, access and job size. The live print price covers rectangular print supply only. If you order the print separately, include its order reference in your application request.</span>
          <div className="contravision-addon-actions">
            <button className="button secondary" type="button" onClick={() => onRequestQuote(contravisionQuotePreset('window-application'))}>Request window application add-on</button>
            <button className="button secondary" type="button" onClick={() => onRequestQuote(contravisionQuotePreset('vehicle-contravision'))}>Car Contravision quote</button>
          </div>
          <span>Car Contravision is a separate vehicle job: window shape, trimming and fitting are checked before quoting.</span>
        </div>
      </div>
    </section>
  )
}
