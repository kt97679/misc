#!/usr/bin/env python

MAX_ITERATIONS = 1000
COLOR_LEVELS = 6
NUMBER_OF_COLORS = COLOR_LEVELS ** 3
SIXEL_MAX_COLOR = 100

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


def prepare_sixel(pixel_data, width, height):
    # enter sixel mode
    out_buf = ['\x1bPq']
    for x in range(NUMBER_OF_COLORS):
        r = x % COLOR_LEVELS
        g = (x // COLOR_LEVELS) % COLOR_LEVELS
        b = (x // (COLOR_LEVELS ** 2))
        # populate color registers
        out_buf.append("#{};2;{};{};{}".format(x,
            int(r * SIXEL_MAX_COLOR / (COLOR_LEVELS - 1)),
            int(g * SIXEL_MAX_COLOR / (COLOR_LEVELS - 1)),
            int(b * SIXEL_MAX_COLOR / (COLOR_LEVELS - 1))))
    
    for y in range(0, height, 6):
        row = {}
        for x in range(width):
            for yy in range(6):
                # c is color of the current pixel
                c = pixel_data[y + yy][x]
                # let's check if we saw this color already ...
                if c not in row:
                    # ... and if not let's add empty sixel string
                    row[c] = ['?'] * width
                # here we update symbol in the sixel string by setting appropriate pixel
                row[c][x] = chr(ord(row[c][x]) + (1 << yy))
        for color, pixels in row.items():
            # output sixel string for each color
            out_buf.append('#{}{}$'.format(color, ''.join(pixels)))
        # go to the new line when we are done
        out_buf.append('-')
    # exit sixel mode
    out_buf.append('\x1b\\')
    return ''.join(out_buf)

def main():
    width = 510
    height = 510
    xmin = -2
    xmax = 1
    ymin = -1.5
    ymax = 1.5

    pixel_data = calculate_pixel_data(xmin, xmax, ymin, ymax, width, height)
    print(prepare_sixel(pixel_data, width, height), end='')

main()
