import json, sys
from playwright.sync_api import sync_playwright
out={}
with sync_playwright() as p:
    b=p.chromium.launch(executable_path='/usr/bin/google-chrome',args=['--autoplay-policy=no-user-gesture-required'])
    pg=b.new_page(viewport={'width':1000,'height':1400})
    pg.on('console', lambda m: print('console:',m.text) if 'rror' in m.text else None)
    pg.goto('http://localhost:8765/index.html')
    pg.wait_for_function("document.getElementById('model-status').textContent.includes('ready')",timeout=120000)
    for name in sys.argv[1:]:
        pg.set_input_files('#file-input', f'{name}.wav')
        pg.wait_for_function("!document.getElementById('run-btn').disabled",timeout=60000)
        pg.click('#run-btn')
        pg.wait_for_function("!document.getElementById('results').hidden && document.querySelectorAll('#note-table tbody tr').length>0",timeout=120000)
        pg.wait_for_timeout(1500)
        rows=pg.eval_on_selector_all('#note-table tbody tr',"rs=>rs.map(r=>[...r.children].map(c=>c.textContent))")
        out[name]={'rows':rows,'quant':pg.inner_text('#quant-info'),'timing':pg.inner_text('#timing'),
                   'svg':pg.eval_on_selector('#staff','e=>e.innerHTML')}
        pg.screenshot(path=f'demo-{name}.png',full_page=True)
        print(name,len(rows),out[name]['quant'],out[name]['timing'])
    b.close()
json.dump(out,open('demo.json','w'))
