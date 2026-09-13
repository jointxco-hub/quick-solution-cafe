import React from 'react'
import Icon from './Icon.jsx'

export function FileControl({ field, file, onFileChange, guided = false }) {
  return (
    <label className={`upload-field field-full ${guided ? 'guided-upload' : ''}`}>
      <input
        className="visually-hidden"
        type="file"
        accept=".pdf,.doc,.docx,.png,.jpg,.jpeg"
        onChange={(event) => onFileChange?.(event.target.files?.[0] || null)}
      />
      <span className="upload-icon"><Icon name="upload" size={21}/></span>
      <span className="upload-copy">
        <strong>{file?.name || field.label}</strong>
        <small>{file ? 'Tap to choose a different file' : field.help}</small>
      </span>
      <span className="upload-action">Choose file</span>
    </label>
  )
}

function ChoiceButtons({ field, value, onChange, guided }) {
  return (
    <fieldset className="field field-full">
      <legend>{field.label}</legend>
      <div className={guided ? 'guided-choice-grid' : 'segmented-grid'}>
        {field.options.map((item) => (
          <button
            key={item.id}
            type="button"
            className={`${guided ? 'guided-choice' : 'segment'} ${value === item.id ? 'selected' : ''}`}
            onClick={() => onChange(item.id)}
            aria-pressed={value === item.id}
          >
            <span>{item.label}</span>
            {guided && item.helper && <small>{item.helper}</small>}
          </button>
        ))}
      </div>
    </fieldset>
  )
}

export default function FieldControl({ field, value, onChange, file, onFileChange, guided = false }) {
  if (field.type === 'file') {
    return <FileControl field={field} file={file} onFileChange={onFileChange} guided={guided}/>
  }

  if (field.type === 'segmented' || (guided && field.type === 'select' && field.options?.length <= 5)) {
    return <ChoiceButtons field={field} value={value} onChange={onChange} guided={guided}/>
  }

  if (field.type === 'number') {
    return (
      <label className="field">
        <span>{field.label}</span>
        <div className="input-with-suffix">
          <input
            type="number"
            min={field.min}
            step={field.step}
            value={value}
            onChange={(event) => onChange(event.target.value)}
            inputMode="decimal"
          />
          {field.suffix && <small>{field.suffix}</small>}
        </div>
      </label>
    )
  }

  return (
    <label className="field">
      <span>{field.label}</span>
      <select value={value} onChange={(event) => onChange(event.target.value)}>
        {field.options.map((item) => <option key={item.id} value={item.id}>{item.label}</option>)}
      </select>
    </label>
  )
}
