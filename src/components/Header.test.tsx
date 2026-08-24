// @vitest-environment jsdom
import '@testing-library/jest-dom/vitest'
import { render, screen } from '@testing-library/react'
import { describe, expect, it, vi } from 'vitest'

vi.mock('../store/generation', () => ({
  client: { baseUrl: 'http://127.0.0.1:8188/comfy' },
  useGenerationStore: <T,>(selector: (state: {
    connected: boolean
    queueRemaining: number
    stop: () => Promise<void>
    setGuideOpen: (open: boolean) => void
  }) => T) => selector({
    connected: true,
    queueRemaining: 0,
    stop: async () => {},
    setGuideOpen: () => {},
  }),
}))

import { Header } from './Header'

describe('Header', () => {
  it('does not render a second VRAM meter outside the fleet telemetry panel', () => {
    render(<Header />)

    expect(screen.getByText('ComfyUI 接続済み')).toBeInTheDocument()
    expect(screen.queryByText('COMFY使用')).not.toBeInTheDocument()
  })
})
