import { products } from '../../src/data/products.js'
// Explicit historical keys: a future addition cannot alter these regression
// snapshots. The full new catalogue is exercised in supplier-catalogue.test.mjs.
const keys = new Set(['pvc-banner', 'vinyl-stickers', 'a4-print', 'business-cards', 'printed-tshirt', 'media-services', 'flags', 'gazebos', 'photo-session', 'scan', 'a4-lamination', 'a3-lamination'])
export const baselineProducts = products.filter(product => keys.has(product.id))
