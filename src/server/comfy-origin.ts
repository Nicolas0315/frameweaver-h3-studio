import type { ProxyOptions } from 'vite'

type Headers = Record<string, string | string[] | undefined>

export function trustedComfyOrigin(headers: Headers, trustedOrigins: string[] = []): boolean {
  const origin = headers.origin
  if (origin === undefined) return headers['sec-fetch-site'] !== 'cross-site'
  if (typeof origin !== 'string' || typeof headers.host !== 'string') return false
  try {
    const parsed = new URL(origin)
    if (!['http:', 'https:'].includes(parsed.protocol) || parsed.origin !== origin) return false
    return (parsed.host === headers.host && headers['sec-fetch-site'] !== 'cross-site') || trustedOrigins.some((value) => new URL(value).origin === origin)
  } catch {
    return false
  }
}

export function comfyOriginGuard(target: string, trustedOrigins: string[] = []): NonNullable<ProxyOptions['configure']> {
  return (proxy) => {
    proxy.on('proxyReq', (outgoing, incoming, response) => {
      if (trustedComfyOrigin(incoming.headers, trustedOrigins)) {
        outgoing.setHeader('origin', new URL(target).origin)
        return
      }
      response.writeHead(403)
      response.end('Forbidden origin')
      outgoing.destroy()
    })
    proxy.on('proxyReqWs', (outgoing, incoming, socket) => {
      if (trustedComfyOrigin(incoming.headers, trustedOrigins)) {
        outgoing.setHeader('origin', new URL(target).origin)
        return
      }
      socket.end('HTTP/1.1 403 Forbidden\r\nConnection: close\r\n\r\n')
      outgoing.destroy()
    })
  }
}
