#!/usr/bin/env python3
"""Disegna l'icona di Booth (stessa famiglia di Dolly) e costruisce Booth.icns.
Uso: python3 icon/generate_icon.py   → icon/Booth-1024.png, icon/Booth.icns (servono sips e iconutil)"""
import math, os, shutil, struct, subprocess, zlib
S=4; N=1024*S
BG=(0x16,0x16,0x16,255); W=(0xF4,0xF4,0xF0,255); G=(0xD3,0xD3,0xCC,255); R=(0xE0,0x3A,0x2F,255)
def canvas(): return bytearray(N*N*4)
def poly(b,pts,c):
    pts=[(x*S,y*S) for x,y in pts]; ink=bytes(c)
    y0=max(0,int(min(p[1] for p in pts))); y1=min(N-1,int(max(p[1] for p in pts))+1)
    for y in range(y0,y1+1):
        s=y+.5; xs=[]
        for (a,b2),(c2,d) in zip(pts,pts[1:]+pts[:1]):
            if (b2<=s<d) or (d<=s<b2): xs.append(a+(s-b2)*(c2-a)/(d-b2))
        xs.sort()
        for a,e in zip(xs[::2],xs[1::2]):
            l=max(0,math.ceil(a-.5)); r=min(N-1,math.floor(e-.5))
            if r>=l: o=(y*N+l)*4; b[o:o+(r-l+1)*4]=ink*(r-l+1)
def arc(cx,cy,r,a0,a1,n=400): return [(cx+r*math.cos(a0+(a1-a0)*i/n),cy+r*math.sin(a0+(a1-a0)*i/n)) for i in range(n+1)]
def disc(b,cx,cy,r,c): poly(b,arc(cx,cy,r,0,2*math.pi)[:-1],c)
def ring(b,cx,cy,r,w,c,bg=BG): disc(b,cx,cy,r,c); disc(b,cx,cy,r-w,bg)
def squircle(b):
    pts=[]
    for i in range(1440):
        a=2*math.pi*i/1440; ca,sa=math.cos(a),math.sin(a)
        pts.append((512+412*math.copysign(abs(ca)**.4,ca),512+412*math.copysign(abs(sa)**.4,sa)))
    poly(b,pts,BG)
def rrect(b,x0,y0,x1,y1,r,c):
    p=arc(x1-r,y0+r,r,-math.pi/2,0,60)+arc(x1-r,y1-r,r,0,math.pi/2,60)+arc(x0+r,y1-r,r,math.pi/2,math.pi,60)+arc(x0+r,y0+r,r,math.pi,1.5*math.pi,60)
    poly(b,p,c)
def bowl(b,x,yt,yb,ext,c):  # rettangolo + mezzo disco a destra
    r=(yb-yt)/2; cy=(yt+yb)/2
    poly(b,[(x,yt),(x+ext,yt)]+arc(x+ext,cy,r,-math.pi/2,math.pi/2)[1:-1]+[(x+ext,yb),(x,yb)],c)
def letterB(b,dx=0):
    # stessa griglia della D di Dolly e della P: asta 130, altezza 277-747, tratti orizzontali 85
    x=445+dx
    poly(b,[(315+dx,277),(x,277),(x,747),(315+dx,747)],W)
    bowl(b,x,277,542,15,W); bowl(b,x,457,747,30,W)
    bowl(b,x,362,457,0,BG); bowl(b,x,542,662,15,BG)
def render():  # la B di Booth con il fascio del proiettore che esce dalla pancia
    b=canvas(); squircle(b)
    poly(b,[(560,560),(560,690),(840,790),(840,460)],G)
    letterB(b,-40); disc(b,785,250,34,R); return b
def png(path,b,n):
    raw=b"".join(b"\x00"+bytes(b[y*n*4:(y+1)*n*4]) for y in range(n))
    ch=lambda k,d: struct.pack(">I",len(d))+k+d+struct.pack(">I",zlib.crc32(k+d)&0xffffffff)
    open(path,"wb").write(b"\x89PNG\r\n\x1a\n"+ch(b"IHDR",struct.pack(">IIBBBBB",n,n,8,6,0,0,0))+ch(b"IDAT",zlib.compress(raw,3))+ch(b"IEND",b""))

if __name__ == "__main__":
    root = os.path.dirname(os.path.abspath(__file__)); hi = os.path.join(root, "Booth-4096.png"); full = os.path.join(root, "Booth-1024.png")
    png(hi, render(), N)
    run = lambda *a: subprocess.run(a, check=True, capture_output=True)
    run("sips", "-z", "1024", "1024", hi, "--out", full); os.remove(hi)
    iconset = os.path.join(root, "Booth.iconset"); shutil.rmtree(iconset, ignore_errors=True); os.makedirs(iconset)
    for size in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            run("sips", "-z", str(size*scale), str(size*scale), full, "--out", os.path.join(iconset, f"icon_{size}x{size}{'@2x' if scale == 2 else ''}.png"))
    run("iconutil", "-c", "icns", iconset, "-o", os.path.join(root, "Booth.icns")); shutil.rmtree(iconset)
    print("Booth-1024.png, Booth.icns")
