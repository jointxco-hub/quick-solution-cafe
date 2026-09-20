export const brand = {
  green: '#008B72',
  orange: '#CC3300',
  lilac: '#D7BFFF'
}

const customerChannels = {
  storefront: true,
  guided: true,
  pos: true,
  quote: true
}

export const products = [
  {
    id: 'pvc-banner',
    name: 'PVC Banner',
    shortName: 'Banner',
    category: 'Signs & Large Format',
    description: 'Custom printed banners for shops, events and promotions.',
    plainDescription: 'Choose the size, finish and artwork help you need.',
    keywords: ['banner', 'sign', 'vinyl', 'shop sign', 'event', 'large format'],
    popular: true,
    active: true,
    channels: { ...customerChannels },
    guidedJourneyId: 'banner-guided',
    nextActionLabel: 'Continue to collection',
    pricingVersion: '2026-09-qsc-02',
    pricing: { strategy: 'PER_AREA', baseRate: 350, minimumBillableArea: 1, unit: 'm²' },
    fields: [
      { id: 'width', type: 'number', label: 'How wide?', shortLabel: 'Width', suffix: 'metres', default: 2, min: 0.1, step: 0.1, required: true },
      { id: 'height', type: 'number', label: 'How high?', shortLabel: 'Height', suffix: 'metres', default: 1, min: 0.1, step: 0.1, required: true },
      {
        id: 'material', type: 'select', label: 'What should we print it on?', shortLabel: 'Banner material', default: 'standard',
        options: [
          { id: 'standard', label: 'Standard PVC', helper: 'Good for most indoor and outdoor jobs.', multiplier: 1 },
          { id: 'premium', label: 'Premium PVC', helper: 'A heavier option for a more substantial finish.', multiplier: 1.25 },
          { id: 'mesh', label: 'Mesh banner', helper: 'Useful where wind needs to pass through.', multiplier: 1.35 }
        ]
      },
      {
        id: 'finishing', type: 'select', label: 'How should we finish the edges?', shortLabel: 'Finishing', default: 'hem-eyelets',
        options: [
          { id: 'none', label: 'No finishing', fee: 0 },
          { id: 'eyelets', label: 'Eyelets', helper: 'Metal rings for tying or mounting.', fee: 55 },
          { id: 'hem', label: 'Hemmed edges', helper: 'Folded edges for extra strength.', fee: 70 },
          { id: 'hem-eyelets', label: 'Hem + eyelets', helper: 'Recommended for most outdoor banners.', fee: 110 }
        ]
      },
      {
        id: 'artwork', type: 'select', label: 'What is happening with the design?', shortLabel: 'Artwork', default: 'ready',
        options: [
          { id: 'ready', label: 'My artwork is ready', fee: 0 },
          { id: 'check', label: 'Please check my artwork', fee: 75 },
          { id: 'design', label: 'I need help with the design', fee: 250 }
        ]
      },
      {
        id: 'turnaround', type: 'select', label: 'When do you need it?', default: 'standard',
        options: [
          { id: 'standard', label: 'Standard turnaround', multiplier: 1 },
          { id: 'express', label: 'Express — where available', multiplier: 1.2 }
        ]
      },
      { id: 'file', type: 'file', label: 'Artwork file', help: 'Optional for now. PDF, JPG or PNG works best.' }
    ]
  },
  {
    id: 'vinyl-stickers',
    name: 'Vinyl Stickers & Labels',
    shortName: 'Stickers',
    category: 'Labels & Packaging',
    description: 'Custom vinyl stickers and labels for bottles, packaging, windows and product branding.',
    plainDescription: 'Choose the print area, artwork help and whether you need print only or print + cut.',
    keywords: ['vinyl sticker', 'stickers', 'labels', 'product labels', 'bottle labels', 'packaging', 'window sticker', 'branding'],
    popular: true,
    active: true,
    channels: { ...customerChannels },
    guidedJourneyId: 'sticker-guided',
    nextActionLabel: 'Continue to collection',
    pricingVersion: '2026-09-qsc-05',
    pricing: { strategy: 'PER_AREA', baseRate: 350, minimumBillableArea: 1, unit: 'm²' },
    fields: [
      { id: 'width', type: 'number', label: 'How wide is the total print area?', shortLabel: 'Width', suffix: 'metres', default: 1, min: 0.1, step: 0.1, required: true },
      { id: 'height', type: 'number', label: 'How high is the total print area?', shortLabel: 'Height', suffix: 'metres', default: 1, min: 0.1, step: 0.1, required: true },
      {
        id: 'material', type: 'select', label: 'Which vinyl should we use?', shortLabel: 'Vinyl', default: 'standard',
        options: [
          { id: 'standard', label: 'White adhesive vinyl', helper: 'A versatile everyday vinyl for bottles, packaging, windows and product branding.', multiplier: 1 }
        ]
      },
      {
        id: 'finishing', type: 'segmented', label: 'Do you need the stickers cut?', shortLabel: 'Cutting', default: 'print-only',
        options: [
          { id: 'print-only', label: 'Print only', helper: 'Supplied as printed vinyl for you to trim or use as a sheet.', fee: 0 },
          { id: 'print-cut', label: 'Print + cut', helper: 'We print and cut the stickers for you. Adds R100.', fee: 100 }
        ]
      },
      {
        id: 'artwork', type: 'select', label: 'What is happening with the design?', shortLabel: 'Artwork', default: 'ready',
        options: [
          { id: 'ready', label: 'My artwork is ready', fee: 0 },
          { id: 'check', label: 'Please check my artwork', fee: 75 },
          { id: 'design', label: 'I need help with the design', fee: 250 }
        ]
      },
      {
        id: 'turnaround', type: 'select', label: 'When do you need it?', default: 'standard',
        options: [
          { id: 'standard', label: 'Standard turnaround', multiplier: 1 },
          { id: 'express', label: 'Express — where available', multiplier: 1.2 }
        ]
      },
      { id: 'file', type: 'file', label: 'Artwork file', help: 'Optional for now. PDF, PNG or high-resolution JPG works best.' }
    ]
  },
  {
    id: 'a4-print',
    name: 'Document Printing',
    shortName: 'Documents',
    category: 'Quick Print',
    description: 'Homework, CVs, forms and everyday documents.',
    plainDescription: 'Upload your file, choose copies and collect when ready.',
    keywords: ['print', 'document', 'homework', 'school', 'cv', 'resume', 'form', 'pdf', 'a4', 'copy', 'photocopy'],
    popular: true,
    active: true,
    channels: { ...customerChannels },
    guidedJourneyId: 'document-guided',
    nextActionLabel: 'Choose collection',
    pricingVersion: '2026-09-qsc-02',
    pricing: { strategy: 'PER_PAGE' },
    fields: [
      { id: 'file', type: 'file', label: 'Upload your documents', help: 'Select several files at once. PDF is best. DOCX, JPG and PNG are also accepted.', multiple: true, maxFiles: 25 },
      { id: 'pages', type: 'number', label: 'A4 pages to print', shortLabel: 'Pages to print', default: 0, min: 0, step: 1, required: true },
      { id: 'copies', type: 'number', label: 'How many copies do you need?', shortLabel: 'Copies', default: 1, min: 1, step: 1, required: true },
      {
        id: 'printMode', type: 'segmented', label: 'How should we print it?', shortLabel: 'Print colour', default: 'bw',
        options: [
          { id: 'bw', label: 'Black & white', helper: 'Best for CVs, homework and forms.', rate: 2 },
          { id: 'colour', label: 'Colour', helper: 'Use when images or colour matter.', rate: 7.5 }
        ]
      },
      {
        id: 'sides', type: 'segmented', label: 'Do you want printing on one side or both?', shortLabel: 'Paper sides', default: 'single',
        options: [
          { id: 'single', label: 'One side', multiplier: 1 },
          { id: 'double', label: 'Both sides', helper: 'Uses less paper when suitable.', multiplier: 0.95 }
        ]
      },
      {
        id: 'finish', type: 'select', label: 'Do you need anything else?', shortLabel: 'Finish', default: 'none',
        options: [
          { id: 'none', label: 'Nothing else', fee: 0 },
          { id: 'staple', label: 'Staple it', fee: 2 },
          { id: 'clear-sleeve', label: 'Put it in a clear sleeve', fee: 5 }
        ]
      }
    ]
  },
  {
    id: 'business-cards',
    name: 'Business Cards',
    shortName: 'Business cards',
    category: 'Business Essentials',
    description: 'Professional cards with clear quantity-based pricing.',
    plainDescription: 'Choose quantity, stock and whether you need design help.',
    keywords: ['business card', 'cards', 'company', 'startup', 'entrepreneur', 'brand'],
    popular: true,
    active: true,
    channels: { ...customerChannels },
    guidedJourneyId: 'business-card-guided',
    nextActionLabel: 'Continue to collection',
    pricingVersion: '2026-09-qsc-02',
    pricing: { strategy: 'TIERED' },
    fields: [
      {
        id: 'quantity', type: 'segmented', label: 'How many cards do you need?', shortLabel: 'Quantity', default: '100',
        options: [
          { id: '100', label: '100', total: 180 },
          { id: '250', label: '250', total: 260 },
          { id: '500', label: '500', total: 390 },
          { id: '1000', label: '1,000', total: 650 }
        ]
      },
      {
        id: 'stock', type: 'select', label: 'What card feel do you want?', shortLabel: 'Card stock', default: 'standard',
        options: [
          { id: 'standard', label: 'Standard premium stock', multiplier: 1 },
          { id: 'thick', label: 'Extra-thick stock', multiplier: 1.2 }
        ]
      },
      {
        id: 'finish', type: 'select', label: 'Do you want a special finish?', shortLabel: 'Finish', default: 'standard',
        options: [
          { id: 'standard', label: 'Standard finish', fee: 0 },
          { id: 'matt', label: 'Matt lamination', fee: 90 },
          { id: 'gloss', label: 'Gloss lamination', fee: 80 }
        ]
      },
      {
        id: 'artwork', type: 'select', label: 'Do you already have a design?', shortLabel: 'Design', default: 'ready',
        options: [
          { id: 'ready', label: 'My design is ready', fee: 0 },
          { id: 'check', label: 'Please check my design', fee: 75 },
          { id: 'design', label: 'Design it for me', fee: 250 }
        ]
      },
      { id: 'file', type: 'file', label: 'Design file', help: 'Optional now. You can add it before checkout.' }
    ]
  },
  {
    id: 'printed-tshirt',
    name: 'Printed T-shirt',
    shortName: 'T-shirt',
    category: 'Clothing & Merch',
    description: 'Bring your own garment or choose a Joint X blank.',
    plainDescription: 'Choose the shirt, print size and quantity without print jargon.',
    keywords: ['shirt', 't-shirt', 'tshirt', 'clothing', 'merch', 'dtf', 'uniform'],
    popular: true,
    active: true,
    channels: { ...customerChannels },
    guidedJourneyId: 'tshirt-guided',
    nextActionLabel: 'Continue to collection',
    pricingVersion: '2026-09-qsc-02',
    pricing: { strategy: 'CONFIGURABLE' },
    fields: [
      { id: 'quantity', type: 'number', label: 'How many shirts do you need?', shortLabel: 'Quantity', default: 1, min: 1, step: 1, required: true },
      {
        id: 'garment', type: 'select', label: 'Which T-shirt should we use?', shortLabel: 'T-shirt', default: 'jointx-220',
        options: [
          { id: 'own', label: 'I am bringing my own T-shirt', unitFee: 0 },
          { id: 'jointx-220', label: 'Joint X premium T-shirt', helper: '220gsm', unitFee: 95 },
          { id: 'jointx-300', label: 'Joint X heavyweight T-shirt', helper: '300gsm', unitFee: 145 }
        ]
      },
      {
        id: 'frontPrint', type: 'select', label: 'How big should the front print be?', shortLabel: 'Front print', default: 'a4',
        options: [
          { id: 'none', label: 'No front print', unitFee: 0 },
          { id: 'pocket', label: 'Small / pocket size', unitFee: 55 },
          { id: 'a4', label: 'Medium', helper: 'About A4', unitFee: 75 },
          { id: 'a3', label: 'Large', helper: 'About A3', unitFee: 95 }
        ]
      },
      {
        id: 'backPrint', type: 'select', label: 'Do you need a back print?', shortLabel: 'Back print', default: 'none',
        options: [
          { id: 'none', label: 'No back print', unitFee: 0 },
          { id: 'a4', label: 'Medium', helper: 'About A4', unitFee: 75 },
          { id: 'a3', label: 'Large', helper: 'About A3', unitFee: 95 }
        ]
      },
      {
        id: 'artwork', type: 'select', label: 'What is happening with the artwork?', shortLabel: 'Artwork', default: 'ready',
        options: [
          { id: 'ready', label: 'My artwork is ready', fee: 0 },
          { id: 'check', label: 'Please check my artwork', fee: 75 },
          { id: 'design', label: 'I need help with the design', fee: 250 }
        ]
      },
      { id: 'file', type: 'file', label: 'Artwork file', help: 'PNG with a transparent background is ideal.' }
    ]
  },
  {
    id: 'media-services',
    name: 'Photography & Video',
    shortName: 'Photo + Video',
    category: 'Photo & Video',
    description: 'From quick café shoots to full on-location photo and video production.',
    plainDescription: 'Choose what you need, where the shoot should happen and which medium should lead.',
    keywords: ['photography', 'photo', 'video', 'videography', 'headshot', 'id photo', 'product photography', 'content', 'reels', 'event', 'matric dance', 'onsite shoot'],
    popular: true,
    active: true,
    serviceType: 'media',
    channels: { ...customerChannels, advanced: false },
    guidedJourneyId: 'media-guided',
    nextActionLabel: 'Send request',
    pricingVersion: '2026-09-qsc-06',
    pricing: { strategy: 'ENQUIRY', quoteRequired: true },
    fields: [
      {
        id: 'mediumFocus',
        type: 'segmented',
        label: 'What do you need?',
        shortLabel: 'Media focus',
        default: 'balanced',
        options: [
          { id: 'photo-only', label: 'Photography only', helper: 'Still photography is the full focus.' },
          { id: 'video-only', label: 'Video only', helper: 'Video is the full focus.' },
          { id: 'photo-led', label: 'Photo-led', helper: 'Photography is primary with a few supporting video clips.' },
          { id: 'video-led', label: 'Video-led', helper: 'Video is primary with a smaller set of supporting photos.' },
          { id: 'balanced', label: 'Photo + video', helper: 'A balanced mix of photography and video.' }
        ]
      },
      {
        id: 'shootType',
        type: 'select',
        label: 'What are we shooting?',
        shortLabel: 'Shoot type',
        default: 'business-content',
        options: [
          { id: 'id-passport', label: 'ID / passport photos' },
          { id: 'headshot', label: 'Professional headshot / CV / LinkedIn' },
          { id: 'products', label: 'Products / ecommerce' },
          { id: 'business-content', label: 'Business / brand content' },
          { id: 'social-content', label: 'Social media / reels content' },
          { id: 'staff-team', label: 'Staff / team portraits' },
          { id: 'event', label: 'Event coverage' },
          { id: 'matric-dance', label: 'Matric dance' },
          { id: 'property-location', label: 'Property / location' },
          { id: 'campaign', label: 'Campaign / commercial shoot' },
          { id: 'other', label: 'Something else' }
        ]
      },
      {
        id: 'shootLocation',
        type: 'segmented',
        label: 'Where should the shoot happen?',
        shortLabel: 'Shoot location',
        default: 'cafe',
        options: [
          { id: 'cafe', label: 'At Quick Solution Café', helper: 'Come to us for quick portraits, headshots, product shots and short content sessions.' },
          { id: 'client-location', label: 'Shoot at my location', helper: 'We send our photographer or videographer to your home, office, shop, venue or chosen location.' },
          { id: 'onsite-team', label: 'Send a photo / video team', helper: 'For bigger coverage, events, campaigns or shoots that need more than one person.' }
        ]
      },
      {
        id: 'crew',
        type: 'select',
        label: 'Who should we send?',
        shortLabel: 'Crew',
        default: 'recommend',
        options: [
          { id: 'photographer', label: 'Photographer' },
          { id: 'videographer', label: 'Videographer' },
          { id: 'photo-video-duo', label: 'Photographer + videographer' },
          { id: 'content-team', label: 'Small content team' },
          { id: 'recommend', label: 'Not sure — recommend the right setup' }
        ]
      },
      {
        id: 'duration',
        type: 'select',
        label: 'Roughly how long do you think you need?',
        shortLabel: 'Duration',
        default: 'not-sure',
        options: [
          { id: 'under-1h', label: 'Under 1 hour' },
          { id: '1h', label: 'About 1 hour' },
          { id: '2h', label: 'About 2 hours' },
          { id: 'half-day', label: 'Half day' },
          { id: 'full-day', label: 'Full day' },
          { id: 'not-sure', label: 'Not sure yet' }
        ]
      },
      {
        id: 'preferredDate',
        type: 'date',
        label: 'Preferred shoot date',
        shortLabel: 'Preferred date',
        default: ''
      },
      {
        id: 'preferredTime',
        type: 'time',
        label: 'Preferred start time',
        shortLabel: 'Preferred time',
        default: ''
      },
      {
        id: 'shootAddress',
        type: 'text',
        label: 'Shoot address / area',
        shortLabel: 'Address',
        placeholder: 'Area, venue or full address',
        help: 'If you are coming to the Café, you can leave this blank.',
        default: ''
      },
      {
        id: 'deliverables',
        type: 'textarea',
        label: 'What do you want us to deliver?',
        shortLabel: 'Deliverables',
        placeholder: 'Example: one 60-second promo video, 3 reels and 15 edited photos.',
        help: 'Tell us the outcome rather than technical camera details.',
        default: ''
      },
      {
        id: 'file',
        type: 'file',
        label: 'Reference / moodboard',
        help: 'Optional. Upload an image or PDF reference if it helps explain the look you want.'
      }
    ]
  },
  {
  "id": "flags",
  "name": "Flags & Promotional Flags",
  "shortName": "Flags",
  "category": "Flags & Events",
  "description": "Telescopic, Shark Fin and Curved flags for shopfronts, stands and events.",
  "plainDescription": "Choose the flag style, size, sides and whether you need the full kit or just a replacement print.",
  "keywords": [
    "flag",
    "flags",
    "promotional flag",
    "feather flag",
    "teardrop flag",
    "telescopic banner",
    "shark fin banner",
    "event flag",
    "outdoor flag"
  ],
  "popular": false,
  "active": true,
  "channels": {
    "storefront": true,
    "guided": true,
    "pos": true,
    "quote": true
  },
  "guidedJourneyId": "flags-guided",
  "nextActionLabel": "Continue to collection",
  "pricingVersion": "2026-09-qsc-14a",
  "pricing": {
    "strategy": "SUPPLIER_MARGIN",
    "minQuantity": 1,
    "variants": {
      "telescopic-2m-ss-full": {
        "label": "Telescopic flag — 2.0m — single-sided — full kit (print + system + ground spike + carry bag)",
        "price": 990
      },
      "telescopic-3m-ss-full": {
        "label": "Telescopic flag — 3.0m — single-sided — full kit (print + system + ground spike + carry bag)",
        "price": 1190
      },
      "telescopic-4m-ss-full": {
        "label": "Telescopic flag — 4.0m — single-sided — full kit (print + system + ground spike + carry bag)",
        "price": 1390
      },
      "telescopic-2m-ds-full": {
        "label": "Telescopic flag — 2.0m — double-sided — full kit (print + system + ground spike + carry bag)",
        "price": 1390
      },
      "telescopic-3m-ds-full": {
        "label": "Telescopic flag — 3.0m — double-sided — full kit (print + system + ground spike + carry bag)",
        "price": 1750
      },
      "telescopic-4m-ds-full": {
        "label": "Telescopic flag — 4.0m — double-sided — full kit (print + system + ground spike + carry bag)",
        "price": 2100
      },
      "telescopic-2m-ss-reprint": {
        "label": "Telescopic flag — 2.0m — single-sided — replacement print only",
        "price": 470
      },
      "telescopic-3m-ss-reprint": {
        "label": "Telescopic flag — 3.0m — single-sided — replacement print only",
        "price": 650
      },
      "telescopic-4m-ss-reprint": {
        "label": "Telescopic flag — 4.0m — single-sided — replacement print only",
        "price": 790
      },
      "telescopic-2m-ds-reprint": {
        "label": "Telescopic flag — 2.0m — double-sided — replacement print only",
        "price": 900
      },
      "telescopic-3m-ds-reprint": {
        "label": "Telescopic flag — 3.0m — double-sided — replacement print only",
        "price": 1150
      },
      "telescopic-4m-ds-reprint": {
        "label": "Telescopic flag — 4.0m — double-sided — replacement print only",
        "price": 1450
      },
      "sharkfin-2m-ss-full": {
        "label": "Shark Fin flag — 2.0m — single-sided — full kit (print + system + ground spike + carry bag)",
        "price": 990
      },
      "sharkfin-3m-ss-full": {
        "label": "Shark Fin flag — 3.0m — single-sided — full kit (print + system + ground spike + carry bag)",
        "price": 1190
      },
      "sharkfin-4m-ss-full": {
        "label": "Shark Fin flag — 4.0m — single-sided — full kit (print + system + ground spike + carry bag)",
        "price": 1390
      },
      "sharkfin-2m-ds-full": {
        "label": "Shark Fin flag — 2.0m — double-sided — full kit (print + system + ground spike + carry bag)",
        "price": 1390
      },
      "sharkfin-3m-ds-full": {
        "label": "Shark Fin flag — 3.0m — double-sided — full kit (print + system + ground spike + carry bag)",
        "price": 1750
      },
      "sharkfin-4m-ds-full": {
        "label": "Shark Fin flag — 4.0m — double-sided — full kit (print + system + ground spike + carry bag)",
        "price": 2100
      },
      "sharkfin-2m-ss-reprint": {
        "label": "Shark Fin flag — 2.0m — single-sided — replacement print only",
        "price": 470
      },
      "sharkfin-3m-ss-reprint": {
        "label": "Shark Fin flag — 3.0m — single-sided — replacement print only",
        "price": 650
      },
      "sharkfin-4m-ss-reprint": {
        "label": "Shark Fin flag — 4.0m — single-sided — replacement print only",
        "price": 790
      },
      "sharkfin-2m-ds-reprint": {
        "label": "Shark Fin flag — 2.0m — double-sided — replacement print only",
        "price": 900
      },
      "sharkfin-3m-ds-reprint": {
        "label": "Shark Fin flag — 3.0m — double-sided — replacement print only",
        "price": 1150
      },
      "sharkfin-4m-ds-reprint": {
        "label": "Shark Fin flag — 4.0m — double-sided — replacement print only",
        "price": 1450
      },
      "curved-2m-ss-full": {
        "label": "Curved flag — 2.0m — single-sided — full kit (print + system + ground spike + carry bag)",
        "price": 1050
      },
      "curved-3m-ss-full": {
        "label": "Curved flag — 3.0m — single-sided — full kit (print + system + ground spike + carry bag)",
        "price": 1250
      },
      "curved-4m-ss-full": {
        "label": "Curved flag — 4.0m — single-sided — full kit (print + system + ground spike + carry bag)",
        "price": 1500
      },
      "curved-2m-ds-full": {
        "label": "Curved flag — 2.0m — double-sided — full kit (print + system + ground spike + carry bag)",
        "price": 1500
      },
      "curved-3m-ds-full": {
        "label": "Curved flag — 3.0m — double-sided — full kit (print + system + ground spike + carry bag)",
        "price": 1850
      },
      "curved-4m-ds-full": {
        "label": "Curved flag — 4.0m — double-sided — full kit (print + system + ground spike + carry bag)",
        "price": 2190
      },
      "curved-2m-ss-reprint": {
        "label": "Curved flag — 2.0m — single-sided — replacement print only",
        "price": 500
      },
      "curved-3m-ss-reprint": {
        "label": "Curved flag — 3.0m — single-sided — replacement print only",
        "price": 700
      },
      "curved-4m-ss-reprint": {
        "label": "Curved flag — 4.0m — single-sided — replacement print only",
        "price": 850
      },
      "curved-2m-ds-reprint": {
        "label": "Curved flag — 2.0m — double-sided — replacement print only",
        "price": 950
      },
      "curved-3m-ds-reprint": {
        "label": "Curved flag — 3.0m — double-sided — replacement print only",
        "price": 1300
      },
      "curved-4m-ds-reprint": {
        "label": "Curved flag — 4.0m — double-sided — replacement print only",
        "price": 1500
      }
    },
    "accessories": {
      "cross-base": {
        "label": "Cross base",
        "price": 500
      },
      "ground-spike": {
        "label": "Ground spike",
        "price": 160
      },
      "water-bag": {
        "label": "Water weight bag",
        "price": 390
      },
      "wall-bracket": {
        "label": "Wall bracket",
        "price": 300
      },
      "cluster-flag-stand": {
        "label": "Cluster flag stand (holds 4 flags)",
        "price": 1190
      }
    },
    "artwork": {
      "ready": {
        "label": "My artwork is ready",
        "fee": 0
      },
      "check": {
        "label": "Please check my artwork",
        "fee": 75
      },
      "design": {
        "label": "I need help with the design",
        "fee": 250
      }
    }
  },
  "fields": [
    {
      "id": "variant",
      "type": "select",
      "label": "Which flag would you like?",
      "shortLabel": "Flag",
      "options": [
        {
          "id": "telescopic-2m-ss-full",
          "label": "Telescopic flag — 2.0m — single-sided — full kit (print + system + ground spike + carry bag)"
        },
        {
          "id": "telescopic-3m-ss-full",
          "label": "Telescopic flag — 3.0m — single-sided — full kit (print + system + ground spike + carry bag)"
        },
        {
          "id": "telescopic-4m-ss-full",
          "label": "Telescopic flag — 4.0m — single-sided — full kit (print + system + ground spike + carry bag)"
        },
        {
          "id": "telescopic-2m-ds-full",
          "label": "Telescopic flag — 2.0m — double-sided — full kit (print + system + ground spike + carry bag)"
        },
        {
          "id": "telescopic-3m-ds-full",
          "label": "Telescopic flag — 3.0m — double-sided — full kit (print + system + ground spike + carry bag)"
        },
        {
          "id": "telescopic-4m-ds-full",
          "label": "Telescopic flag — 4.0m — double-sided — full kit (print + system + ground spike + carry bag)"
        },
        {
          "id": "telescopic-2m-ss-reprint",
          "label": "Telescopic flag — 2.0m — single-sided — replacement print only"
        },
        {
          "id": "telescopic-3m-ss-reprint",
          "label": "Telescopic flag — 3.0m — single-sided — replacement print only"
        },
        {
          "id": "telescopic-4m-ss-reprint",
          "label": "Telescopic flag — 4.0m — single-sided — replacement print only"
        },
        {
          "id": "telescopic-2m-ds-reprint",
          "label": "Telescopic flag — 2.0m — double-sided — replacement print only"
        },
        {
          "id": "telescopic-3m-ds-reprint",
          "label": "Telescopic flag — 3.0m — double-sided — replacement print only"
        },
        {
          "id": "telescopic-4m-ds-reprint",
          "label": "Telescopic flag — 4.0m — double-sided — replacement print only"
        },
        {
          "id": "sharkfin-2m-ss-full",
          "label": "Shark Fin flag — 2.0m — single-sided — full kit (print + system + ground spike + carry bag)"
        },
        {
          "id": "sharkfin-3m-ss-full",
          "label": "Shark Fin flag — 3.0m — single-sided — full kit (print + system + ground spike + carry bag)"
        },
        {
          "id": "sharkfin-4m-ss-full",
          "label": "Shark Fin flag — 4.0m — single-sided — full kit (print + system + ground spike + carry bag)"
        },
        {
          "id": "sharkfin-2m-ds-full",
          "label": "Shark Fin flag — 2.0m — double-sided — full kit (print + system + ground spike + carry bag)"
        },
        {
          "id": "sharkfin-3m-ds-full",
          "label": "Shark Fin flag — 3.0m — double-sided — full kit (print + system + ground spike + carry bag)"
        },
        {
          "id": "sharkfin-4m-ds-full",
          "label": "Shark Fin flag — 4.0m — double-sided — full kit (print + system + ground spike + carry bag)"
        },
        {
          "id": "sharkfin-2m-ss-reprint",
          "label": "Shark Fin flag — 2.0m — single-sided — replacement print only"
        },
        {
          "id": "sharkfin-3m-ss-reprint",
          "label": "Shark Fin flag — 3.0m — single-sided — replacement print only"
        },
        {
          "id": "sharkfin-4m-ss-reprint",
          "label": "Shark Fin flag — 4.0m — single-sided — replacement print only"
        },
        {
          "id": "sharkfin-2m-ds-reprint",
          "label": "Shark Fin flag — 2.0m — double-sided — replacement print only"
        },
        {
          "id": "sharkfin-3m-ds-reprint",
          "label": "Shark Fin flag — 3.0m — double-sided — replacement print only"
        },
        {
          "id": "sharkfin-4m-ds-reprint",
          "label": "Shark Fin flag — 4.0m — double-sided — replacement print only"
        },
        {
          "id": "curved-2m-ss-full",
          "label": "Curved flag — 2.0m — single-sided — full kit (print + system + ground spike + carry bag)"
        },
        {
          "id": "curved-3m-ss-full",
          "label": "Curved flag — 3.0m — single-sided — full kit (print + system + ground spike + carry bag)"
        },
        {
          "id": "curved-4m-ss-full",
          "label": "Curved flag — 4.0m — single-sided — full kit (print + system + ground spike + carry bag)"
        },
        {
          "id": "curved-2m-ds-full",
          "label": "Curved flag — 2.0m — double-sided — full kit (print + system + ground spike + carry bag)"
        },
        {
          "id": "curved-3m-ds-full",
          "label": "Curved flag — 3.0m — double-sided — full kit (print + system + ground spike + carry bag)"
        },
        {
          "id": "curved-4m-ds-full",
          "label": "Curved flag — 4.0m — double-sided — full kit (print + system + ground spike + carry bag)"
        },
        {
          "id": "curved-2m-ss-reprint",
          "label": "Curved flag — 2.0m — single-sided — replacement print only"
        },
        {
          "id": "curved-3m-ss-reprint",
          "label": "Curved flag — 3.0m — single-sided — replacement print only"
        },
        {
          "id": "curved-4m-ss-reprint",
          "label": "Curved flag — 4.0m — single-sided — replacement print only"
        },
        {
          "id": "curved-2m-ds-reprint",
          "label": "Curved flag — 2.0m — double-sided — replacement print only"
        },
        {
          "id": "curved-3m-ds-reprint",
          "label": "Curved flag — 3.0m — double-sided — replacement print only"
        },
        {
          "id": "curved-4m-ds-reprint",
          "label": "Curved flag — 4.0m — double-sided — replacement print only"
        }
      ]
    },
    {
      "id": "quantity",
      "type": "number",
      "label": "How many?",
      "shortLabel": "Quantity",
      "default": 1,
      "min": 1,
      "step": 1,
      "required": true
    },
    {
      "id": "artwork",
      "type": "select",
      "label": "What is happening with the design?",
      "shortLabel": "Artwork",
      "default": "ready",
      "options": [
        {
          "id": "ready",
          "label": "My artwork is ready"
        },
        {
          "id": "check",
          "label": "Please check my artwork"
        },
        {
          "id": "design",
          "label": "I need help with the design"
        }
      ]
    },
    {
      "id": "file",
      "type": "file",
      "label": "Artwork file",
      "help": "PDF or high-resolution PNG/JPG works best."
    }
  ]
},
  {
  "id": "gazebos",
  "name": "Gazebos & Event Displays",
  "shortName": "Gazebos",
  "category": "Flags & Events",
  "description": "Branded steel and aluminium gazebos for markets, activations and events.",
  "plainDescription": "Choose the frame, size and whether you need the full kit or just a replacement canopy print.",
  "keywords": [
    "gazebo",
    "event display",
    "market stand",
    "branded gazebo",
    "pop up tent",
    "event branding"
  ],
  "popular": false,
  "active": true,
  "channels": {
    "storefront": true,
    "guided": true,
    "pos": true,
    "quote": true
  },
  "guidedJourneyId": "gazebos-guided",
  "nextActionLabel": "Continue to collection",
  "pricingVersion": "2026-09-qsc-14b",
  "pricing": {
    "strategy": "SUPPLIER_MARGIN",
    "minQuantity": 1,
    "variants": {
      "steel-2x2-full": {
        "label": "Steel gazebo — 2m × 2m — full kit (print + system + carry bag + toolkit)",
        "price": 5500
      },
      "steel-2x2-reprint": {
        "label": "Steel gazebo — 2m × 2m — replacement canopy print only",
        "price": 2700
      },
      "steel-3x3-standard-full": {
        "label": "Steel gazebo — 3m × 3m standard — full kit (print + system + carry bag + toolkit)",
        "price": 6700
      },
      "steel-3x3-standard-reprint": {
        "label": "Steel gazebo — 3m × 3m standard — replacement canopy print only",
        "price": 4300
      },
      "steel-3x3-deluxe-full": {
        "label": "Steel gazebo — 3m × 3m deluxe — full kit (print + system + carry bag + toolkit)",
        "price": 7700
      },
      "steel-3x3-deluxe-reprint": {
        "label": "Steel gazebo — 3m × 3m deluxe — replacement canopy print only",
        "price": 4300
      },
      "aluminium-2x2-full": {
        "label": "Aluminium gazebo — 2m × 2m — full kit (print + system + carry bag + toolkit)",
        "price": 6500
      },
      "aluminium-2x2-reprint": {
        "label": "Aluminium gazebo — 2m × 2m — replacement canopy print only",
        "price": 2700
      },
      "aluminium-3x3-standard-full": {
        "label": "Aluminium gazebo — 3m × 3m standard — full kit (print + system + carry bag + toolkit)",
        "price": 7990
      },
      "aluminium-3x3-standard-reprint": {
        "label": "Aluminium gazebo — 3m × 3m standard — replacement canopy print only",
        "price": 4300
      },
      "aluminium-3x3-deluxe-full": {
        "label": "Aluminium gazebo — 3m × 3m deluxe — full kit (print + system + carry bag + toolkit)",
        "price": 8900
      },
      "aluminium-3x3-deluxe-reprint": {
        "label": "Aluminium gazebo — 3m × 3m deluxe — replacement canopy print only",
        "price": 4300
      },
      "aluminium-3x4.5-deluxe-full": {
        "label": "Aluminium gazebo — 3m × 4.5m deluxe — full kit (print + system + carry bag + toolkit)",
        "price": 12990
      },
      "aluminium-3x4.5-deluxe-reprint": {
        "label": "Aluminium gazebo — 3m × 4.5m deluxe — replacement canopy print only",
        "price": 5790
      },
      "aluminium-3x6-deluxe-full": {
        "label": "Aluminium gazebo — 3m × 6m deluxe — full kit (print + system + carry bag + toolkit)",
        "price": 16590
      },
      "aluminium-3x6-deluxe-reprint": {
        "label": "Aluminium gazebo — 3m × 6m deluxe — replacement canopy print only",
        "price": 7390
      }
    },
    "accessories": {
      "wall-2x2-half": {
        "label": "2m × 2m half wall",
        "price": 650
      },
      "wall-2x2-full": {
        "label": "2m × 2m full wall",
        "price": 1190
      },
      "wall-3x3-half": {
        "label": "3m × 3m half wall",
        "price": 850
      },
      "wall-3x3-full": {
        "label": "3m × 3m full wall",
        "price": 1650
      },
      "wall-3x4.5-full": {
        "label": "3m × 4.5m full wall",
        "price": 2500
      },
      "wall-3x6-full": {
        "label": "3m × 6m full wall",
        "price": 3300
      },
      "wall-window": {
        "label": "Window add-on for a wall",
        "price": 250
      },
      "wall-door": {
        "label": "Door with zip add-on for a wall",
        "price": 300
      },
      "rubber-weight": {
        "label": "Rubber weight",
        "price": 690
      },
      "sandbag-set-4": {
        "label": "Weight sandbag set of 4",
        "price": 680
      },
      "wheely-bag-2-3m": {
        "label": "Wheely bag (2m or 3m gazebo)",
        "price": 750
      },
      "wheely-bag-4-5m": {
        "label": "Wheely bag (4.5m gazebo)",
        "price": 900
      },
      "wheely-bag-6m": {
        "label": "Wheely bag (6m gazebo)",
        "price": 990
      }
    },
    "artwork": {
      "ready": {
        "label": "My artwork is ready",
        "fee": 0
      },
      "check": {
        "label": "Please check my artwork",
        "fee": 75
      },
      "design": {
        "label": "I need help with the design",
        "fee": 250
      }
    }
  },
  "fields": [
    {
      "id": "variant",
      "type": "select",
      "label": "Which gazebo would you like?",
      "shortLabel": "Gazebo",
      "options": [
        {
          "id": "steel-2x2-full",
          "label": "Steel gazebo — 2m × 2m — full kit (print + system + carry bag + toolkit)"
        },
        {
          "id": "steel-2x2-reprint",
          "label": "Steel gazebo — 2m × 2m — replacement canopy print only"
        },
        {
          "id": "steel-3x3-standard-full",
          "label": "Steel gazebo — 3m × 3m standard — full kit (print + system + carry bag + toolkit)"
        },
        {
          "id": "steel-3x3-standard-reprint",
          "label": "Steel gazebo — 3m × 3m standard — replacement canopy print only"
        },
        {
          "id": "steel-3x3-deluxe-full",
          "label": "Steel gazebo — 3m × 3m deluxe — full kit (print + system + carry bag + toolkit)"
        },
        {
          "id": "steel-3x3-deluxe-reprint",
          "label": "Steel gazebo — 3m × 3m deluxe — replacement canopy print only"
        },
        {
          "id": "aluminium-2x2-full",
          "label": "Aluminium gazebo — 2m × 2m — full kit (print + system + carry bag + toolkit)"
        },
        {
          "id": "aluminium-2x2-reprint",
          "label": "Aluminium gazebo — 2m × 2m — replacement canopy print only"
        },
        {
          "id": "aluminium-3x3-standard-full",
          "label": "Aluminium gazebo — 3m × 3m standard — full kit (print + system + carry bag + toolkit)"
        },
        {
          "id": "aluminium-3x3-standard-reprint",
          "label": "Aluminium gazebo — 3m × 3m standard — replacement canopy print only"
        },
        {
          "id": "aluminium-3x3-deluxe-full",
          "label": "Aluminium gazebo — 3m × 3m deluxe — full kit (print + system + carry bag + toolkit)"
        },
        {
          "id": "aluminium-3x3-deluxe-reprint",
          "label": "Aluminium gazebo — 3m × 3m deluxe — replacement canopy print only"
        },
        {
          "id": "aluminium-3x4.5-deluxe-full",
          "label": "Aluminium gazebo — 3m × 4.5m deluxe — full kit (print + system + carry bag + toolkit)"
        },
        {
          "id": "aluminium-3x4.5-deluxe-reprint",
          "label": "Aluminium gazebo — 3m × 4.5m deluxe — replacement canopy print only"
        },
        {
          "id": "aluminium-3x6-deluxe-full",
          "label": "Aluminium gazebo — 3m × 6m deluxe — full kit (print + system + carry bag + toolkit)"
        },
        {
          "id": "aluminium-3x6-deluxe-reprint",
          "label": "Aluminium gazebo — 3m × 6m deluxe — replacement canopy print only"
        }
      ]
    },
    {
      "id": "quantity",
      "type": "number",
      "label": "How many?",
      "shortLabel": "Quantity",
      "default": 1,
      "min": 1,
      "step": 1,
      "required": true
    },
    {
      "id": "artwork",
      "type": "select",
      "label": "What is happening with the design?",
      "shortLabel": "Artwork",
      "default": "ready",
      "options": [
        {
          "id": "ready",
          "label": "My artwork is ready"
        },
        {
          "id": "check",
          "label": "Please check my artwork"
        },
        {
          "id": "design",
          "label": "I need help with the design"
        }
      ]
    },
    {
      "id": "file",
      "type": "file",
      "label": "Artwork file",
      "help": "PDF or high-resolution PNG/JPG works best."
    }
  ]
},
  {
  "id": "photo-session",
  "name": "Quick Photo Session",
  "shortName": "Photo Session",
  "category": "Photo & Video",
  "description": "A fast, no-fuss photo session at Quick Solution Café.",
  "plainDescription": "Book the 30-minute session with 7 edited photos included. Other durations or extras are quoted before you book.",
  "keywords": [
    "photo session",
    "quick photos",
    "headshot",
    "id photo",
    "photography special"
  ],
  "popular": true,
  "active": true,
  "serviceType": "media",
  "channels": {
    "storefront": true,
    "guided": true,
    "pos": true,
    "quote": true,
    "advanced": false
  },
  "guidedJourneyId": "photo-session-guided",
  "nextActionLabel": "Send request",
  "pricingVersion": "2026-09-qsc-14c",
  "pricing": {
    "strategy": "PHOTOGRAPHY_SESSION",
    "sessions": {
      "30min-7edits": {
        "label": "30-minute session — 7 edited photos included",
        "durationMinutes": 30,
        "includedEdits": 7,
        "price": 449
      },
      "custom": {
        "label": "A different duration or scope",
        "durationMinutes": null,
        "includedEdits": null,
        "price": null
      }
    },
    "extraEditRate": null,
    "deliverables": {}
  },
  "fields": [
    {
      "id": "session",
      "type": "select",
      "label": "Which session would you like?",
      "shortLabel": "Session",
      "default": "30min-7edits",
      "options": [
        {
          "id": "30min-7edits",
          "label": "30-minute session — 7 edited photos included"
        },
        {
          "id": "custom",
          "label": "A different duration or scope — quote me"
        }
      ]
    },
    {
      "id": "extraEdits",
      "type": "number",
      "label": "Extra edited photos beyond what is included?",
      "shortLabel": "Extra edits",
      "default": 0,
      "min": 0,
      "step": 1
    },
    {
      "id": "preferredDate",
      "type": "date",
      "label": "Preferred date",
      "shortLabel": "Preferred date",
      "default": ""
    },
    {
      "id": "preferredTime",
      "type": "time",
      "label": "Preferred start time",
      "shortLabel": "Preferred time",
      "default": ""
    },
    {
      "id": "file",
      "type": "file",
      "label": "Reference / moodboard",
      "help": "Optional. Upload an image or PDF reference if it helps explain the look you want."
    }
  ]
}
]

export const guidedJourneys = [
  {
    id: 'media-guided',
    productId: 'media-services',
    title: 'Book photography or video',
    intro: 'Tell us the outcome, where the shoot should happen and which medium should lead.',
    steps: [
      {
        id: 'coverage',
        eyebrow: 'Step 1',
        title: 'What should we create?',
        helper: 'Choose photo, video or a combination. If you need both, tell us which one should be the main focus.',
        fields: ['mediumFocus', 'shootType']
      },
      {
        id: 'location',
        eyebrow: 'Step 2',
        title: 'Where should the shoot happen?',
        helper: 'Come to the Café, have us send a photographer to you, or request a photo / video team for bigger coverage.',
        type: 'location'
      },
      {
        id: 'crew',
        eyebrow: 'Step 3',
        title: 'What kind of crew do you need?',
        helper: 'Choose what sounds right. If you are unsure, we will recommend the right photographer, videographer or team.',
        fields: ['crew', 'duration']
      },
      {
        id: 'schedule',
        eyebrow: 'Step 4',
        title: 'When should we plan for?',
        helper: 'Give us your preferred date and time. We will confirm availability before the booking is final.',
        fields: ['preferredDate', 'preferredTime']
      },
      {
        id: 'brief',
        eyebrow: 'Step 5',
        title: 'What should the finished content do for you?',
        helper: 'Describe the photos, videos or content you want delivered. A reference is optional.',
        fields: ['deliverables', 'file']
      },
      {
        id: 'review',
        eyebrow: 'Final step',
        title: 'Check your media request',
        helper: 'We will review the brief, crew, location and schedule before confirming the quote.',
        type: 'review'
      }
    ]
  },
  {
    id: 'sticker-guided',
    productId: 'vinyl-stickers',
    title: 'Make stickers or labels',
    intro: 'Tell us the print area, whether you need cutting, and what is happening with the artwork.',
    steps: [
      {
        id: 'size',
        eyebrow: 'Step 1',
        title: 'How much vinyl do you need?',
        helper: 'Enter the total printed width and height in metres.',
        fields: ['width', 'height']
      },
      {
        id: 'finish',
        eyebrow: 'Step 2',
        title: 'Should we cut the stickers for you?',
        helper: 'Print only is supplied as printed vinyl. Print + cut adds R100.',
        fields: ['material', 'finishing']
      },
      {
        id: 'artwork',
        eyebrow: 'Step 3',
        title: 'What about the artwork?',
        helper: 'Upload ready artwork or ask Joint X to check or help with the design.',
        fields: ['artwork', 'file', 'turnaround']
      },
      {
        id: 'fulfilment',
        eyebrow: 'Step 4',
        title: 'How do you want to receive it?',
        helper: 'Collect from Quick Solution, use a Quick Point, or arrange delivery.',
        type: 'fulfilment'
      },
      {
        id: 'review',
        eyebrow: 'Final step',
        title: 'Check your sticker order',
        helper: 'Review the print area, cutting option, artwork and collection details.',
        type: 'review'
      }
    ]
  },
  {
    id: 'document-guided',
    productId: 'a4-print',
    title: 'Print a document',
    intro: 'A few simple questions and we will prepare the print job correctly.',
    steps: [
      { id: 'file', eyebrow: 'Step 1', title: 'Send us the document', helper: 'Upload the file from your phone or computer.', fields: ['file'] },
      { id: 'quantity', eyebrow: 'Step 2', title: 'Tell us what to print', helper: 'We keep this simple: print everything by default, or open a file only when you need certain pages.', fields: ['pages', 'copies'] },
      { id: 'print', eyebrow: 'Step 3', title: 'Choose how it should look', helper: 'Black & white is usually best for CVs, forms and school work.', fields: ['printMode', 'sides', 'finish'] },
      { id: 'fulfilment', eyebrow: 'Step 4', title: 'How do you want to get it?', helper: 'Choose what is most convenient. You can change this before payment.', type: 'fulfilment' },
      { id: 'review', eyebrow: 'Final step', title: 'Check your order', helper: 'Make sure the details below match what you need.', type: 'review' }
    ]
  },
  {
    id: 'banner-guided',
    productId: 'pvc-banner',
    title: 'Make a banner',
    intro: 'Tell us the finished size and how you plan to use it.',
    steps: [
      { id: 'size', eyebrow: 'Step 1', title: 'What size should the banner be?', helper: 'Use the finished width and height in metres.', fields: ['width', 'height'] },
      { id: 'finish', eyebrow: 'Step 2', title: 'Choose the banner and finishing', helper: 'Standard PVC with hem and eyelets works for most everyday jobs.', fields: ['material', 'finishing'] },
      { id: 'artwork', eyebrow: 'Step 3', title: 'What about the design?', helper: 'Upload it now or ask Joint X to help.', fields: ['artwork', 'file', 'turnaround'] },
      { id: 'fulfilment', eyebrow: 'Step 4', title: 'Where should it go?', helper: 'Collect from the Café, a Quick Point, or arrange delivery.', type: 'fulfilment' },
      { id: 'review', eyebrow: 'Final step', title: 'Check your banner order', helper: 'We will confirm anything unusual before production.', type: 'review' }
    ]
  },
  {
    id: 'business-card-guided',
    productId: 'business-cards',
    title: 'Order business cards',
    intro: 'Choose a quantity, finish and whether you need design help.',
    steps: [
      { id: 'quantity', eyebrow: 'Step 1', title: 'How many cards do you need?', helper: 'You can reorder the same saved card later.', fields: ['quantity'] },
      { id: 'finish', eyebrow: 'Step 2', title: 'Choose the card feel', helper: 'Standard premium stock works well for most businesses.', fields: ['stock', 'finish'] },
      { id: 'artwork', eyebrow: 'Step 3', title: 'Do you have a design?', helper: 'Upload an existing design or ask us to create one.', fields: ['artwork', 'file'] },
      { id: 'fulfilment', eyebrow: 'Step 4', title: 'How should you receive them?', helper: 'Choose collection or delivery.', type: 'fulfilment' },
      { id: 'review', eyebrow: 'Final step', title: 'Check your business card order', helper: 'You can still adjust the order before payment.', type: 'review' }
    ]
  },
  {
    id: 'tshirt-guided',
    productId: 'printed-tshirt',
    title: 'Print a T-shirt',
    intro: 'Choose the shirt, print placement and artwork. We will handle the production details.',
    steps: [
      { id: 'shirt', eyebrow: 'Step 1', title: 'How many shirts and which type?', helper: 'You can bring your own shirt or use a Joint X blank.', fields: ['quantity', 'garment'] },
      { id: 'print', eyebrow: 'Step 2', title: 'Where should we print?', helper: 'Choose the closest size. We can confirm the exact artwork size before production.', fields: ['frontPrint', 'backPrint'] },
      { id: 'artwork', eyebrow: 'Step 3', title: 'Send the artwork', helper: 'A transparent PNG works best for most clothing prints.', fields: ['artwork', 'file'] },
      { id: 'fulfilment', eyebrow: 'Step 4', title: 'Where should the shirts go?', helper: 'Collect nearby or arrange delivery.', type: 'fulfilment' },
      { id: 'review', eyebrow: 'Final step', title: 'Check your T-shirt order', helper: 'We will confirm sizes, stock and artwork before production.', type: 'review' }
    ]
  },
  {
    id: 'flags-guided',
    productId: 'flags',
    title: 'Order a flag',
    intro: 'Choose the flag, how many you need and what is happening with the artwork.',
    steps: [
      { id: 'flag', eyebrow: 'Step 1', title: 'Which flag would you like?', helper: 'Telescopic, Shark Fin and Curved are shown with every size, sides and kit option.', fields: ['variant', 'quantity'] },
      { id: 'artwork', eyebrow: 'Step 2', title: 'What about the artwork?', helper: 'Upload ready artwork or ask Joint X to check or help with the design.', fields: ['artwork', 'file'] },
      { id: 'fulfilment', eyebrow: 'Step 3', title: 'How do you want to receive it?', helper: 'Collect from Quick Solution, use a Quick Point, or arrange delivery.', type: 'fulfilment' },
      { id: 'review', eyebrow: 'Final step', title: 'Check your flag order', helper: 'Review the flag, quantity, artwork and collection details.', type: 'review' }
    ]
  },
  {
    id: 'gazebos-guided',
    productId: 'gazebos',
    title: 'Order a gazebo',
    intro: 'Choose the frame, size and kit, then tell us about the artwork.',
    steps: [
      { id: 'gazebo', eyebrow: 'Step 1', title: 'Which gazebo would you like?', helper: 'Steel and Aluminium frames are shown with every size and kit option.', fields: ['variant', 'quantity'] },
      { id: 'artwork', eyebrow: 'Step 2', title: 'What about the artwork?', helper: 'Upload ready artwork or ask Joint X to check or help with the design.', fields: ['artwork', 'file'] },
      { id: 'fulfilment', eyebrow: 'Step 3', title: 'How do you want to receive it?', helper: 'Collect from Quick Solution, use a Quick Point, or arrange delivery.', type: 'fulfilment' },
      { id: 'review', eyebrow: 'Final step', title: 'Check your gazebo order', helper: 'Review the gazebo, quantity, artwork and collection details.', type: 'review' }
    ]
  },
  {
    id: 'photo-session-guided',
    productId: 'photo-session',
    title: 'Book a quick photo session',
    intro: 'Choose the session, add any extra edited photos, and pick a date and time.',
    steps: [
      { id: 'session', eyebrow: 'Step 1', title: 'Which session would you like?', helper: 'The 30-minute session with 7 edited photos is our approved special. Anything else is quoted before you book.', fields: ['session', 'extraEdits'] },
      { id: 'schedule', eyebrow: 'Step 2', title: 'When should we plan for?', helper: 'Give us your preferred date and time. We will confirm availability before the booking is final.', fields: ['preferredDate', 'preferredTime'] },
      { id: 'brief', eyebrow: 'Step 3', title: 'Anything we should see first?', helper: 'A reference photo is optional.', fields: ['file'] },
      { id: 'review', eyebrow: 'Final step', title: 'Check your session request', helper: 'We will confirm the price and schedule before anything is booked.', type: 'review' }
    ]
  }
]

export const fulfilmentOptions = [
  { id: 'cafe', label: 'Quick Solution Café', helper: 'Collect from the full-service location.', icon: 'store' },
  { id: 'quick-point', label: 'Quick Point near me', helper: 'Collect from a trusted local partner.', icon: 'pin' },
  { id: 'delivery', label: 'Local delivery', helper: 'We will confirm the delivery fee and address.', icon: 'truck' }
]

export const categories = [
  'Quick Print',
  'Photo & Video',
  'Signs & Large Format',
  'Labels & Packaging',
  'Flags & Events',
  'Clothing & Merch',
  'Business Essentials',
  'Brand & Digital',
  'Quick Café',
  'Local & Quick Points'
]

export const quickTasks = [
  {
    id: 'schoolwork',
    kicker: 'School & study',
    label: 'Print homework or notes',
    helper: 'Upload a document and choose your copies.',
    productId: 'a4-print',
    journeyId: 'document-guided',
    preset: { printMode: 'bw' },
    icon: 'document'
  },
  {
    id: 'cv',
    kicker: 'Jobs & admin',
    label: 'Print my CV or forms',
    helper: 'Simple document printing without print jargon.',
    productId: 'a4-print',
    journeyId: 'document-guided',
    preset: { printMode: 'bw', copies: 2 },
    icon: 'user'
  },
  {
    id: 'copy-scan',
    kicker: 'Everyday admin',
    label: 'Copy, print or email a document',
    helper: 'Start here if you just need help getting a document handled.',
    productId: 'a4-print',
    journeyId: 'document-guided',
    preset: { copies: 1 },
    icon: 'upload'
  },
  {
    id: 'business',
    kicker: 'Business',
    label: 'Get my business ready',
    helper: 'Start with cards now, then add signs and branding.',
    productId: 'business-cards',
    journeyId: 'business-card-guided',
    preset: {},
    icon: 'store'
  },
  {
    id: 'clothing',
    kicker: 'Clothing & events',
    label: 'Print a T-shirt',
    helper: 'Bring your own shirt or choose a Joint X blank.',
    productId: 'printed-tshirt',
    journeyId: 'tshirt-guided',
    preset: {},
    icon: 'shirt'
  },
  {
    id: 'media-shoot',
    kicker: 'Photo & video',
    label: 'Book a shoot',
    helper: 'Come to the Café or have us send a photographer, videographer or team to you.',
    productId: 'media-services',
    journeyId: 'media-guided',
    preset: {},
    icon: 'camera'
  },
  {
    id: 'help',
    kicker: 'Not sure?',
    label: 'I need a person to help me',
    helper: 'Message Quick Solution and we will guide you.',
    action: 'help',
    icon: 'message'
  }
]
