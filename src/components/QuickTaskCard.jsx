import React from 'react'
import Icon from './Icon.jsx'

export default function QuickTaskCard({ task, onSelect }) {
  return (
    <button type="button" className="task-card" onClick={() => onSelect(task)}>
      <span className="task-icon"><Icon name={task.icon} size={22}/></span>
      <span className="task-copy">
        <small>{task.kicker}</small>
        <strong>{task.label}</strong>
        <span>{task.helper}</span>
      </span>
      <Icon name="arrowRight" size={18}/>
    </button>
  )
}
