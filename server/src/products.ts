import type { Config } from './config.ts'

export type ProductKind = 'subscription' | 'lifetime'
export type ProductInfo = { id: string; kind: ProductKind; plan: 'monthly' | 'yearly' | 'lifetime'; priceUsd: number; trialDays: number }

/** Catalog (docs/marketing/MARKETING_PLAN.md): free live view; Pro $4.99/mo or $29.99/yr with a 7-day trial; Lifetime $49.99. */
export function catalog(cfg: Config): ProductInfo[] {
  return [
    { id: cfg.products.monthly, kind: 'subscription', plan: 'monthly', priceUsd: 4.99, trialDays: 7 },
    { id: cfg.products.yearly, kind: 'subscription', plan: 'yearly', priceUsd: 29.99, trialDays: 7 },
    { id: cfg.products.lifetime, kind: 'lifetime', plan: 'lifetime', priceUsd: 49.99, trialDays: 0 },
  ]
}

export function productById(cfg: Config, id: string): ProductInfo | undefined {
  return catalog(cfg).find((p) => p.id === id)
}
