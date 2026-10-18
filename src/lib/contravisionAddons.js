export function contravisionQuotePreset(jobType) {
  if (!['window-application', 'vehicle-contravision'].includes(jobType)) throw new Error('Unknown application job type.')
  return {
    jobType, material: 'contravision', installation: 'install', frame: 'none', sides: 'single',
    supplyScope: jobType === 'window-application' ? 'application-only' : 'print-and-application'
  }
}
