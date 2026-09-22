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
    // QS-18 Simple/Pro: 'name' stays the Pro/default term (unchanged -
    // every existing, not-yet-mode-aware call site keeps showing exactly
    // this); simpleName is the new Simple-mode override, resolved via
    // resolveProductDisplayName()/resolveDisplayLabel() (productContent.js).
    simpleName: 'Outdoor advertising banner',
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
        id: 'artwork', type: 'select', label: 'What is happening with the design?', shortLabel: 'Artwork', simpleShortLabel: 'Your design', default: 'ready',
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
    ],
    // QS-17 — optional, backward-compatible Product Hub content (see
    // src/components/ProductHub.jsx / src/lib/productContent.js).
    // Derived directly from the description/field data above — no new
    // durability/material-spec/turnaround-day claims and no prices.
    media: {
      hero: '/qs11/product-pvc-banner-clean.webp',
      // Found while visually QA-ing the built page (not just filenames):
      // pvc-banner.webp and product-banner.webp are near-duplicate
      // exports of the SAME photo (different crop/resolution only) - a
      // "gallery" showing the same image twice adds no real value, so
      // only one of the pair is kept alongside the genuinely distinct
      // stand-mounted hero shot.
      gallery: ['/qs11/product-pvc-banner-clean.webp', '/qs11/pvc-banner.webp']
    },
    productPage: {
      headline: 'Custom PVC banners for shops, events and promotions',
      intro: 'Choose the size, finish and artwork help you need.',
      useCases: [
        { label: 'Shop signage' },
        { label: 'Events' },
        { label: 'Promotions' }
      ],
      highlights: [
        { label: 'Standard, premium or mesh PVC' },
        { label: 'Hem and eyelet finishing available' },
        { label: 'Artwork ready, checked, or designed for you' },
        { label: 'Standard or express turnaround' }
      ],
      configPreview: ['material', 'finishing'],
      showStartingPrice: false
    }
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
          { id: 'standard', label: 'White self-adhesive vinyl', helper: 'A versatile everyday vinyl for bottles, packaging, windows and product branding.', multiplier: 1 }
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
        id: 'artwork', type: 'select', label: 'What is happening with the design?', shortLabel: 'Artwork', simpleShortLabel: 'Your design', default: 'ready',
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
    ],
    // QS-16 — optional, backward-compatible customer-facing content for
    // the Product Hub (src/components/ProductHub.jsx). Every value here
    // is derived directly from facts already present above (description/
    // plainDescription text, and the material/finishing/artwork/turnaround
    // field option labels) — no new durability/thickness/waterproofing/
    // adhesive-grade/turnaround-day/minimum-quantity claims and no prices.
    // Read only via src/lib/productContent.js's resolve*() helpers, which
    // fall back gracefully for any product without this block at all.
    media: {
      hero: '/qs11/product-vinyl-labels-clean.webp',
      gallery: [
        '/qs11/product-vinyl-labels-clean.webp',
        '/qs11/product-vinyl.webp',
        '/qs11/product-labels-perfume.webp',
        '/qs11/product-labels-household.webp'
      ]
    },
    productPage: {
      headline: 'Custom vinyl stickers and labels for bottles, packaging, windows and branding',
      intro: 'Choose the print area, artwork help and whether you need print only or print + cut.',
      useCases: [
        { label: 'Bottles' },
        { label: 'Packaging' },
        { label: 'Windows' },
        { label: 'Product branding' }
      ],
      highlights: [
        { label: 'White self-adhesive vinyl' },
        { label: 'Print only or print + cut' },
        { label: 'Artwork ready, checked, or designed for you' },
        { label: 'Standard or express turnaround, where available' }
      ],
      configPreview: ['finishing', 'artwork'],
      // Correction: showStartingPrice is opt-in and must only be enabled
      // once someone has confirmed the DEFAULT configuration really is
      // the cheapest valid one - not merely because the product has a
      // pricing object. Confirmed for vinyl-stickers: pricing.js's
      // priceArea() is monotonically non-decreasing in every input
      // (billableArea, material.multiplier, finishing.fee, artwork.fee,
      // turnaround.multiplier), and every default option here is the
      // minimum for its field - width/height default to 1x1 = 1m²,
      // exactly matching pricing.minimumBillableArea (not below the
      // floor, not above it); material has only the one, multiplier:1
      // option; finishing defaults to 'print-only' (fee 0, cheaper than
      // print-cut's fee 100); artwork defaults to 'ready' (fee 0,
      // cheaper than check's 75 / design's 250); turnaround defaults to
      // 'standard' (multiplier 1, cheaper than express's 1.2). So the
      // default IS the true minimum price for this product, not merely
      // "a" price.
      showStartingPrice: true
    }
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
        id: 'artwork', type: 'select', label: 'Do you already have a design?', shortLabel: 'Design', simpleShortLabel: 'Your design', default: 'ready',
        options: [
          { id: 'ready', label: 'My design is ready', fee: 0 },
          { id: 'check', label: 'Please check my design', fee: 75 },
          { id: 'design', label: 'Design it for me', fee: 250 }
        ]
      },
      { id: 'file', type: 'file', label: 'Design file', help: 'Optional now. You can add it before checkout.' }
    ],
    // QS-17 — optional, backward-compatible Product Hub content.
    // showStartingPrice: true per agreed rule - confirmed safe: the
    // default config (100 cards, standard stock ×1, standard finish fee
    // 0, ready artwork fee 0) is every field's cheapest option, so it is
    // genuinely the minimum price, not merely "a" price (same
    // reasoning/verification standard as vinyl-stickers in QS-16).
    media: {
      hero: '/qs11/product-business-cards-clean.webp',
      // Same near-duplicate pair issue as pvc-banner: business-cards.webp
      // and product-business-cards.webp are the same photo re-exported -
      // only one kept alongside the genuinely distinct hero.
      gallery: ['/qs11/product-business-cards-clean.webp', '/qs11/business-cards.webp']
    },
    productPage: {
      headline: 'Professional business cards with clear quantity-based pricing',
      intro: 'Choose quantity, stock and whether you need design help.',
      highlights: [
        { label: 'Standard or extra-thick card stock' },
        { label: 'Matt or gloss lamination available' },
        { label: 'Design ready, checked, or designed for you' }
      ],
      // QS-21: 'quantity' added - the single biggest price driver
      // (100/250/500/1000 cards) was missing from this curated preview,
      // which also feeds Quick Configure (src/lib/navigation.js) - a
      // "quick" configure without the main quantity choice wasn't
      // actually quick/useful. Purely additive; ProductHub's own
      // "Choices you will make" section gains the same field for free.
      configPreview: ['quantity', 'stock', 'finish'],
      showStartingPrice: true
    }
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
        id: 'artwork', type: 'select', label: 'What is happening with the artwork?', shortLabel: 'Artwork', simpleShortLabel: 'Your design', default: 'ready',
        options: [
          { id: 'ready', label: 'My artwork is ready', fee: 0 },
          { id: 'check', label: 'Please check my artwork', fee: 75 },
          { id: 'design', label: 'I need help with the design', fee: 250 }
        ]
      },
      { id: 'file', type: 'file', label: 'Artwork file', help: 'PNG with a transparent background is ideal.' }
    ],
    // QS-17 — optional, backward-compatible Product Hub content.
    media: {
      hero: '/qs11/product-tshirt-clean.webp',
      // Same near-duplicate pair issue: apparel-printing.webp and
      // product-apparel.webp are the same photo re-exported - only one
      // kept alongside the genuinely distinct hanging-shirt hero.
      gallery: ['/qs11/product-tshirt-clean.webp', '/qs11/apparel-printing.webp']
    },
    productPage: {
      headline: 'Custom printed T-shirts, your garment or ours',
      intro: 'Choose the shirt, print size and quantity without print jargon.',
      highlights: [
        { label: 'Bring your own shirt or choose a Joint X blank' },
        { label: 'Front and back print sizes available' },
        { label: 'Artwork ready, checked, or designed for you' }
      ],
      // QS-21: 'quantity' added - same reasoning as business-cards
      // above. FieldControl already renders type:'number' fields fine
      // (this one has a real default:1/min:1), so this is safe for
      // both ProductHub's preview and Quick Configure.
      configPreview: ['quantity', 'garment', 'frontPrint'],
      showStartingPrice: false
    }
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
  // QS-20: production rollout confirmed complete and verified - QS-14
  // supplier-pricing foundation, this product's base catalogue row,
  // server-authoritative supplier pricing, single-sided minQuantity/
  // quantityStep rules and QS-17B's Product Hub + presets are all live.
  // The prior "not yet published" fallback is stale - flipped to true.
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
    "variantAxes": [
      { "id": "style", "label": "Style", "options": [
        { "id": "telescopic", "label": "Telescopic" },
        { "id": "sharkfin", "label": "Shark Fin" },
        { "id": "curved", "label": "Curved" }
      ] },
      { "id": "size", "label": "Size", "options": [
        { "id": "2m", "label": "2.0m" },
        { "id": "3m", "label": "3.0m" },
        { "id": "4m", "label": "4.0m" }
      ] },
      { "id": "sides", "label": "Sides", "simpleLabel": "Printed on one side or both?", "options": [
        { "id": "ss", "label": "Single-sided (must be ordered in pairs of 2)", "simpleLabel": "Printed on one side (ordered in pairs of 2)" },
        { "id": "ds", "label": "Double-sided", "simpleLabel": "Printed on both sides" }
      ] },
      { "id": "kit", "label": "Kit", "simpleLabel": "Do you need the stand too?", "options": [
        { "id": "full", "label": "Full kit (print + system + ground spike + carry bag)", "simpleLabel": "Complete kit (print + system + ground spike + carry bag)" },
        { "id": "reprint", "label": "Replacement print only" }
      ] }
    ],
    "variantTemplate": "{style}-{size}-{sides}-{kit}",
    "variants": {
      "telescopic-2m-ss-full": {
        "label": "Telescopic flag — 2.0m — single-sided — full kit (print + system + ground spike + carry bag)",
        "price": 990,
        "minQuantity": 2,
        "quantityStep": 2
      },
      "telescopic-3m-ss-full": {
        "label": "Telescopic flag — 3.0m — single-sided — full kit (print + system + ground spike + carry bag)",
        "price": 1190,
        "minQuantity": 2,
        "quantityStep": 2
      },
      "telescopic-4m-ss-full": {
        "label": "Telescopic flag — 4.0m — single-sided — full kit (print + system + ground spike + carry bag)",
        "price": 1390,
        "minQuantity": 2,
        "quantityStep": 2
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
        "price": 470,
        "minQuantity": 2,
        "quantityStep": 2
      },
      "telescopic-3m-ss-reprint": {
        "label": "Telescopic flag — 3.0m — single-sided — replacement print only",
        "price": 650,
        "minQuantity": 2,
        "quantityStep": 2
      },
      "telescopic-4m-ss-reprint": {
        "label": "Telescopic flag — 4.0m — single-sided — replacement print only",
        "price": 790,
        "minQuantity": 2,
        "quantityStep": 2
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
        "price": 990,
        "minQuantity": 2,
        "quantityStep": 2
      },
      "sharkfin-3m-ss-full": {
        "label": "Shark Fin flag — 3.0m — single-sided — full kit (print + system + ground spike + carry bag)",
        "price": 1190,
        "minQuantity": 2,
        "quantityStep": 2
      },
      "sharkfin-4m-ss-full": {
        "label": "Shark Fin flag — 4.0m — single-sided — full kit (print + system + ground spike + carry bag)",
        "price": 1390,
        "minQuantity": 2,
        "quantityStep": 2
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
        "price": 470,
        "minQuantity": 2,
        "quantityStep": 2
      },
      "sharkfin-3m-ss-reprint": {
        "label": "Shark Fin flag — 3.0m — single-sided — replacement print only",
        "price": 650,
        "minQuantity": 2,
        "quantityStep": 2
      },
      "sharkfin-4m-ss-reprint": {
        "label": "Shark Fin flag — 4.0m — single-sided — replacement print only",
        "price": 790,
        "minQuantity": 2,
        "quantityStep": 2
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
        "price": 1050,
        "minQuantity": 2,
        "quantityStep": 2
      },
      "curved-3m-ss-full": {
        "label": "Curved flag — 3.0m — single-sided — full kit (print + system + ground spike + carry bag)",
        "price": 1250,
        "minQuantity": 2,
        "quantityStep": 2
      },
      "curved-4m-ss-full": {
        "label": "Curved flag — 4.0m — single-sided — full kit (print + system + ground spike + carry bag)",
        "price": 1500,
        "minQuantity": 2,
        "quantityStep": 2
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
        "price": 500,
        "minQuantity": 2,
        "quantityStep": 2
      },
      "curved-3m-ss-reprint": {
        "label": "Curved flag — 3.0m — single-sided — replacement print only",
        "price": 700,
        "minQuantity": 2,
        "quantityStep": 2
      },
      "curved-4m-ss-reprint": {
        "label": "Curved flag — 4.0m — single-sided — replacement print only",
        "price": 850,
        "minQuantity": 2,
        "quantityStep": 2
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
      "simpleShortLabel": "Your design",
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
  ],
  // QS-21.1: real branded flag photography added (visually inspected and
  // classified from a supplied photo batch - see the QS-21.1 media
  // mapping report). Replaces the earlier documented "no dedicated flag
  // photography exists yet" placeholder gap. hero is the single-flag
  // shot (clearest at ProductCard thumbnail size); gallery adds the
  // size-lineup and Shark Fin pair so the real style/size range the
  // configurator actually offers is visible, plus an alternate angle of
  // the hero subject.
  "media": {
    "hero": "/qs21/flags-hero-single.webp",
    "gallery": [
      "/qs21/flags-lineup-sizes.webp",
      "/qs21/flags-shark-fin-pair.webp",
      "/qs21/flags-hero-single-alt.webp"
    ]
  },
  "productPage": {
    "headline": "Telescopic, Shark Fin and Curved flags for shopfronts, stands and events",
    "intro": "Choose the flag style, size, sides and whether you need the full kit or just a replacement print.",
    "useCases": [
      { "label": "Shopfronts" },
      { "label": "Stands" },
      { "label": "Events" }
    ],
    "highlights": [
      { "label": "Telescopic, Shark Fin or Curved styles" },
      { "label": "2m, 3m or 4m sizes" },
      { "label": "Single or double-sided printing" },
      { "label": "Full kit or replacement print only" }
    ],
    "configPreview": ["artwork"],
    "showStartingPrice": false,
    // QS-17 curated presets. No documented "default"/"most popular"
    // flag style exists anywhere in the catalogue (checked: product-
    // level popular:false, no `default` key on the variant field) - so
    // every preset below names its style explicitly (Telescopic) rather
    // than implying a house default that was never actually decided.
    // Telescopic was chosen as the illustrative/reference style (it is
    // listed first among the three styles and is the most generic/
    // common flag type) - this is a QS-17 judgment call, not a
    // recovered business rule; confirmed by the business (keep
    // Telescopic; every preset name says so explicitly, never implied).
    // Every config below maps to a real, existing key in
    // pricing.variants above - none invented.
    //
    // artwork: null (not 'ready') - a preset configures the PHYSICAL
    // PRODUCT (variant/quantity), it must not silently assert the
    // customer already has print-ready artwork. See the full
    // investigation/reasoning in src/lib/productContent.js above
    // validatePresetConfig(). Guided mode then genuinely asks the
    // artwork question with nothing pre-selected.
    "presets": [
      {
        "id": "flag-2m-telescopic-full",
        "name": "2m Telescopic Flag — Complete kit",
        "description": "A ready-to-use 2m telescopic flag with stand, spike and single-sided print. Single-sided flags are supplied in pairs of 2.",
        "config": { "variant": "telescopic-2m-ss-full", "quantity": 2, "artwork": null }
      },
      {
        "id": "flag-3m-telescopic-full",
        "name": "3m Telescopic Flag — Complete kit",
        "description": "A ready-to-use 3m telescopic flag with stand, spike and single-sided print. Single-sided flags are supplied in pairs of 2.",
        "config": { "variant": "telescopic-3m-ss-full", "quantity": 2, "artwork": null }
      },
      {
        "id": "flag-3m-telescopic-double-full",
        "name": "3m Double-Sided Telescopic Flag — Complete kit",
        "description": "A ready-to-use 3m telescopic flag, printed on both sides, with stand and spike.",
        "config": { "variant": "telescopic-3m-ds-full", "quantity": 1, "artwork": null }
      },
      {
        "id": "flag-4m-telescopic-full",
        "name": "4m Telescopic Flag — Complete kit",
        "description": "A ready-to-use 4m telescopic flag with stand, spike and single-sided print. Single-sided flags are supplied in pairs of 2.",
        "config": { "variant": "telescopic-4m-ss-full", "quantity": 2, "artwork": null }
      },
      {
        "id": "flag-3m-telescopic-reprint",
        "name": "Replacement print — 3m Telescopic Flag",
        "description": "A replacement single-sided print only, for an existing 3m telescopic flag stand. Supplied in pairs of 2.",
        "config": { "variant": "telescopic-3m-ss-reprint", "quantity": 2, "artwork": null }
      }
    ]
  }
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
  // QS-20: see the matching comment on the 'flags' entry above -
  // production rollout confirmed complete and verified, including this
  // product's base catalogue row and gazebo accessory compatibility
  // rules. Flipped to true.
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
    "variantAxes": [
      { "id": "frame", "label": "Frame", "options": [
        { "id": "steel", "label": "Steel" },
        { "id": "aluminium", "label": "Aluminium" }
      ] },
      { "id": "size", "label": "Size", "options": [
        { "id": "2x2", "label": "2m × 2m" },
        { "id": "3x3-standard", "label": "3m × 3m standard" },
        { "id": "3x3-deluxe", "label": "3m × 3m deluxe" },
        { "id": "3x4.5-deluxe", "label": "3m × 4.5m deluxe", "availableWhen": { "frame": ["aluminium"] } },
        { "id": "3x6-deluxe", "label": "3m × 6m deluxe", "availableWhen": { "frame": ["aluminium"] } }
      ] },
      { "id": "kit", "label": "Kit", "simpleLabel": "Do you need the full frame, or just a replacement print?", "options": [
        { "id": "full", "label": "Full kit (print + system + carry bag + toolkit)", "simpleLabel": "Complete kit (print + system + carry bag + toolkit)" },
        { "id": "reprint", "label": "Replacement canopy print only", "simpleLabel": "Replacement gazebo roof print" }
      ] }
    ],
    "variantTemplate": "{frame}-{size}-{kit}",
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
        "price": 650,
        "compatibleVariants": ["steel-2x2-full", "steel-2x2-reprint", "aluminium-2x2-full", "aluminium-2x2-reprint"]
      },
      "wall-2x2-full": {
        "label": "2m × 2m full wall",
        "price": 1190,
        "compatibleVariants": ["steel-2x2-full", "steel-2x2-reprint", "aluminium-2x2-full", "aluminium-2x2-reprint"]
      },
      "wall-3x3-half": {
        "label": "3m × 3m half wall",
        "price": 850,
        "compatibleVariants": ["steel-3x3-standard-full", "steel-3x3-standard-reprint", "steel-3x3-deluxe-full", "steel-3x3-deluxe-reprint", "aluminium-3x3-standard-full", "aluminium-3x3-standard-reprint", "aluminium-3x3-deluxe-full", "aluminium-3x3-deluxe-reprint"]
      },
      "wall-3x3-full": {
        "label": "3m × 3m full wall",
        "price": 1650,
        "compatibleVariants": ["steel-3x3-standard-full", "steel-3x3-standard-reprint", "steel-3x3-deluxe-full", "steel-3x3-deluxe-reprint", "aluminium-3x3-standard-full", "aluminium-3x3-standard-reprint", "aluminium-3x3-deluxe-full", "aluminium-3x3-deluxe-reprint"]
      },
      "wall-3x4.5-full": {
        "label": "3m × 4.5m full wall",
        "price": 2500,
        "compatibleVariants": ["aluminium-3x4.5-deluxe-full", "aluminium-3x4.5-deluxe-reprint"]
      },
      "wall-3x6-full": {
        "label": "3m × 6m full wall",
        "price": 3300,
        "compatibleVariants": ["aluminium-3x6-deluxe-full", "aluminium-3x6-deluxe-reprint"]
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
        "price": 750,
        "compatibleVariants": ["steel-2x2-full", "steel-2x2-reprint", "steel-3x3-standard-full", "steel-3x3-standard-reprint", "steel-3x3-deluxe-full", "steel-3x3-deluxe-reprint", "aluminium-2x2-full", "aluminium-2x2-reprint", "aluminium-3x3-standard-full", "aluminium-3x3-standard-reprint", "aluminium-3x3-deluxe-full", "aluminium-3x3-deluxe-reprint"]
      },
      "wheely-bag-4-5m": {
        "label": "Wheely bag (4.5m gazebo)",
        "price": 900,
        "compatibleVariants": ["aluminium-3x4.5-deluxe-full", "aluminium-3x4.5-deluxe-reprint"]
      },
      "wheely-bag-6m": {
        "label": "Wheely bag (6m gazebo)",
        "price": 990,
        "compatibleVariants": ["aluminium-3x6-deluxe-full", "aluminium-3x6-deluxe-reprint"]
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
      "simpleShortLabel": "Your design",
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
  ],
  // QS-21.1: real branded gazebo photography added (visually inspected
  // and classified from a supplied photo batch - see the QS-21.1 media
  // mapping report), replacing the earlier single stock-style
  // event-gazebo.webp placeholder and its "no second distinct photo
  // exists" limitation. hero shows the full kit (frame + carry bag +
  // stakes), matching the "full kit or replacement canopy" copy below;
  // gallery adds the walled, half-wall and open-frame variations so the
  // real configuration range is visible before configuring.
  "media": {
    "hero": "/qs21/gazebo-hero-kit.webp",
    "gallery": [
      "/qs21/gazebo-walled.webp",
      "/qs21/gazebo-half-wall.webp",
      "/qs21/gazebo-open-frame.webp"
    ]
  },
  "productPage": {
    "headline": "Branded steel and aluminium gazebos for markets, activations and events",
    "intro": "Choose the frame, size and whether you need the full kit or just a replacement canopy print.",
    "useCases": [
      { "label": "Markets" },
      { "label": "Activations" },
      { "label": "Events" }
    ],
    "highlights": [
      { "label": "Steel or aluminium frames" },
      { "label": "2×2m up to 3×6m sizes" },
      { "label": "Full kit or replacement canopy print only" },
      { "label": "Optional walls and weights" }
    ],
    "configPreview": ["artwork"],
    "showStartingPrice": false,
    // QS-17 curated presets. Like flags, no documented default frame
    // exists (product-level popular:false, no `default` on the variant
    // field), so every 3x3 preset names its frame explicitly. The one
    // genuine ambiguity: "3×3 Deluxe Gazebo" (the brief's own example
    // name) does not specify a frame, and both steel and aluminium have
    // a deluxe 3x3 variant. Chose aluminium here (the frame that also
    // carries the larger deluxe sizes, i.e. the more "premium" line in
    // this catalogue's structure) - a QS-17 judgment call, not a
    // recovered business rule; confirmed by the business (keep the
    // "3×3 Aluminium Deluxe Gazebo" as the deluxe preset - the "Complete
    // Kit" in that confirmation was a reference to which preset to
    // keep, not a mandated casing; the customer-facing name below uses
    // the QS-17 review's exact copy spec, "Complete kit").
    // Every config below maps to a real, existing key in
    // pricing.variants above - none invented.
    //
    // artwork: null (not 'ready') - same reasoning as the flags
    // presets above: a preset configures the PHYSICAL PRODUCT, not
    // whether the customer's artwork happens to be ready. See
    // src/lib/productContent.js's validatePresetConfig() for the full
    // investigation.
    "presets": [
      {
        "id": "gazebo-2x2-steel-full",
        "name": "2×2 Steel Gazebo — Complete kit",
        "description": "A ready-to-use 2m × 2m steel-frame gazebo with printed canopy, frame and carry bag.",
        "config": { "variant": "steel-2x2-full", "quantity": 1, "artwork": null }
      },
      {
        "id": "gazebo-3x3-steel-standard-full",
        "name": "3×3 Steel Gazebo — Complete kit",
        "description": "A ready-to-use 3m × 3m standard steel-frame gazebo with printed canopy, frame and carry bag.",
        "config": { "variant": "steel-3x3-standard-full", "quantity": 1, "artwork": null }
      },
      {
        "id": "gazebo-3x3-aluminium-standard-full",
        "name": "3×3 Aluminium Gazebo — Complete kit",
        "description": "A ready-to-use 3m × 3m standard aluminium-frame gazebo with printed canopy, frame and carry bag.",
        "config": { "variant": "aluminium-3x3-standard-full", "quantity": 1, "artwork": null }
      },
      {
        "id": "gazebo-3x3-aluminium-deluxe-full",
        "name": "3×3 Aluminium Deluxe Gazebo — Complete kit",
        "description": "A ready-to-use 3m × 3m deluxe aluminium-frame gazebo with printed canopy, frame and carry bag.",
        "config": { "variant": "aluminium-3x3-deluxe-full", "quantity": 1, "artwork": null }
      },
      {
        "id": "gazebo-3x3-steel-standard-reprint",
        "name": "Replacement canopy print — 3×3 Steel Standard Gazebo",
        "description": "A replacement canopy print only, for an existing 3m × 3m standard steel-frame gazebo.",
        "config": { "variant": "steel-3x3-standard-reprint", "quantity": 1, "artwork": null }
      }
    ]
  }
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
  // Not yet published live in commerce.service_product_configs — kept
  // inactive in this fallback so it can never flash as orderable before
  // the live catalogue fetch resolves (or if that fetch fails). Unlike
  // flags/gazebos (QS-20: now confirmed live), this product's own
  // production rollout has not been confirmed yet.
  "active": false,
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
      { id: 'flag', eyebrow: 'Step 1', title: 'Which flag would you like?', helper: 'Choose the style, size, sides and kit — single-sided flags are ordered in pairs of 2.', type: 'variant-builder' },
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
      { id: 'gazebo', eyebrow: 'Step 1', title: 'Which gazebo would you like?', helper: 'Choose the frame, size and kit, then add any walls or accessories that fit.', type: 'variant-builder' },
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
      { id: 'deliverables', eyebrow: 'Step 2', title: 'Anything extra to deliver?', helper: 'Optional — choose any extra deliverables Quick Solution has priced.', type: 'photo-deliverables' },
      { id: 'schedule', eyebrow: 'Step 3', title: 'When should we plan for?', helper: 'Give us your preferred date and time. We will confirm availability before the booking is final.', fields: ['preferredDate', 'preferredTime'] },
      { id: 'brief', eyebrow: 'Step 4', title: 'Anything we should see first?', helper: 'A reference photo is optional.', fields: ['file'] },
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

// QS-18 — the Home hero's compact outcome actions (6 broad outcomes).
// Replaces the old quickTasks list (7 more granular starting points,
// rendered by the now-removed #start section/QuickTaskCard component) -
// removed in the QS-18 Lite cleanup once confirmed to have zero
// remaining runtime references anywhere in the app. Two kinds of entry,
// both reusing EXISTING routing only (no new product/pricing logic):
//  - kind: 'guided' -> opens an existing guided journey directly
//    (App.jsx's openGuided(), the same existing entry point every
//    guided flow already uses), used where exactly one product clearly
//    answers the outcome.
//  - kind: 'shop' -> scrolls to the Shop section pre-filtered to one of
//    productContent.js's SHOP_CATEGORIES, used where more than one
//    product could answer the outcome and the customer should pick.
export const heroOutcomes = [
  {
    id: 'print',
    label: 'Print something',
    helper: 'Documents, CVs, forms and everyday printing.',
    icon: 'document',
    kind: 'guided',
    productId: 'a4-print',
    journeyId: 'document-guided',
    preset: {}
  },
  {
    id: 'business-ready',
    label: 'Get my business ready',
    helper: 'Cards, signage and the essentials to look established.',
    icon: 'store',
    // QS-18A correction: was kind:'guided' straight into business-cards -
    // too narrow, since "get ready" isn't necessarily just cards. An
    // outcome must not silently collapse into one product when more
    // than one could satisfy it.
    kind: 'shop',
    shopCategory: 'Business'
  },
  {
    id: 'promote',
    label: 'Promote my business',
    helper: 'Banners, signs and outdoor advertising.',
    icon: 'signpost',
    kind: 'shop',
    shopCategory: 'Signs & Advertising'
  },
  {
    id: 'event',
    label: 'Prepare for an event',
    helper: 'Flags, gazebos and displays for markets and activations.',
    icon: 'tent',
    kind: 'shop',
    shopCategory: 'Events'
  },
  {
    id: 'apparel',
    label: 'Clothing & merch',
    helper: 'Printed T-shirts, bring-your-own or a Joint X blank.',
    icon: 'shirt',
    // QS-18A correction: was kind:'guided' straight into printed-tshirt -
    // same reasoning as "Get my business ready" above.
    kind: 'shop',
    shopCategory: 'Apparel'
  },
  {
    id: 'media',
    label: 'Photo & video',
    helper: 'Book a shoot or a quick photo session.',
    icon: 'camera',
    kind: 'shop',
    shopCategory: 'Photo & Video'
  }
]

// QS-20 — Offers / Combos: curated groups of REAL products/presets, not
// a second catalogue or a second price. Every id below was verified
// against this file's own product/preset data before being written
// here (see the QS-20 audit) - nothing invented. `category` reuses the
// exact SHOP_CATEGORIES vocabulary (productContent.js) so an offer can
// be filtered/surfaced with the same bucket a hero outcome's
// `shopCategory` already names - no second taxonomy.
//
// `items[].quantity` is a REPEAT COUNT of that exact resolved line
// (see src/lib/offers.js's own header comment for why) - it is NOT
// merged into a preset/config's own internal quantity. The 3m
// Telescopic Flag preset below already sets config.quantity: 2 (single-
// sided flags are sold in pairs) - that is one pair, one order line;
// this offer's own item.quantity: 1 means exactly one of that pair,
// matching the "2× Flags" a customer sees as one line reading "3m
// Telescopic Flag - Complete kit x2" from the preset itself, not two
// separate order lines.
//
// QS-20 final review: flags/gazebos' production rollout is now confirmed
// complete and verified (base catalogue rows published, server-
// authoritative supplier pricing, QS-17B Product Hub + presets all
// live) - both flipped to active:true above, and "Event Starter" below
// is active accordingly. "Business Starter" and "Promotion Pack" use
// only products that don't yet have curated presets, so their lines use
// explicit `config` instead of a presetId - allowed by the QS-20 spec
// ("config? // only when necessary") specifically because no preset
// exists yet to prefer.
//
// A fourth "Market Setup" offer (suggested as an initial direction) was
// considered and deliberately NOT added, per explicit confirmation:
// three curated offers is enough for v1.
export const offers = [
  {
    id: 'business-starter',
    name: 'Business Starter',
    description: 'Cards to hand out and a shop sign to be seen by - the two essentials to look established from day one.',
    category: 'Business',
    active: true,
    items: [
      {
        id: 'cards',
        productId: 'business-cards',
        config: { quantity: '100', stock: 'standard', finish: 'standard', artwork: 'ready' },
        quantity: 1
      },
      {
        id: 'shop-banner',
        productId: 'pvc-banner',
        config: { width: 1.5, height: 1, material: 'standard', finishing: 'hem-eyelets', artwork: 'ready', turnaround: 'standard' },
        quantity: 1
      }
    ]
  },
  {
    id: 'promotion-pack',
    name: 'Promotion Pack',
    description: 'A banner to draw the eye and window stickers to reinforce it - one combo for getting noticed.',
    category: 'Signs & Advertising',
    active: true,
    items: [
      {
        id: 'promo-banner',
        productId: 'pvc-banner',
        config: { width: 2, height: 1, material: 'standard', finishing: 'hem-eyelets', artwork: 'ready', turnaround: 'standard' },
        quantity: 1
      },
      {
        id: 'window-stickers',
        productId: 'vinyl-stickers',
        config: { width: 1, height: 1, material: 'standard', finishing: 'print-cut', artwork: 'ready', turnaround: 'standard' },
        quantity: 1
      }
    ]
  },
  {
    id: 'event-starter',
    name: 'Event Starter',
    description: 'A deluxe gazebo, a telescopic flag pair and a banner - everything to show up properly at a market or activation.',
    category: 'Events',
    // QS-20 final review: flags/gazebos' production rollout is
    // confirmed live (see the block comment above and both products'
    // own active:true) - Event Starter activated accordingly. The
    // optional PVC Banner line means this offer's real minimum
    // composition is R11,280 (gazebo + flags only), not the R12,090
    // shown by default with every item included - see OfferCard.jsx's
    // total-display fix for why the card never claims "From R12,090".
    active: true,
    items: [
      {
        id: 'gazebo',
        productId: 'gazebos',
        presetId: 'gazebo-3x3-aluminium-deluxe-full',
        quantity: 1
      },
      {
        id: 'flags',
        productId: 'flags',
        presetId: 'flag-3m-telescopic-full',
        quantity: 1
      },
      {
        id: 'event-banner',
        productId: 'pvc-banner',
        config: { width: 2, height: 1, material: 'standard', finishing: 'hem-eyelets', artwork: 'ready', turnaround: 'standard' },
        quantity: 1,
        optional: true
      }
    ]
  }
]
