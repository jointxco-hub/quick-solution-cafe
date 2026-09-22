import React from 'react'

// QS-18 — compact "Worked with" proof strip.
//
// No approved client/partner names or logos exist anywhere in this
// project yet (checked: no such data file, no logo assets under
// public/), so this is deliberately NOT a list of specific named
// businesses - inventing plausible-sounding company names would present
// false social proof to real customers. Instead this uses the same
// honest, already-true categories of work Quick Solution already
// describes elsewhere (see ProofGallery.jsx's real copy about product
// branding, packaging and event branding). Swap these for real,
// approved names/logos the moment the business provides them - this
// array is the one place to edit.
const workedWith = [
  'Local cafés & retailers',
  'Community events & markets',
  'Schools & offices',
  'Growing local brands'
]

export default function WorkedWithStrip() {
  return (
    <section className="qs18-worked-with shell" aria-label="Works well for">
      {/* QS-21.4 section 7: renamed from "Worked with" (read like an
          eyebrow/code label at a glance - it used the exact same all-
          caps, wide-tracked treatment as every other structural eyebrow
          on the site) to "Works well for", styled distinctly as a
          natural sentence-case lead-in rather than a category tag. */}
      <span className="qs18-worked-with-label">Works well for</span>
      <div className="qs18-worked-with-list">
        {workedWith.map((name) => (
          <span key={name} className="qs18-worked-with-item">{name}</span>
        ))}
      </div>
    </section>
  )
}
