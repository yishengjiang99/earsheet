import { createPool, migrate } from './db.ts'
const db = createPool()
migrate(db)
  .then((a) => { console.log(a.length ? `applied: ${a.join(', ')}` : 'up to date') })
  .finally(() => db.end())
