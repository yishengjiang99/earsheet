// Builds the generated parts of web/ (gitignored): vendor/lib.js, vendor/*.wasm,
// vendor/abcjs-basic-min.js and model/ (Basic Pitch TF.js weights, Apache-2.0).
// Run: npm ci && node build.mjs
import { build } from 'esbuild';
import { createHash } from 'node:crypto';
import { copyFileSync, mkdirSync, readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const web = join(here, '..', '..', 'web');
const require = createRequire(import.meta.url);
const nm = (p) => join(here, 'node_modules', p);

// Pinned Basic Pitch TF.js model (@spotify/basic-pitch@1.0.1/model).
const MODEL_PINS = {
  'model.json': '1ed1aaee3409ec1dc098c8b01f430c0911f6fe9412e7af8086750f9e8f302f68',
  'group1-shard1of1.bin': 'b142a95737a52e1e412d5f92e73d8bb80dfe8d04941acc0702f11f4524fb377c',
};

mkdirSync(join(web, 'vendor'), { recursive: true });
mkdirSync(join(web, 'model'), { recursive: true });

await build({
  entryPoints: [join(here, 'entry.js')],
  bundle: true,
  minify: true,
  format: 'esm',
  target: 'es2020',
  platform: 'browser',
  outfile: join(web, 'vendor', 'lib.js'),
  // One tfjs for everything (basic-pitch pins tfjs 3 as a dependency).
  alias: {
    '@tensorflow/tfjs': nm('@tensorflow/tfjs'),
    '@tensorflow/tfjs-core': nm('@tensorflow/tfjs-core'),
  },
  define: { 'process.env.NODE_ENV': '"production"' },
  external: ['fs', 'path', 'worker_threads', 'perf_hooks', 'os', 'crypto'],
  legalComments: 'linked',
  logLevel: 'info',
});

for (const f of ['tfjs-backend-wasm.wasm', 'tfjs-backend-wasm-simd.wasm', 'tfjs-backend-wasm-threaded-simd.wasm']) {
  copyFileSync(nm(`@tensorflow/tfjs-backend-wasm/dist/${f}`), join(web, 'vendor', f));
}
copyFileSync(nm('abcjs/dist/abcjs-basic-min.js'), join(web, 'vendor', 'abcjs-basic-min.js'));

for (const [f, want] of Object.entries(MODEL_PINS)) {
  const src = nm(`@spotify/basic-pitch/model/${f}`);
  const got = createHash('sha256').update(readFileSync(src)).digest('hex');
  if (got !== want) throw new Error(`sha256 mismatch for ${f}: ${got} != ${want}`);
  copyFileSync(src, join(web, 'model', f));
}
copyFileSync(nm('@spotify/basic-pitch/LICENSE'), join(web, 'model', 'LICENSE-basic-pitch.txt'));
console.log('web/ vendor + model ready');
