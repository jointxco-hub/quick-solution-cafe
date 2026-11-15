import { test, expect } from '@playwright/test'

// Browser smoke tests exercise existing QS actions, without creating orders,
// taking payments, or changing the backend. Use local catalogue data.
const viewports = [
  { name: 'small-mobile', width: 360, height: 780 },
  { name: 'mobile', width: 390, height: 844 },
  { name: 'large-mobile', width: 430, height: 932 },
  { name: 'desktop', width: 1440, height: 900 },
]

for (const viewport of viewports) {
  test(`homepage layout is legible at ${viewport.name}`, async ({ page }) => {
    await page.setViewportSize({ width: viewport.width, height: viewport.height })
    const errors = []
    page.on('pageerror', error => errors.push(error.message))
    await page.goto('/')
    await expect(page.getByRole('heading', { name: /Your ideas/i })).toBeVisible()
    await expect(page.getByRole('button', { name: /Explore services/i })).toBeVisible()
    await expect(page.getByRole('button', { name: /Upload & print/i })).toBeVisible()
    await expect(page.getByRole('heading', { name: /Find what you need/i })).toBeVisible()
    await expect(page.getByRole('heading', { name: /Made here/i })).toBeVisible()
    await expect(page.getByRole('heading', { name: /Here's how it works/i })).toBeVisible()
    const horizontalOverflow = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth)
    expect(horizontalOverflow).toBeLessThanOrEqual(2)
    expect(errors).toEqual([])
    await page.screenshot({ path: `test-results/qs-home-${viewport.name}.png`, fullPage: true })
  })
}

test('Explore services opens the real Shop route', async ({ page }) => {
  await page.goto('/')
  await page.getByRole('button', { name: /Explore services/i }).click()
  await expect(page).toHaveURL(/\/shop(?:[?#]|$)/)
})

test('Upload & print opens existing document product flow', async ({ page }) => {
  await page.goto('/')
  await page.getByRole('button', { name: /Upload & print/i }).click()
  await expect(page).toHaveURL(/(?:\/product\/a4-print|\/configure\/a4-print|a4-print)/)
})

test('Business branding opens existing Signs & Advertising products', async ({ page }) => {
  await page.goto('/')
  await page.getByRole('button', { name: /Business branding/i }).click()
  await expect(page).toHaveURL(/\/shop(?:[?#]|$)/)
  await expect(page.getByText('Signs & Advertising', { exact: true }).first()).toBeVisible()
})

test('Print documents card reuses document order entry', async ({ page }) => {
  await page.goto('/')
  await page.getByRole('button', { name: /Print documents/i }).click()
  await expect(page).toHaveURL(/a4-print/)
})

test('Track order still resolves without submitting a payment', async ({ page }) => {
  await page.goto('/track')
  await expect(page).toHaveURL(/\/track/)
  await expect(page.locator('body')).not.toContainText('The app hit a render error.')
})
