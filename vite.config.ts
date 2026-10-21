import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import tailwindcss from '@tailwindcss/vite'
import { comfyOriginGuard } from './src/server/comfy-origin.ts'

const API_TARGET = process.env.FRAMEWEAVER_API_URL ?? 'http://127.0.0.1:5181'
const proxy = {
  '/api': { target: API_TARGET, changeOrigin: true },
  '/auth': { target: API_TARGET, changeOrigin: true },
  '/rewriter': { target: API_TARGET, changeOrigin: true },
  '/comfy': {
    target: API_TARGET,
    changeOrigin: true,
    ws: true,
    configure: comfyOriginGuard(API_TARGET, (process.env.FRAMEWEAVER_TRUSTED_ORIGINS ?? '').split(',').filter(Boolean)),
  },
}

export default defineConfig({
  plugins: [react(), tailwindcss()],
  server: {
    host: '127.0.0.1',
    port: 5180,
    strictPort: true,
    allowedHosts: ['rtx4090.tail37947a.ts.net'],
    proxy,
  },
  preview: { host: '127.0.0.1', port: 5180, strictPort: true, proxy },
})
