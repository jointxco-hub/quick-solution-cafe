import React from 'react'
import ProductScene from './ProductScene.jsx'

const stories = [
  {
    id: 'documents',
    eyebrow: 'Print it',
    title: 'CVs, homework and forms.',
    copy: 'Upload from your phone. Collect when it is ready.',
    scene: 'a4-print'
  },
  {
    id: 'branding',
    eyebrow: 'Brand it',
    title: 'Signs, cards and apparel.',
    copy: 'Guided ordering keeps the specs simple without losing control.',
    scene: 'printed-tshirt'
  },
  {
    id: 'pickup',
    eyebrow: 'Collect local',
    title: 'Online first. Nearby pickup.',
    copy: 'The Café starts the network; Quick Points extend it into the community.',
    scene: 'quick-point'
  }
]

export default function SubtleStoryRail() {
  return (
    <section className="shell section visual-story-section" aria-label="How Quick Solution fits real community use">
      <div className="section-heading visual-story-heading">
        <div>
          <span className="eyebrow">One place for everyday jobs</span>
          <h2>From file to pickup.</h2>
        </div>
        <p>Simple enough for a quick document. Structured enough for a growing business.</p>
      </div>

      <div className="story-rail">
        {stories.map((story) => (
          <article key={story.id} className="story-card">
            <div className="story-media"><ProductScene productId={story.scene} /></div>
            <div className="story-copy">
              <span className="eyebrow">{story.eyebrow}</span>
              <h3>{story.title}</h3>
              <p>{story.copy}</p>
            </div>
          </article>
        ))}
      </div>
    </section>
  )
}
