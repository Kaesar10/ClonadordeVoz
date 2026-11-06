# -*- coding: utf-8 -*-
"""Genera el icono de la aplicación (icono.ico + icono.png).

Se dibuja a 1024 px y se reduce con LANCZOS para que los bordes salgan suaves.
Solo hace falta ejecutarlo si se quiere cambiar el diseño:

    python _crear_icono.py
"""
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

AQUI = Path(__file__).resolve().parent
LADO = 1024
SUPER = 1  # ya se dibuja a 1024, que es 4x el tamaño final de 256


def gradiente(lado: int, c1, c2):
    """Gradiente diagonal suave entre dos colores RGB."""
    x = np.linspace(0.0, 1.0, lado)[None, :]
    y = np.linspace(0.0, 1.0, lado)[:, None]
    t = np.clip(x * 0.55 + y * 0.45, 0.0, 1.0)[..., None]
    c1 = np.array(c1, dtype=np.float32)
    c2 = np.array(c2, dtype=np.float32)
    arr = c1 + (c2 - c1) * t
    return Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8), "RGB").convert("RGBA")


img = gradiente(LADO, (130, 100, 255), (52, 34, 176))

# --- Brillo suave arriba a la izquierda -----------------------------------
brillo = Image.new("L", (LADO, LADO), 0)
d = ImageDraw.Draw(brillo)
d.ellipse([-LADO * 0.35, -LADO * 0.55, LADO * 0.85, LADO * 0.55], fill=90)
brillo = brillo.filter(ImageFilter.GaussianBlur(LADO / 7))
capa = Image.new("RGBA", (LADO, LADO), (255, 255, 255, 0))
capa.putalpha(brillo)
img = Image.alpha_composite(img, capa)

# --- Esquinas redondeadas (máscara) ---------------------------------------
mascara = Image.new("L", (LADO, LADO), 0)
ImageDraw.Draw(mascara).rounded_rectangle(
    [0, 0, LADO - 1, LADO - 1], radius=int(LADO * 0.225), fill=255
)
img.putalpha(mascara)

# --- Micrófono ------------------------------------------------------------
S = LADO * SUPER
mic = Image.new("RGBA", (S, S), (0, 0, 0, 0))
dm = ImageDraw.Draw(mic)

BLANCO = (255, 255, 255, 255)
SOMBRA = (20, 10, 60, 70)

cx = S / 2
# sombra del cuerpo
dm.rounded_rectangle(
    [cx - 88 + 10, 205 + 18, cx + 88 + 10, 520 + 18], radius=88, fill=SOMBRA
)
# cuerpo del micrófono
dm.rounded_rectangle([cx - 88, 205, cx + 88, 520], radius=88, fill=BLANCO)

# arco (medio círculo) alrededor de la parte baja
dm.arc(
    [cx - 195, 325, cx + 195, 715],
    start=0,
    end=180,
    fill=BLANCO,
    width=46,
)

# pie y base
dm.rounded_rectangle([cx - 23, 690, cx + 23, 792], radius=6, fill=BLANCO)
dm.rounded_rectangle([cx - 112, 786, cx + 112, 834], radius=24, fill=BLANCO)

img = Image.alpha_composite(img, mic)

# --- Escalado y guardado --------------------------------------------------
final = img.resize((256, 256), Image.LANCZOS)
final.save(AQUI / "icono.png")
final.save(
    AQUI / "icono.ico",
    format="ICO",
    sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)],
)
print("Icono generado:", AQUI / "icono.ico")
