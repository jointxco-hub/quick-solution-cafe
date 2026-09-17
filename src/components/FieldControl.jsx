import React from 'react'
import Icon from './Icon.jsx'

export function FileControl({ field, file, onFileChange, guided = false }) {
  const multiple = Boolean(field.multiple)
  const files = multiple ? (Array.isArray(file) ? file : file ? [file] : []) : []
  const maxFiles = Number(field.maxFiles || 25)

  const chooseFiles = (event) => {
    const selected = Array.from(event.target.files || [])
    if (!multiple) {
      onFileChange?.(selected[0] || null)
      return
    }
    const existing = files
    const next = [...existing, ...selected].slice(0, maxFiles)
    onFileChange?.(next)
    event.target.value = ''
  }

  const removeFile = (index) => {
    onFileChange?.(files.filter((_, fileIndex) => fileIndex !== index))
  }

  if (multiple) {
    return (
      <div className={`upload-field upload-field-multiple field-full ${guided ? 'guided-upload' : ''}`}>
        <label className="upload-picker">
          <input
            className="visually-hidden"
            type="file"
            multiple
            accept={field.accept || ".pdf,.doc,.docx,.png,.jpg,.jpeg"}
            onChange={chooseFiles}
          />
          <span className="upload-icon"><Icon name="upload" size={21}/></span>
          <span className="upload-copy">
            <strong>{files.length ? `${files.length} document${files.length === 1 ? '' : 's'} selected` : 'Send us your documents'}</strong>
            <small>{files.length ? `Add more documents · up to ${maxFiles} total` : 'Select several files at once. PDF is best. DOCX, JPG and PNG also work.'}</small>
          </span>
          <span className="upload-action">{files.length ? 'Add more' : 'Choose files'}</span>
        </label>

        {files.length ? (
          <>
            <div className="upload-file-summary">
              <strong>{files.length} file{files.length === 1 ? '' : 's'}</strong>
              <span>{(files.reduce((sum, selectedFile) => sum + Number(selectedFile.size || 0), 0) / (1024 * 1024)).toFixed(1)} MB total</span>
            </div>
            <div className="upload-file-list">
            {files.map((selectedFile, index) => (
              <div className="upload-file-row" key={`${selectedFile.name}-${selectedFile.size}-${index}`}>
                <span><strong>{selectedFile.name}</strong><small>{Math.max(1, Math.round(selectedFile.size / 1024))} KB</small></span>
                <button type="button" onClick={() => removeFile(index)} aria-label={`Remove ${selectedFile.name}`}>Remove</button>
              </div>
            ))}
            </div>
          </>
        ) : null}
      </div>
    )
  }

  return (
    <label className={`upload-field field-full ${guided ? 'guided-upload' : ''}`}>
      <input
        className="visually-hidden"
        type="file"
        accept={field.accept || ".pdf,.doc,.docx,.png,.jpg,.jpeg"}
        onChange={chooseFiles}
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

  if (field.type === 'textarea') {
    return (
      <label className="field field-full">
        <span>{field.label}</span>
        <textarea
          value={value || ''}
          onChange={(event) => onChange(event.target.value)}
          placeholder={field.placeholder || ''}
          rows={4}
        />
        {field.help && <small>{field.help}</small>}
      </label>
    )
  }

  if (field.type === 'text' || field.type === 'date' || field.type === 'time') {
    return (
      <label className="field">
        <span>{field.label}</span>
        <input
          type={field.type}
          value={value || ''}
          onChange={(event) => onChange(event.target.value)}
          placeholder={field.placeholder || ''}
        />
        {field.help && <small>{field.help}</small>}
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
