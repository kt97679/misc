#!/usr/bin/env python

import shutil

MAX_ITERATIONS = 1000
COLOR_LEVELS = 6
NUMBER_OF_COLORS = COLOR_LEVELS ** 3

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
    xmin = -2
    xmax = 1
    ymin = -1.5
    ymax = 1.5

    pixel_data = calculate_pixel_data(xmin, xmax, ymin, ymax, width, height)
    for row in pixel_data:
        print(''.join(map(lambda x: '*' if x else ' ', row)))

main()
