import { defineConfig } from 'vitest/config'

export default defineConfig({
  test: {
    exclude: ['.worktrees/**', 'e2e/**', 'node_modules/**', 'dist/**'],
  },
})
