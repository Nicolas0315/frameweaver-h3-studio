import { describe, expect, it } from 'vitest'
import { trustedComfyOrigin } from './comfy-origin'

describe('Comfy proxy browser origins', () => {
  it('accepts the app origin at an arbitrary development port', () => {
    expect(trustedComfyOrigin({ host: 'localhost:5196', origin: 'http://localhost:5196' })).toBe(true)
  })
  it.each(['https://evil.test', 'null', 'http://localhost:5197'])('rejects an unrelated origin: %s', (origin) => {
    expect(trustedComfyOrigin({ host: 'localhost:5196', origin })).toBe(false)
  })
  it('accepts an explicitly trusted reverse proxy origin', () => {
    expect(trustedComfyOrigin({ host: 'localhost:5196', origin: 'https://tail.example' }, ['https://tail.example'])).toBe(true)
  })
  it('rejects browser cross-site traffic even without an Origin header', () => {
    expect(trustedComfyOrigin({ host: 'localhost:5196', 'sec-fetch-site': 'cross-site' })).toBe(false)
  })
})
