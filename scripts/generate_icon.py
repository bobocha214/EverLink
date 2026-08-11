from PIL import Image, ImageDraw

SIZE = 1024
BG = (0, 137, 123)  # teal #00897B
WHITE = (255, 255, 255)
CORNER_RADIUS = 240

# Node positions (diagonal, inside adaptive-icon safe zone)
NODE1 = (360, 360)
NODE2 = (664, 664)
MIDDLE = (512, 512)
NODE_RADIUS = 95
LINK_WIDTH = 36
PULSE_RADIUS = 48


def draw_rounded_rect(draw, xy, radius, fill):
    draw.rounded_rectangle(xy, radius=radius, fill=fill)


def draw_icon(draw):
    # Link line with rounded caps
    draw.line([NODE1, NODE2], fill=WHITE, width=LINK_WIDTH)
    # Middle pulse dot
    draw.ellipse(
        [MIDDLE[0] - PULSE_RADIUS, MIDDLE[1] - PULSE_RADIUS,
         MIDDLE[0] + PULSE_RADIUS, MIDDLE[1] + PULSE_RADIUS],
        fill=WHITE,
    )
    # Nodes
    for cx, cy in (NODE1, NODE2):
        draw.ellipse(
            [cx - NODE_RADIUS, cy - NODE_RADIUS,
             cx + NODE_RADIUS, cy + NODE_RADIUS],
            fill=WHITE,
        )


def main():
    base = Image.new('RGBA', (SIZE, SIZE), (0, 0, 0, 0))
    draw = ImageDraw.Draw(base)

    # Full icon (background + glyph)
    full = base.copy()
    d = ImageDraw.Draw(full)
    draw_rounded_rect(d, (0, 0, SIZE, SIZE), CORNER_RADIUS, BG)
    draw_icon(d)
    full.save('assets/icon/icon_source.png')

    # Android adaptive foreground (transparent bg + glyph)
    fg = base.copy()
    d2 = ImageDraw.Draw(fg)
    draw_icon(d2)
    fg.save('assets/icon/icon_foreground.png')

    print('Generated assets/icon/icon_source.png and icon_foreground.png')


if __name__ == '__main__':
    main()
