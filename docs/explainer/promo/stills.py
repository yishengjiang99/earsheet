import sys
from playwright.sync_api import sync_playwright
mode=sys.argv[1]; ts=[float(x) for x in sys.argv[2:]]
W,H=(1080,1920) if mode=='tiktok' else (1920,1080)
with sync_playwright() as p:
    b=p.chromium.launch(executable_path='/usr/bin/google-chrome',args=['--allow-file-access-from-files'])
    pg=b.new_page(viewport={'width':W,'height':H})
    pg.on('console',lambda m:print('console',m.text)); pg.on('pageerror',lambda e:print('ERR',e))
    pg.goto(f'file:///workspace/vid2/site/scene.html?mode={mode}'); pg.wait_for_timeout(500)
    for t in ts:
        pg.evaluate(f'renderAt({t})'); pg.screenshot(path=f'still-{mode}-{t}.png')
    b.close()
