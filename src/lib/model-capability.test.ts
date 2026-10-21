import { describe, expect, it } from 'vitest'
import {
  normalizeModelPath,
  rankModels,
  type NodeCapabilitySnapshot,
} from './model-capability'

function imageSnapshot(overrides: Partial<NodeCapabilitySnapshot> = {}): NodeCapabilitySnapshot {
  return {
    capturedAt: '2026-08-24T00:00:00.000Z',
    status: 'ready',
    accelerator: 'cuda',
    devices: [{ name: 'Test GPU', kind: 'cuda', vramTotal: 24 * 1024 ** 3, vramFree: 20 * 1024 ** 3 }],
    queueRemaining: 0,
    inventory: {
      checkpoints: ['waiillustrioussdxl_v170.safetensors'],
      unets: ['z_image_turbo_nvfp4.safetensors'],
      clips: ['qwen_3_4b.safetensors'],
      vaes: ['ae_zimage.safetensors'],
      loras: [],
    },
    features: [],
    errors: [],
    ...overrides,
  }
}

describe('normalizeModelPath', () => {
  it('Windows区切りと大文字小文字の差を同一モデルとして扱う', () => {
    expect(normalizeModelPath('Models\\Z_IMAGE_TURBO_NVFP4.SAFETENSORS')).toBe(
      'models/z_image_turbo_nvfp4.safetensors',
    )
  })
})

describe('rankModels', () => {
  it('導入済みで推奨VRAMを満たす画像モデルを安定した順序で返す', () => {
    const fits = rankModels(imageSnapshot(), 'image')

    expect(fits.map((fit) => [fit.model.id, fit.status])).toEqual([
      ['zimage', 'recommended'],
      ['anime', 'recommended'],
      ['krea2', 'unavailable'],
    ])
    expect(fits[0].reasons).toEqual(['installed', 'recommended-memory'])
    expect(fits[2].reasons).toContain('missing-model-files')
  })

  it('総VRAMは足りても空きVRAMが最小値未満なら注意にする', () => {
    const snapshot = imageSnapshot({
      devices: [{ name: 'Busy GPU', kind: 'cuda', vramTotal: 16 * 1024 ** 3, vramFree: 4 * 1024 ** 3 }],
    })

    const zimage = rankModels(snapshot, 'image').find((fit) => fit.model.id === 'zimage')

    expect(zimage?.status).toBe('warning')
    expect(zimage?.reasons).toContain('low-free-vram')
  })

  it('最小VRAM未満はモデルが導入済みでも利用不可にする', () => {
    const snapshot = imageSnapshot({
      devices: [{ name: 'Small GPU', kind: 'cuda', vramTotal: 6 * 1024 ** 3, vramFree: 6 * 1024 ** 3 }],
    })

    const zimage = rankModels(snapshot, 'image').find((fit) => fit.model.id === 'zimage')

    expect(zimage?.status).toBe('unavailable')
    expect(zimage?.reasons).toContain('insufficient-vram')
  })

  it('古い能力値を推奨根拠にせず注意として返す', () => {
    const snapshot = imageSnapshot({ status: 'stale' })

    const zimage = rankModels(snapshot, 'image').find((fit) => fit.model.id === 'zimage')

    expect(zimage?.status).toBe('warning')
    expect(zimage?.reasons).toContain('stale-capability')
  })

  it('必須ファイルの一部だけでは導入済みと判定しない', () => {
    const snapshot = imageSnapshot({
      inventory: {
        checkpoints: [],
        unets: ['z_image_turbo_nvfp4.safetensors'],
        clips: [],
        vaes: ['ae_zimage.safetensors'],
        loras: [],
      },
    })

    const zimage = rankModels(snapshot, 'image').find((fit) => fit.model.id === 'zimage')

    expect(zimage?.status).toBe('unavailable')
    expect(zimage?.missingFiles).toEqual(['qwen_3_4b.safetensors'])
  })
})


describe('reviewed capability boundaries', () => {
  it('uses the first execution device even when the second GPU is larger', () => {
    const snapshot = imageSnapshot()
    snapshot.devices.unshift({ name: 'Execution GPU', kind: 'cuda', vramTotal: 4 * 1024 ** 3, vramFree: 3 * 1024 ** 3 })
    expect(rankModels(snapshot, 'image').find((fit) => fit.model.id === 'zimage')?.status).toBe('unavailable')
  })
  it('ranks the selected anime checkpoint', () => {
    const snapshot = imageSnapshot()
    snapshot.inventory.checkpoints = ['alternative.safetensors']
    expect(rankModels(snapshot, 'image', 'alternative.safetensors').find((fit) => fit.model.id === 'anime')?.status).toBe('recommended')
  })
  it('does not accept subfolder paths for workflows submitting a bare filename', () => {
    const snapshot = imageSnapshot()
    snapshot.inventory.unets = ['sub/z_image_turbo_nvfp4.safetensors']
    expect(rankModels(snapshot, 'image').find((fit) => fit.model.id === 'zimage')?.missingFiles).toContain('z_image_turbo_nvfp4.safetensors')
  })
  it('requires both H3 VAEs', () => {
    const snapshot = imageSnapshot()
    snapshot.inventory.unets = ['minimax_h3_fl2va_pruned_int8_convrot.safetensors']
    snapshot.inventory.clips = ['qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors']
    snapshot.inventory.vaes = ['minimax_h3_video_vae_fp16.safetensors']
    expect(rankModels(snapshot, 'video')[0].missingFiles).toContain('minimax_h3_audio_vae_fp32.safetensors')
    snapshot.inventory.vaes.push('minimax_h3_audio_vae_fp32.safetensors')
    expect(rankModels(snapshot, 'video')[0].status).toBe('recommended')
  })
})
