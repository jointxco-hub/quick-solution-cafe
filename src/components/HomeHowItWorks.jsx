import React from 'react'

const steps = [
  { number: '01', title: 'Choose', description: 'Pick a service or upload your document.' },
  { number: '02', title: 'Customise', description: 'Add the details we need, then review your order.' },
  { number: '03', title: 'Pay', description: 'Choose an available payment option at checkout.' },
  { number: '04', title: 'Get it', description: 'Collect locally or choose an available delivery option.' }
]

export default function HomeHowItWorks() {
  return <section className="qs23-process shell section" aria-labelledby="qs23-process-title">
    <header className="qs23-process-heading">
      <span className="eyebrow">Simple from start to finish</span>
      <h2 id="qs23-process-title">Here's how it works.</h2>
    </header>
    <ol className="qs23-process-list">
      {steps.map(step => <li key={step.number} className="qs23-process-step">
        <span className="qs23-process-number">{step.number}</span>
        <strong>{step.title}</strong>
        <p>{step.description}</p>
      </li>)}
    </ol>
  </section>
}
