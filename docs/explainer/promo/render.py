import sys, subprocess
from playwright.sync_api import sync_playwright
mode,out=sys.argv[1],sys.argv[2]; fps=30
W,H=(1080,1920) if mode=='tiktok' else (1920,1080)
with sync_playwright() as p:
    b=p.chromium.launch(executable_path='/usr/bin/google-chrome',args=['--allow-file-access-from-files'])
    pg=b.new_page(viewport={'width':W,'height':H})
    pg.on('pageerror',lambda e:print('ERR',e))
    pg.goto(f'file:///workspace/vid2/site/scene.html?mode={mode}'); pg.wait_for_timeout(800)
    dur=pg.evaluate('DUR'); n=round(dur*fps)
    ff=subprocess.Popen(['ffmpeg','-v','error','-y','-f','image2pipe','-framerate',str(fps),'-c:v','mjpeg','-i','-','-c:v','libx264','-preset','slow','-crf','19','-pix_fmt','yuv420p','-r',str(fps),out],stdin=subprocess.PIPE)
    for i in range(n):
        pg.evaluate(f'renderAt({i/fps})')
        ff.stdin.write(pg.screenshot(type='jpeg',quality=93))
        if i%150==0: print(mode,i,'/',n,flush=True)
    ff.stdin.close(); ff.wait(); b.close()
print('done',out)
