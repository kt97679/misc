#!/usr/bin/env python

import shutil

color = [
    '\x1b[30m', # blk
    '\x1b[31m', '\x1b[91m', # red
    '\x1b[32m', '\x1b[92m', # grn
    '\x1b[33m', '\x1b[93m', # ylw
    '\x1b[34m', '\x1b[94m', # blu
    '\x1b[35m', '\x1b[95m', # mgn
    '\x1b[36m', '\x1b[96m', # cyn
    '\x1b[37m', '\x1b[97m'  # wht
]
color_reset = '\x1b[0m'

MAX_ITERATIONS = 1000
NUMBER_OF_COLORS = len(color)

def get_pixel_color(cx, cy):
    x0, y0 = 0, 0
    for i in range(MAX_ITERATIONS):
        x0, y0 = (x0 * x0 - y0 * y0 + cx), (2 * x0 * y0 + cy)
        if (x0 * x0 + y0 * y0 > 4):
            return i % NUMBER_OF_COLORS
    return 0

def calculate_pixel_data(xmin, xmax, ymin, ymax, width, height):
    dx = (xmax - xmin) / width
    dy = (ymax - ymin) / height
    data = []
    for y in range(height):
        row = []
        cy = ymin + y * dy
        for x in range(width):
            cx = xmin + x * dx
            row.append(get_pixel_color(cx, cy))
        data.append(row)
    return data

def main():
    width, height = shutil.get_terminal_size()
    width *= 2
    height = (height - 1) * 4
    xmin = -2.0
    xmax = 1.0
    ymin = -1.5
    ymax = 1.5
    data = calculate_pixel_data(xmin, xmax, ymin, ymax, width, height)
    for y in range(0, height, 4):
        b = []
        for x in range(0, width, 2):
            d = 0
            e = 0
            for xx, yy in [[1, 3], [0, 3], [1, 2], [1, 1], [1, 0], [0, 2], [0, 1], [0, 0]]:
                d <<= 1
                f = data[y + yy][x + xx]
                if f:
                    e += f
                    d |= 1
            c = ((0xE2A0 + (d >> 6)) << 8) + 0x80 + (d & 63)
            b.append(color[int(e / 8) % NUMBER_OF_COLORS])
            b.append((c).to_bytes(3, byteorder='big').decode("utf-8"))
            b.append(color_reset)
        print("".join(b))

main()
