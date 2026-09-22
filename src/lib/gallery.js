// QS-21.3 — pure lightbox/gallery index math, no DOM. ProductHub.jsx owns
// the actual lightbox open/close state and the keydown (Escape/ArrowLeft/
// ArrowRight) listener; these two functions are just "given N images and
// a current index, which index is next/previous", wrapping around at
// either end - kept pure and separate so that decision is unit-testable
// without a rendering harness (same reasoning as resolveRelatedDisclosureState,
// src/lib/relatedContent.js).
export function resolveNextGalleryIndex(currentIndex, length) {
  if (!length) return 0
  return (currentIndex + 1) % length
}

export function resolvePrevGalleryIndex(currentIndex, length) {
  if (!length) return 0
  return (currentIndex - 1 + length) % length
}
