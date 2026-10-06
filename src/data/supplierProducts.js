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
const boardSize = select('size', 'Which size?', [['a2', 'A2'], ['a1', 'A1'], ['custom', 'Custom — describe measurements below']])
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
  enquiry('correx-boards', 'Correx Boards', 'Signs & Large Format', 'Lightweight boards for business notices, directions and promotions.', [boardSize, sides, count, select('mounting', 'Mounting', [['none', 'Board only'], ['eyelets', 'Eyelets — confirm in quote']])]),
  enquiry('pull-up-banners', 'Pull-up Banners', 'Flags & Events', 'Portable printed displays for shops, events and presentations.', [select('kit', 'What do you need?', [['complete', 'Complete printed kit with stand'], ['reprint', 'Replacement print — match my existing stand']]), select('style', 'Stand type', [['economy', 'Economy'], ['deluxe', 'Deluxe']]), count]),
  enquiry('car-magnets', 'Car Magnets', 'Signs & Large Format', 'Removable printed vehicle advertising magnets.', [select('size', 'Magnet size', [['500x300', '500 × 300 mm'], ['custom', 'Custom — describe below']]), { ...count, label: 'How many sets of two?', default: 1 }]),
  enquiry('posters', 'Posters', 'Business Essentials', 'Posters for events, shop offers and displays.', [select('size', 'Poster size', [['a3', 'A3'], ['a2', 'A2'], ['a1', 'A1']]), count]),
  enquiry('rigid-signage', 'Shop Signs & Rigid Signage', 'Signs & Large Format', 'Configure a printed sign, frame and installation request.', [
    select('material', 'Sign material', [['unsure', 'Recommend the right material'], ['chromadek', 'Chromadek steel'], ['acm', 'Aluminium composite'], ['abs', 'ABS plastic'], ['pvc-frame', 'Stretched PVC on a frame']]),
    ...dimensions, count, select('frame', 'Frame', [['none', 'No frame'], ['steel', 'Steel frame'], ['aluminium', 'Aluminium frame'], ['unsure', 'Please advise']]),
    select('installation', 'Installation', [['supply', 'Supply only'], ['install', 'Install for me — quote after checking site']]),
    { id: 'site', type: 'textarea', label: 'Installation site / area', placeholder: 'Area, wall or fence, mounting height and access. Add a photo below.' }
  ]),
  enquiry('folded-leaflets', 'Folded Leaflets & Menus', 'Business Essentials', 'Folded menus, brochures and service leaflets.', [paperSize, select('fold', 'Fold', [['half', 'Half fold'], ['three', 'Three panels'], ['unsure', 'Please advise']]), { ...count, default: 500 }]),
  enquiry('booklets', 'Booklets', 'Business Essentials', 'Printed booklets for programmes, catalogues and information.', [paperSize, { id: 'pages', type: 'number', label: 'Total pages including cover', default: 8, min: 4, step: 4 }, { ...count, default: 100 }]),
  enquiry('notepads', 'Branded Notepads', 'Business Essentials', 'Branded tear-off pads for business use.', [select('sheets', 'Sheets per pad', [['25', '25'], ['50', '50']]), count]),
  enquiry('presentation-folders', 'Presentation Folders', 'Business Essentials', 'Printed folders for proposals and business documents.', [count]),
  enquiry('calendars', 'Branded Calendars', 'Business Essentials', 'Calendars produced to order for your business or campaign.', [select('format', 'Calendar format', [['tent', 'Desk tent'], ['wall', 'Wall'], ['fridge', 'Fridge'], ['wiro', 'Wiro bound'], ['deskpad', 'Desk pad']]), { id: 'year', type: 'number', label: 'Calendar year', default: 2027, min: 2026, max: 2100, step: 1 }, count]),
  enquiry('contravision-installation', 'Contravision with Installation', 'Signs & Large Format', 'Printed window branding with fitting assessed and quoted separately.', [...dimensions, select('application', 'Where will it go?', [['vehicle', 'Vehicle rear window'], ['shop', 'Shop window or door']]), { id: 'site', type: 'textarea', label: 'Vehicle / site details', placeholder: 'Vehicle model or installation address; attach a window photo.' }]),
  {
    id: 'contravision', name: 'Contravision Window Printing', shortName: 'Contravision', category: 'Signs & Large Format',
    description: 'Full-colour perforated window vinyl, supplied as a rectangular print for one panel.',
    plainDescription: 'Enter one panel’s width and height. Print only, minimum 1 m² billed. Shaped trimming and installation need a separate quote.',
    active: true, popular: false, keywords: ['contravision', 'window branding', 'one way vision'],
    channels: { storefront: true, guided: true, pos: true, quote: true }, guidedJourneyId: 'contravision-guided',
    nextActionLabel: 'Continue to collection', pricingVersion: '2026-10-contravision-01',
    // Customer selling rate only. The supplier basis stays in staff metadata.
    pricing: { strategy: 'PER_AREA', baseRate: 414, minimumBillableArea: 1, unit: 'm²' },
    fields: [...dimensions,
      { ...select('material', 'Material', [['standard', 'Perforated one-way-vision vinyl']]), options: [{ id: 'standard', label: 'Perforated one-way-vision vinyl', multiplier: 1 }] },
      { ...select('finishing', 'Supply format', [['print-only', 'Rectangular print only — no fitting']]), options: [{ id: 'print-only', label: 'Rectangular print only — no fitting', fee: 0 }] },
      { ...artwork, options: [{ id: 'ready', label: 'My artwork is ready', fee: 0 }, { id: 'check', label: 'Please check my artwork', fee: 75 }, { id: 'design', label: 'I need design help', fee: 250 }] },
      { ...select('turnaround', 'Turnaround', [['standard', 'Standard — production timing confirmed after artwork review']]), options: [{ id: 'standard', label: 'Standard — timing confirmed after artwork review', multiplier: 1 }] }, file],
    productPage: { headline: 'Print your window branding', intro: 'Print only. Vehicle contour cutting, fitting and installation are quoted separately.', showStartingPrice: true }
  }
]
export const supplierJourneys = supplierProducts.map(product => ({
  id: product.guidedJourneyId, productId: product.id, title: product.name, intro: product.plainDescription,
  steps: [
    { id: 'specification', eyebrow: 'Step 1', title: 'What do you need?', helper: product.plainDescription, fields: product.fields.filter(f => !['artwork', 'brief', 'file'].includes(f.id)).map(f => f.id) },
    { id: 'artwork', eyebrow: 'Step 2', title: 'What about the design?', helper: 'Send artwork or a reference and add any important details.', fields: product.fields.filter(f => ['artwork', 'brief', 'file'].includes(f.id)).map(f => f.id) },
    { id: 'review', eyebrow: 'Final step', title: 'Check your request', helper: product.pricing.strategy === 'ENQUIRY' ? 'We confirm pricing and delivery or installation before payment.' : 'Check the dimensions. Installation is not included.', type: 'review' }
  ]
}))
