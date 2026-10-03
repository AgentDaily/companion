"""Render explanatory storyboards, not recordings of implemented features.

Requires Pillow. Run with: conda run -n kora python scripts/render-readme-animations.py
Set COMPANION_FONT to a Chinese font path when rendering outside macOS.
"""
from pathlib import Path
from functools import lru_cache
import math
import os
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'docs/images'
W, H, SCALE = 920, 480, 2
FONT = os.environ.get('COMPANION_FONT', '/System/Library/Fonts/Hiragino Sans GB.ttc')
BG = '#101622'
PANEL = '#1c2535'
LINE = '#354359'
WHITE = '#f2f4fa'
MUTED = '#9aa9bf'
BLUE = '#8eb4ff'
MINT = '#83dcc3'
VIOLET = '#c5adff'


@lru_cache(maxsize=32)
def font(size):
    return ImageFont.truetype(FONT, size * SCALE)


def box(d, bounds, fill, radius=14, outline=None, width=1):
    d.rounded_rectangle(tuple(int(v*SCALE) for v in bounds), radius=radius*SCALE,
                        fill=fill, outline=outline, width=width*SCALE)


def text(d, xy, value, size=16, fill=WHITE):
    d.text(tuple(int(v*SCALE) for v in xy), value, font=font(size), fill=fill)


def line(d, coords, fill=LINE, width=2):
    d.line([(int(x*SCALE), int(y*SCALE)) for x,y in coords], fill=fill, width=width*SCALE)


def circle(d, x, y, r, fill):
    d.ellipse(tuple(int(v*SCALE) for v in (x-r,y-r,x+r,y+r)),fill=fill)


STORIES = [
    dict(name='companion-flow', title='一台 Mac，随身接入。',
         subtitle='Quenda 交互流程示意 · 共享连接，本机 Gateway 执行', tag='已有能力 · 示意', accent=BLUE,
         steps=['打开应用', '发送任务', '确认权限', '查看结果'],
         captions=['一次设备配对，进入自己的应用。', '手机发出请求，Mac 连接本机 Gateway。',
                   '需要工具权限时，回到手机确认。', '结果流式回到手机，继续这次会话。']),
    dict(name='idea-receipts', title='随手拍照，票据自动归档。',
         subtitle='应用构想 / 01 · 手机采集，Mac 本地识别与存储', tag='应用构想 · 尚未实现', accent=MINT,
         steps=['拍摄票据', '传到 Mac', '识别归档', '手机查看'],
         captions=['用手机拍下票据。', '通过配对连接，把图片交给自己的 Mac。',
                   '在 Mac 上运行 OCR，提取金额、日期与分类。', '手机查看归档结果，原始文件留在自己的设备。']),
    dict(name='idea-voice', title='说下想法，留下清晰笔记。',
         subtitle='应用构想 / 02 · 手机录音，Mac 本地转写与整理', tag='应用构想 · 尚未实现', accent=VIOLET,
         steps=['录下想法', '传到 Mac', '转写整理', '回看笔记'],
         captions=['在手机录下一段灵感。', '录音片段传给自己的 Mac。',
                   '本地 ASR 转写，可选本地模型整理重点。', '手机收到文本与待办，随时回看。']),
]


def devices(d, story, stage, t):
    accent=story['accent']
    # Device silhouettes and chrome, deliberately schematic rather than fake screenshots.
    box(d,(60,126,250,368),'#090e17',24,LINE)
    box(d,(69,136,241,357),PANEL,17)
    box(d,(119,143,191,151),'#090e17',4)
    text(d,(86,163),'Companion',19)
    text(d,(63,377),'iPhone / 采集与交互',13,MUTED)
    box(d,(560,143,854,349),PANEL,14,LINE)
    line(d,[(560,174),(854,174)])
    for i,c in enumerate(['#fa8e8c','#edc573','#8fcca8']): circle(d,577+i*14,159,3,c)
    text(d,(633,150),'Mac · 本地执行',12,MUTED)
    line(d,[(546,356),(868,356)],LINE,5)
    text(d,(597,377),'你的算力 / 文件 / 执行环境',13,MUTED)
    # Bidirectional encrypted device connection; reverse flow carries output.
    line(d,[(256,252),(554,252)],LINE)
    box(d,(317,212,490,288),BG,18,LINE)
    text(d,(338,223),'Companion',18,accent)
    text(d,(342,253),'共享加密连接',13,MUTED)
    direction = -1 if stage==3 else 1
    if stage in [1,3]:
        for k in range(3):
            pos=((t*1.2+k/3)%1)
            x=256+298*(pos if direction==1 else 1-pos)
            if x<312 or x>495:
                circle(d,x,252,4,accent)
    text(d,(326,300),'附近优先 · 远程可选',12,MUTED)
    name=story['name']
    if name=='companion-flow':
        text(d,(86,199),'Quenda',16,accent)
        if stage==0:
            box(d,(83,237,227,294),'#293a54',10)
            text(d,(96,249),'继续我的任务',15)
            text(d,(96,276),'发送  →',11,accent)
        elif stage==1:
            text(d,(87,242),'任务已发送',15)
            text(d,(87,273),'等待 Agent 响应',12,MUTED)
        elif stage==2:
            text(d,(86,233),'需要工具许可',15)
            box(d,(84,266,228,301),accent,8)
            text(d,(108,273),'允许本次',14,BG)
        else:
            text(d,(86,237),'收到任务结果',15,accent)
            for j in range(3):
                length=min(125,max(0,(t*4-j)*125))
                if length: box(d,(86,274+j*16,86+length,279+j*16),LINE,2)
        text(d,(581,192),'Quenda Gateway',18,accent)
        messages=[('独立运行','等待应用请求'),('Agent 处理请求','按应用 ID 路由'),
                  ('工具权限请求','等待用户决定'),('生成回答','结果流式返回')]
        for j,value in enumerate(messages[stage]): text(d,(582,232+j*29),value,16 if j==0 else 13,WHITE if j==0 else MUTED)
    elif name=='idea-receipts':
        if stage<3:
            box(d,(95,211,217,328),'#e9eee9',5)
            text(d,(113,220),'RECEIPT',12,'#34483f')
            for j,l in enumerate([80,58,76]): line(d,[(110,251+j*12),(110+l,251+j*12)],'#b0bdb5',2)
            text(d,(112,297),'¥ 128.00',15,'#34483f')
            if stage==0: line(d,[(91,219+t*104),(221,219+t*104)],accent,2)
        else:
            text(d,(87,213),'已归档',19,accent)
            text(d,(87,253),'餐饮 · ¥128.00',15)
            text(d,(87,285),'2026 / 10 / 04',12,MUTED)
        text(d,(582,192),'本地票据服务',18,accent)
        if stage<2:
            text(d,(582,237),'OCR / 提取 / 归档',16)
            text(d,(582,270),'等待图片' if stage==0 else '接收图片 …',13,MUTED)
        else:
            for j,(label,value) in enumerate([('金额','¥ 128.00'),('分类','餐饮'),('存储','本地票据目录')]):
                text(d,(582,230+j*30),label,13,MUTED)
                text(d,(646,230+j*30),value,14,WHITE)
    else:
        if stage<2:
            text(d,(87,212),'灵感录音',16,accent)
            for j in range(24):
                amplitude=5+abs(math.sin(j*.65+t*math.pi*3))*22
                line(d,[(88+j*5.5,276-amplitude),(88+j*5.5,276+amplitude)],accent,2)
            text(d,(95,321),'录制片段' if stage==0 else '传输片段 …',12,MUTED)
        elif stage==2:
            text(d,(87,235),'Mac 正在处理',15)
            text(d,(87,269),'转写 → 整理',13,MUTED)
        else:
            text(d,(87,214),'灵感笔记',17,accent)
            for j,v in enumerate(['试做一个读书工具','整理三篇论文','□ 周末做原型']): text(d,(86,251+j*26),v,12)
        text(d,(582,192),'本地语音服务',18,accent)
        if stage<2:
            text(d,(582,237),'ASR / 本地模型',16)
            text(d,(582,271),'等待录音' if stage==0 else '接收录音 …',13,MUTED)
        else:
            text(d,(582,229),'转写完成',15,accent)
            text(d,(582,259),'提取重点与待办',15)
            text(d,(582,293),'保存到本地笔记',13,MUTED)


def render(story, i):
    stage=i//24
    t=(i%24)/24
    im=Image.new('RGB',(W*SCALE,H*SCALE),BG)
    d=ImageDraw.Draw(im)
    text(d,(36,23),'COMPANION  /  YOUR DEVICES, CONNECTED',11,MUTED)
    box(d,(687,22,884,49),PANEL,12)
    text(d,(700,27),story['tag'],12,story['accent'])
    text(d,(36,52),story['title'],29)
    text(d,(37,95),story['subtitle'],13,MUTED)
    devices(d,story,stage,t)
    line(d,[(36,412),(884,412)],LINE,1)
    for j,label in enumerate(story['steps']):
        x=36+j*218
        circle(d,x+9,437,9,story['accent'] if j==stage else PANEL)
        text(d,(x+5,430),str(j+1),10,BG if j==stage else MUTED)
        text(d,(x+26,427),label,14,WHITE if j==stage else MUTED)
        if j<3: text(d,(x+180,429),'→',13,MUTED)
    text(d,(36,456),story['captions'][stage],12,MUTED)
    return im.resize((W,H),Image.Resampling.LANCZOS)


def main():
    OUT.mkdir(parents=True,exist_ok=True)
    previews=[]
    for story in STORIES:
        frames=[render(story,i) for i in range(96)]
        # One palette for every frame keeps static backgrounds and text stable.
        sample=Image.new('RGB',(W,H*4))
        for j in range(4): sample.paste(frames[j*24+12],(0,j*H))
        palette=sample.quantize(colors=128)
        indexed=[f.quantize(palette=palette,dither=Image.Dither.NONE) for f in frames]
        target=OUT/(story['name']+'.gif')
        indexed[0].save(target,save_all=True,append_images=indexed[1:],duration=100,
                        loop=0,optimize=True,disposal=1)
        with Image.open(target) as gif:
            assert gif.n_frames>1 and gif.size==(W,H)
        print(f'{target.name}: {target.stat().st_size/1024:.0f} KiB',flush=True)
        previews.append(sample.resize((690,1440)))
    contact=Image.new('RGB',(690*3,1440))
    for j,p in enumerate(previews): contact.paste(p,(j*690,0))
    contact.save('/tmp/companion-animation-review.jpg')


if __name__=='__main__':
    main()
