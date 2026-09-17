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
    pricing: { strategy: 'PER_AREA', baseRate: 145, minimumBillableArea: 1, unit: 'm²' },
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
      { id: 'pages', type: 'number', label: 'How many pages are in the document?', shortLabel: 'Pages', default: 1, min: 1, step: 1, required: true },
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
      { id: 'quantity', eyebrow: 'Step 2', title: 'Tell us how much to print', helper: 'If you are not sure how many pages are in the file, we can confirm before production.', fields: ['pages', 'copies'] },
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
