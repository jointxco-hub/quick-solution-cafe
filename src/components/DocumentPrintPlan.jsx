import React, { useEffect, useMemo, useState } from 'react'

function fileKey(file) {
  return [file?.name || 'file', file?.size || 0, file?.lastModified || 0].join(':')
}

function isImage(file) {
  return String(file?.type || '').startsWith('image/')
}

function countPageSpec(value) {
  const raw = String(value || '').trim()
  if (!raw) return { valid: false, count: 0, normalized: '' }

  let count = 0
  const normalized = []
  for (const part of raw.split(',').map((item) => item.trim()).filter(Boolean)) {
    if (/^\d+$/.test(part)) {
      const page = Number(part)
      if (page < 1 || page > 1000) return { valid: false, count: 0, normalized: raw }
      count += 1
      normalized.push(String(page))
      continue
    }

    const match = part.match(/^(\d+)\s*-\s*(\d+)$/)
    if (!match) return { valid: false, count: 0, normalized: raw }

    const from = Number(match[1])
    const to = Number(match[2])
    if (from < 1 || to < from || to > 1000) return { valid: false, count: 0, normalized: raw }
    count += (to - from) + 1
    normalized.push(from === to ? String(from) : `${from}-${to}`)
  }

  return { valid: count > 0 && count <= 1000, count, normalized: normalized.join(', ') }
}

function makeInstruction(file, previous) {
  const image = isImage(file)
  return {
    key: fileKey(file),
    name: file?.name || 'Document',
    mimeType: file?.type || '',
    selection: previous?.selection || 'all',
    sourcePages: image ? 1 : (previous?.sourcePages || ''),
    pagesSpec: previous?.pagesSpec || '',
    selectedPages: image ? 1 : Number(previous?.selectedPages || 0)
  }
}

export default function DocumentPrintPlan({ files = [], config, onChange }) {
  const [expanded, setExpanded] = useState(() => new Set())

  const instructions = useMemo(() => {
    const previous = Array.isArray(config.documentInstructions) ? config.documentInstructions : []
    const byKey = new Map(previous.map((item) => [item.key, item]))
    return files.map((file) => makeInstruction(file, byKey.get(fileKey(file))))
  }, [files, config.documentInstructions])

  const evaluated = useMemo(() => instructions.map((item) => {
    if (item.selection === 'specific') {
      const parsed = countPageSpec(item.pagesSpec)
      return { ...item, selectedPages: parsed.count, valid: parsed.valid }
    }

    const count = Number(item.sourcePages || 0)
    return { ...item, selectedPages: count, valid: Number.isInteger(count) && count > 0 && count <= 1000 }
  }), [instructions])

  const totalPages = evaluated.reduce((sum, item) => sum + (item.valid ? item.selectedPages : 0), 0)
  const valid = files.length > 0 && evaluated.length === files.length && evaluated.every((item) => item.valid)

  useEffect(() => {
    const nextInstructions = evaluated.map(({ valid: _valid, ...item }) => item)
    const current = JSON.stringify(config.documentInstructions || [])
    const next = JSON.stringify(nextInstructions)
    const nextPages = valid ? totalPages : 0
    if (current !== next || Number(config.pages || 0) !== nextPages || Boolean(config.documentPlanValid) !== valid) {
      onChange({
        documentInstructions: nextInstructions,
        documentPlanValid: valid,
        pages: nextPages
      })
    }
  }, [evaluated, valid, totalPages, config.documentInstructions, config.pages, config.documentPlanValid, onChange])

  const updateInstruction = (key, patch) => {
    const next = instructions.map((item) => item.key === key ? { ...item, ...patch } : item)
    onChange({ documentInstructions: next, documentPlanValid: false })
  }

  const toggleExpanded = (key) => {
    setExpanded((previous) => {
      const next = new Set(previous)
      if (next.has(key)) next.delete(key)
      else next.add(key)
      return next
    })
  }

  if (!files.length) {
    return (
      <div className="doc-plan-empty">
        <strong>Add your documents first.</strong>
        <span>Go back one step and upload the files you want us to print.</span>
      </div>
    )
  }

  return (
    <div className="doc-plan">
      <div className="doc-plan-intro">
        <div>
          <span className="eyebrow">Simple by default</span>
          <h3>What should we print?</h3>
          <p>We assume you want the whole file. Only open a document if you need specific pages.</p>
        </div>
        <div className={`doc-plan-total ${valid ? 'ready' : ''}`}>
          <strong>{valid ? totalPages : '—'}</strong>
          <span>{valid ? `page${totalPages === 1 ? '' : 's'} to print` : 'page count needed'}</span>
        </div>
      </div>

      <div className="doc-plan-files">
        {evaluated.map((item, index) => {
          const open = expanded.has(item.key) || !item.valid
          const image = String(item.mimeType || '').startsWith('image/')
          return (
            <article className={`doc-plan-file ${item.valid ? 'ready' : 'needs-info'}`} key={item.key}>
              <div className="doc-plan-file-head">
                <div>
                  <strong>{item.name}</strong>
                  <small>
                    {image
                      ? 'Image · 1 page'
                      : item.selection === 'specific' && item.valid
                        ? `${item.selectedPages} selected page${item.selectedPages === 1 ? '' : 's'}`
                        : item.valid
                          ? `${item.selectedPages} page${item.selectedPages === 1 ? '' : 's'}`
                          : 'Tell us how many pages to print'}
                  </small>
                </div>
                {!image ? (
                  <button
                    type="button"
                    className="doc-plan-change"
                    onClick={() => toggleExpanded(item.key)}
                    disabled={open && !item.valid}
                  >
                    {open ? (item.valid ? 'Done' : 'Page details needed') : 'Change pages'}
                  </button>
                ) : null}
              </div>

              {!image && open ? (
                <div className="doc-plan-file-options">
                  <div className="doc-plan-choice">
                    <button
                      type="button"
                      className={item.selection === 'all' ? 'selected' : ''}
                      onClick={() => updateInstruction(item.key, { selection: 'all', pagesSpec: '' })}
                    >
                      <strong>Print everything</strong>
                      <small>Use every page in this file.</small>
                    </button>
                    <button
                      type="button"
                      className={item.selection === 'specific' ? 'selected' : ''}
                      onClick={() => updateInstruction(item.key, { selection: 'specific' })}
                    >
                      <strong>Only certain pages</strong>
                      <small>Example: 17, 19, 27 or 1-4, 8.</small>
                    </button>
                  </div>

                  {item.selection === 'specific' ? (
                    <label className="checkout-field doc-plan-input">
                      <span>Which pages?</span>
                      <input
                        type="text"
                        inputMode="text"
                        value={item.pagesSpec || ''}
                        onChange={(event) => updateInstruction(item.key, { pagesSpec: event.target.value })}
                        placeholder="17, 19, 27"
                      />
                      <small>{item.pagesSpec && !item.valid ? 'Use page numbers separated by commas, with ranges like 1-4.' : 'We will keep this exact instruction with the file.'}</small>
                    </label>
                  ) : (
                    <label className="checkout-field doc-plan-input">
                      <span>How many pages are in this file?</span>
                      <input
                        type="number"
                        min="1"
                        max="1000"
                        step="1"
                        value={item.sourcePages || ''}
                        onChange={(event) => updateInstruction(item.key, { sourcePages: event.target.value })}
                        placeholder="e.g. 30"
                      />
                      <small>We only ask because browsers cannot reliably count every PDF or Word file.</small>
                    </label>
                  )}
                </div>
              ) : null}
            </article>
          )
        })}
      </div>

      <div className="doc-plan-copies">
        <label className="checkout-field">
          <span>How many copies of this set?</span>
          <input
            type="number"
            min="1"
            max="500"
            step="1"
            value={config.copies || 1}
            onChange={(event) => onChange({ copies: Math.max(1, Number(event.target.value || 1)) })}
          />
          <small>This applies to the whole batch. Different copies per file will stay under More options later.</small>
        </label>
      </div>

      {!valid ? (
        <div className="doc-plan-note">
          <strong>One small detail left.</strong>
          <span>Complete the page count or page selection for the document highlighted above.</span>
        </div>
      ) : (
        <div className="doc-plan-note ready">
          <strong>{totalPages} page{totalPages === 1 ? '' : 's'} × {Number(config.copies || 1)} cop{Number(config.copies || 1) === 1 ? 'y' : 'ies'}.</strong>
          <span>You can continue. Colour, sides and finishing are next.</span>
        </div>
      )}
    </div>
  )
}
