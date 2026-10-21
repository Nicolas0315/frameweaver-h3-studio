import { expect, test, type Page } from '@playwright/test'

async function mockAuthenticatedApp(page: Page) {
  await page.route('**/api/auth/me', (route) => route.fulfill({ json: { enabled: true, authenticated: true, displayName: 'Test User' } }))
  await page.route('**/api/workers', (route) => route.fulfill({ json: { workers: [
    { id: 'rtx5060ti', label: 'RTX 5060 Ti', capabilities: ['image'], online: true, stale: false, free_vram_mb: 12288, queue_depth: 0 },
    { id: 'rtx4090', label: 'RTX 4090', capabilities: ['image', 'video'], online: true, stale: false, free_vram_mb: 20480, queue_depth: 0 },
  ] } }))
  await page.route('**/api/jobs?**', (route) => route.fulfill({ json: { jobs: [] } }))
  await page.route('**/api/fleet', (route) => route.fulfill({ json: { samples: [], at: '2026-08-22T00:00:00Z', collecting: false } }))
  await page.route('**/comfy/**', (route) => route.fulfill({ status: 404, json: {} }))
}

test('unauthenticated user sees only Discord login', async ({ page }) => {
  await page.route('**/api/auth/me', (route) => route.fulfill({ status: 401, json: { error: 'authentication_required' } }))
  await page.goto('/')
  await expect(page.getByRole('link', { name: 'Discordでログイン' })).toHaveAttribute('href', '/auth/login')
  await expect(page.getByRole('button', { name: /生成/ })).toHaveCount(0)
})

test('authenticated desktop and mobile expose safe GPU selection without endpoint data', async ({ page }) => {
  await mockAuthenticatedApp(page)
  await page.goto('/')
  const selector = page.getByLabel('生成GPU')
  await expect(selector).toBeVisible()
  await expect(selector).toHaveValue('auto')
  await selector.selectOption('rtx5060ti')
  await expect(selector).toHaveValue('rtx5060ti')
  await expect(page.locator('body')).not.toContainText('tail37947a.ts.net')
})

for (const completedAtCreate of [true, false]) {
  test(`persisted image completion without a websocket event (create terminal=${completedAtCreate})`, async ({ page }) => {
    await mockAuthenticatedApp(page)
    await page.route('**/rewriter/models', (route) => route.fulfill({ json: { models: [] } }))
    await page.routeWebSocket('**/comfy/ws**', () => {})
    const jobId = '22222222-2222-4222-8222-222222222222'
    let stored: Record<string, unknown> = {}
    let reads = 0
    await page.route('**/api/jobs', async (route) => {
      const input = route.request().postDataJSON() as { mode: string; prompt: string; settings: object }
      stored = {
        id: jobId, owner_id: route.request().headers()['x-frameweaver-owner'], kind: 'image', mode: input.mode,
        prompt: input.prompt, settings_json: JSON.stringify(input.settings), status: 'succeeded',
        output_json: JSON.stringify([{ filename: 'fixture.png', subfolder: '', type: 'output' }]), error: null,
        created_at: '2026-10-21T00:00:00Z', updated_at: '2026-10-21T00:00:01Z', started_at: null, finished_at: null,
      }
      await route.fulfill({ status: 201, json: completedAtCreate ? stored : { ...stored, status: 'queued', output_json: null } })
    })
    await page.route(`**/api/jobs/${jobId}`, async (route) => {
      reads++
      await route.fulfill({ json: stored })
    })
    await page.route('**/comfy/view?**', (route) => route.fulfill({
      contentType: 'image/png', body: Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII=', 'base64'),
    }))
    await page.goto('/')
    await page.getByRole('button', { name: '閉じる', exact: true }).click()
    await page.getByRole('button', { name: /画像生成.*Krea/ }).click()
    await page.getByPlaceholder(/生成したい画像を詳しく/).fill('fixture image')
    await page.locator('.generate-bar').getByRole('button', { name: /画像/ }).click()
    const result = page.getByAltText('生成画像')
    await expect(result).toBeVisible()
    await expect(result).toHaveAttribute('src', /prompt_id=22222222-2222-4222-8222-222222222222.*owner=/)
    await expect(page.locator('.generate-bar').getByRole('button', { name: '■ 停止' })).toHaveCount(0)
    await expect(page.locator('.generate-bar').getByRole('button', { name: /画像/ })).toBeEnabled()
    if (!completedAtCreate) expect(reads).toBeGreaterThan(0)
  })
}
