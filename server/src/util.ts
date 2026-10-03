import type { Request } from 'express'

export const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
export const isUuid = (v: unknown): v is string => typeof v === 'string' && UUID_RE.test(v)
export const str = (v: unknown, max: number): string | null =>
  typeof v === 'string' && v.trim() ? v.trim().slice(0, max) : null
export const clientIp = (req: Request): string =>
  (String(req.headers['x-real-ip'] || '') || req.ip || req.socket.remoteAddress || 'unknown').slice(0, 64)

/** Fixed-window per-key limiter (in-memory; one process per service). */
export class RateLimiter {
  private hits = new Map<string, { n: number; reset: number }>()
  constructor(private limit: number, private windowMs = 60_000) {}
  allow(key: string, now = Date.now()): boolean {
    const h = this.hits.get(key)
    if (!h || h.reset <= now) {
      if (this.hits.size > 50_000) this.hits.clear()
      this.hits.set(key, { n: 1, reset: now + this.windowMs })
      return true
    }
    h.n += 1
    return h.n <= this.limit
  }
}
