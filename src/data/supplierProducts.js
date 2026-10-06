// Customer-safe definitions only. Supplier costs and references are stored
// separately in operations_definition by the catalogue installer.
const select = (id, label, values) => ({ id, type: 'select', label, default: values[0][0], options: values.map(([id, label]) => ({ id, label })) })
const count = { id: 'quantity', type: 'number', label: 'How many?', default: 1, min: 1, max: 10000, step: 1, required: true }
const dimensions = [
  { id: 'width', type: 'number', label: 'Finished width', suffix: 'metres', default: 1, min: 0.1, max: 20, step: 0.01, required: true },
  { id: 'height', type: 'number', label: 'Finished height', suffix: 'metres', default: 1, min: 0.1, max: 20, step: 0.01, required: true }
]
const artwork = select('artwork', 'What about the design?', [['ready', 'My artwork is ready'], ['check', 'Please check my artwork'], ['design', 'I need design help']])
const file = { id: 'file', type: 'file', label: 'Artwork or reference', help: 'Upload a PDF, image or photo of the installation area.' }
const brief = { id: 'brief', type: 'textarea', label: 'Anything we should know?', placeholder: 'Intended use, deadline, measurements or finishing requirements.' }
const paperSize = select('size', 'Which size?', [['a5', 'A5'], ['a6', 'A6'], ['a4', 'A4']])
const sides = select('sides', 'Printed sides', [['single', 'Single sided'], ['double', 'Double sided']])
const correxSizes = [
  ['a3', 'A3 · 297 × 420 mm', 87.5],
  ['a2', 'A2 · 420 × 594 mm', 175],
  ['a1', 'A1 · 594 × 841 mm', 350],
  ['a0', 'A0 · 841 × 1189 mm', 700]
]
function enquiry(id, name, category, description, specificationFields) {
  return {
    id, name, shortName: name, category, description, plainDescription: `${description} Configure your request; we confirm the quote before payment.`,
    keywords: [id.replaceAll('-', ' '), name.toLowerCase()], active: true, popular: false,
    serviceType: 'print-signage', channels: { storefront: true, guided: true, advanced: false, pos: false, quote: true },
    guidedJourneyId: `${id}-guided`, nextActionLabel: 'Request a quote', pricingVersion: '2026-10-catalogue-01',
    pricing: { strategy: 'ENQUIRY', quoteRequired: true }, fields: [...specificationFields, artwork, brief, file],
    productPage: { headline: name, intro: description, showStartingPrice: false }
  }
}
export const supplierProducts = [
  enquiry('flyers', 'Flyers', 'Business Essentials', 'Printed flyers for local promotions and events.', [paperSize, sides, { ...count, default: 500 }]),
  {
    id: 'correx-boards', name: 'Correx Boards', shortName: 'Correx', category: 'Signs & Large Format',
    description: 'Single-sided printed Correx boards for notices, directions and promotions.',
    plainDescription: 'Choose a standard size and quantity. Single-sided print, board only. Custom sizes, double-sided printing, eyelets and mounting need a Shop Signs quote.',
    active: true, popular: false, keywords: ['correx', 'boards', 'signs'],
    channels: { storefront: true, guided: true, advanced: true, pos: false, quote: true },
    guidedJourneyId: 'correx-boards-guided', nextActionLabel: 'Continue to collection', pricingVersion: '2026-10-correx-local-02',
    pricing: { strategy: 'SUPPLIER_MARGIN', minQuantity: 1,
      variants: Object.fromEntries(correxSizes.map(([id, label, price]) => [id, { label: `${label} · single-sided, unmounted`, price }])),
      accessories: {}, artwork: { ready: { label: 'Print-ready artwork', fee: 0 }, check: { label: 'Artwork check', fee: 75 }, design: { label: 'Design help', fee: 250 } }
    },
    fields: [select('variant', 'Board size', correxSizes), count, artwork, brief, file],
    productPage: { headline: 'Choose your Correx board', intro: 'Standard sizes, single-sided printing, supplied without mounting. Ask for a Shop Signs quote for custom sizes, double sides or fitting.', showStartingPrice: true }
  },
  enquiry('pull-up-banners', 'Pull-up Banners', 'Flags & Events', 'Portable printed displays for shops, events and presentations.', [select('kit', 'What do you need?', [['complete', 'Complete printed kit with stand'], ['reprint', 'Replacement print — match my existing stand']]), select('style', 'Stand type', [['economy', 'Economy'], ['deluxe', 'Deluxe']]), count]),
  enquiry('car-magnets', 'Car Magnets', 'Signs & Large Format', 'Removable printed vehicle advertising magnets.', [select('size', 'Magnet size', [['500x300', '500 × 300 mm'], ['custom', 'Custom — enter measurements below']]), { id: 'customSize', type: 'textarea', label: 'Custom dimensions in mm', placeholder: 'Width × height for each magnet, if custom.' }, { ...count, label: 'How many sets of two?', default: 1 }, { id: 'vehicle', type: 'textarea', label: 'Vehicle and placement', placeholder: 'Make/model, door or panel location. Attach a photo for suitability review.' }]),
  enquiry('posters', 'Posters', 'Business Essentials', 'Posters for events, shop offers and displays.', [select('size', 'Poster size', [['a3', 'A3'], ['a2', 'A2'], ['a1', 'A1'], ['a0', 'A0'], ['custom', 'Custom — describe below']]), select('paper', 'Paper / material', [['standard', 'Standard poster paper'], ['photo', 'Photo-quality paper'], ['weatherproof', 'Outdoor / weatherproof — please advise']]), select('finish', 'Finish', [['none', 'Print only'], ['laminated', 'Laminated — confirm availability and price']]), count, { id: 'customSize', type: 'textarea', label: 'Custom dimensions in mm', placeholder: 'Width × height, if custom.' }]),
  enquiry('rigid-signage', 'Shop Signs & Rigid Signage', 'Signs & Large Format', 'Configure a printed sign, frame and installation request.', [
    select('jobType', 'Job type', [['sign', 'Shop sign / rigid board'], ['window-application', 'Shop window vinyl application add-on'], ['vehicle-contravision', 'Car Contravision — vehicle rear window']]),
    select('supplyScope', 'What should we quote?', [['print-and-application', 'Print / sign supply and selected fitting'], ['application-only', 'Application only — I have or will order the print separately']]),
    select('material', 'Sign material', [['unsure', 'Recommend the right material'], ['correx', 'Correx — custom size, double-sided or mounting'], ['chromadek', 'Chromadek steel'], ['acm', 'Aluminium composite'], ['abs', 'ABS plastic'], ['pvc-frame', 'Stretched PVC on a frame'], ['contravision', 'Contravision perforated window vinyl']]),
    ...dimensions, count, sides, select('frame', 'Frame', [['none', 'No frame'], ['steel', 'Steel frame'], ['aluminium', 'Aluminium frame'], ['unsure', 'Please advise']]),
    select('installation', 'Installation', [['supply', 'Supply only'], ['install', 'Install for me — quote after checking site']]),
    { id: 'site', type: 'textarea', label: 'Site / vehicle details', placeholder: 'Address/area, wall or glass surface, mounting height and access; or vehicle make/model and window shape. Add a photo below.' }
  ]),
  {
    id: 'contravision', name: 'Contravision Window Printing', shortName: 'Contravision', category: 'Signs & Large Format',
    description: 'Full-colour perforated window vinyl, supplied as a rectangular print for one panel.',
    plainDescription: 'Enter one panel’s width and height. Print only, minimum 1 m² billed. Application is an optional separately quoted add-on based on the job. Car Contravision needs a vehicle-specific quote.',
    active: true, popular: false, keywords: ['contravision', 'window branding', 'one way vision'],
    channels: { storefront: true, guided: true, pos: true, quote: true }, guidedJourneyId: 'contravision-guided',
    nextActionLabel: 'Continue to collection', pricingVersion: '2026-10-contravision-local-02',
    // Customer selling rate only. The supplier basis stays in staff metadata.
    pricing: { strategy: 'PER_AREA', baseRate: 300, minimumBillableArea: 1, unit: 'm²' },
    fields: [...dimensions,
      { ...select('material', 'Material', [['standard', 'Perforated one-way-vision vinyl']]), options: [{ id: 'standard', label: 'Perforated one-way-vision vinyl', multiplier: 1 }] },
      { ...select('finishing', 'Supply format', [['print-only', 'Rectangular print only — no fitting']]), options: [{ id: 'print-only', label: 'Rectangular print only — no fitting', fee: 0 }] },
      { ...artwork, options: [{ id: 'ready', label: 'My artwork is ready', fee: 0 }, { id: 'check', label: 'Please check my artwork', fee: 75 }, { id: 'design', label: 'I need design help', fee: 250 }] },
      { ...select('turnaround', 'Turnaround', [['standard', 'Standard — production timing confirmed after artwork review']]), options: [{ id: 'standard', label: 'Standard — timing confirmed after artwork review', multiplier: 1 }] }, file],
    productPage: { headline: 'Print your window branding', intro: 'Live price for rectangular print supply. Request shop-window application as an add-on, or a separate Car Contravision quote for a shaped vehicle window.', showStartingPrice: true }
  }
].map(product => ['contravision', 'correx-boards', 'flyers', 'pull-up-banners'].includes(product.id)
  ? { ...product, media: { hero: `/qs-catalogue/${product.id}-v1.webp`, gallery: [] } }
  : product)
export const supplierJourneys = supplierProducts.map(product => ({
  id: product.guidedJourneyId, productId: product.id, title: product.name, intro: product.plainDescription,
  steps: [
    { id: 'specification', eyebrow: 'Step 1', title: 'What do you need?', helper: product.plainDescription, fields: product.fields.filter(f => !['artwork', 'brief', 'file'].includes(f.id)).map(f => f.id) },
    { id: 'artwork', eyebrow: 'Step 2', title: 'What about the design?', helper: 'Send artwork or a reference and add any important details.', fields: product.fields.filter(f => ['artwork', 'brief', 'file'].includes(f.id)).map(f => f.id) },
    { id: 'review', eyebrow: 'Final step', title: 'Check your request', helper: product.pricing.strategy === 'ENQUIRY' ? 'We confirm pricing and delivery or installation before payment.' : 'Check the dimensions. Installation is not included.', type: 'review' }
  ]
}))
