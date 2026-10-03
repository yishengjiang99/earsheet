/** MySQL pool + forward-only SQL migrations (migrations/*.sql, recorded in schema_migrations). */
import fs from 'node:fs'
import path from 'node:path'
import mysql from 'mysql2/promise'

export type Db = mysql.Pool

export function createPool(): Db {
  const url = process.env.MYSQL_URL?.trim()
  const common = { waitForConnections: true, connectionLimit: 6, enableKeepAlive: true, timezone: 'Z', dateStrings: false } as const
  if (url) return mysql.createPool({ uri: url, ...common })
  return mysql.createPool({
    host: process.env.MYSQL_HOST?.trim() || '127.0.0.1',
    port: Number(process.env.MYSQL_PORT || 3306),
    user: process.env.MYSQL_USER?.trim() || 'music_radar',
    password: process.env.MYSQL_PASSWORD ?? '',
    database: process.env.MYSQL_DATABASE?.trim() || 'music_radar',
    ...common,
  })
}

export const MIGRATIONS_DIR = new URL('../migrations/', import.meta.url).pathname

/** Split a migration file into statements (no procedures/triggers, so ';' at line end is safe). */
export function splitSql(sql: string): string[] {
  return sql
    .split('\n')
    .filter((l) => !l.trim().startsWith('--'))
    .join('\n')
    .split(/;\s*(?:\n|$)/)
    .map((s) => s.trim())
    .filter(Boolean)
}

export async function migrate(db: Db, dir = MIGRATIONS_DIR): Promise<string[]> {
  await db.query(`CREATE TABLE IF NOT EXISTS schema_migrations (
    name VARCHAR(128) NOT NULL PRIMARY KEY,
    applied_at TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3)
  ) ENGINE=InnoDB`)
  const [rows] = await db.query<mysql.RowDataPacket[]>('SELECT name FROM schema_migrations')
  const done = new Set(rows.map((r) => r.name as string))
  const applied: string[] = []
  for (const f of fs.readdirSync(dir).filter((f) => f.endsWith('.sql')).sort()) {
    if (done.has(f)) continue
    for (const stmt of splitSql(fs.readFileSync(path.join(dir, f), 'utf8'))) await db.query(stmt)
    await db.query('INSERT INTO schema_migrations (name) VALUES (?)', [f])
    applied.push(f)
  }
  return applied
}

export const toDate = (ms: number | undefined | null): Date | null =>
  typeof ms === 'number' && Number.isFinite(ms) ? new Date(ms) : null
