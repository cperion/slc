# UI style and layout: Tailwind-granular instructions

**Approved authoring contract; implementation is partial.** This replaces the old
property-table/style-table surface in [UI components](ui-components.md).

Every construction block opens its applicable instructions and the bound theme's
typed tokens. Construction runs once, while the component type is built. The result
is ordinary native fields, not a runtime utility interpreter.

```lua
local primary = ui.style do(..)
    px 4
    py 2
    rounded md
    bg blue_600
    text_color white
    hover do(..) bg blue_700 end
    disabled do(..) opacity 50 end
end

local Dialog = ui.component "Dialog" do(..)
    column do(..)
        p 4
        gap 3
        button "save_button" do(..)
            use primary
            caption "Save"
        end
    end
end
```

## Names and scales

Tailwind's `prefix-value` becomes `prefix value`; internal token dashes become
underscores. Numeric spacing values use the theme's spacing multiplier (default 4).
Raw dimensions are explicit: `w(pixels 200)`; grid fractions are `fr 1`.

| Utility family | Instructions |
|---|---|
| Padding/margin | `p`, `px`, `py`, `pt`, `pr`, `pb`, `pl`; corresponding `m` forms |
| Size | `w`, `h`, `min_w`, `max_w`, `min_h`, `max_h`, `square` |
| Containers | `row`, `column`, `flex`, `grid`, `stack`, `modal` |
| Flow | `gap`, `gap_x`, `gap_y`, `items`, `justify`, `wrap`, `direction` |
| Child placement | `grow`, `shrink`, `basis`, `align`, `span`, `row_span`, `col_start`, `inset`, `layer` |
| Typography | `caption`, `text_size`, `text_color`, `weight`, `font`, `line_height`, `tracking`, `text_align`, `truncate` |
| Appearance | `bg`, `border`, `border_color`, `rounded`, `shadow`, `opacity`, `ring`, `ring_color`, `cursor` |
| Participation | `visible`, `enabled`, `clip` |

**Collision decisions:**

- `leading` / `trailing` are alignment tokens; **`line_height tight`** sets typography.
- `text_size`, `text_color`, and `caption` distinguish three meanings of “text”.
- `square` sets width and height; `pixels` is the raw unit, leaving `px` as padding-x.
- `align` avoids the method receiver name `self`.
- `row` and `column` are containers; variable direction uses `flex` and
  `direction horizontal` / `direction vertical`.
- Size tokens stay `sm`, `md`, `lg`, `xl`; breakpoint blocks are `from_sm`,
  `from_md`, `from_lg`, `from_xl`.
- Switches take `on` / `off`; a bare name is not an instruction statement.

A name a receiver lacks falls through lexically to enclosing scopes. Thus `gap`
inside a button may affect its enclosing row. A name a receiver supplies shadows
an earlier local; a later local shadows it in turn. Leaving the block restores the
outer vocabulary. One instruction per line is the default: `rounded md bg red_600`
is not two statements.

Tokens distinguish colour, size, fraction, alignment, switch, weight, font,
direction and cursor. A size name is looked up in the instruction's own scale;
`text_size md` fails if `md` is not in `text_sizes`. Theme token-kind collisions are
errors. Colours stored at runtime are native `ui.Color` values, not token objects.
`bg(black / 50)` constructs a translucent colour token.

## Themes and sharing

```lua
local theme = ui.theme {
    spacing = 4,
    colors = ui.palettes.tailwind { accent = ui.colors.blue_600 },
    radii = { sm = 2, md = 6, lg = 8, xl = 12, full = 9999 },
    shadows = { sm = 1, md = 4, lg = 8, none = 0 },
    text_sizes = { xs = 12, sm = 14, base = 16, lg = 18, xl = 20 },
    breakpoints = { sm = 640, md = 768, lg = 1024, xl = 1280 },
}
local component = ui.with_theme(theme).component
```

Binding a theme does not mutate a global current theme. `ui.style` retains its
construction block and `use` runs it on the receiving vocabulary. Later instructions
win; there is no selector specificity, merge policy or stored runtime callback.

## Variants

Interaction variants are `hover`, `active`, `focus`, `disabled`; breakpoint variants
use the theme's minimum widths. Nested blocks conjoin conditions. Nesting order does
not change that conjunction; among applicable overrides, declaration order wins.
The overrides themselves are native fields. Known interaction state can eliminate
selection branches. Layout must resolve the same overrides as drawing.

## Implementation boundary

The [builders](../lib/ui.slc), [tokens](../lib/ui/theme.slc), and
[property vocabulary](../lib/ui/properties.slc) construct the fields and variants.
The [tree words](../lib/ui/tree.slc) perform measure/arrange, routing and traversal;
[SDL](../lib/ui/sdl.slc) supplies window/input/font/rendering capabilities.

The current executable slice uses row/column spacing and fixed dimensions,
buttons, labels, numbers, modal children, generated event sums, pointer activation,
colour/opacity variants and real SDL_ttf text. The vocabulary is broader than the
current layout/renderer: full grid tracks/spans, flex growth/shrink/wrap, margins,
stack ordering, clipping, keyboard focus, typography beyond font size, and
border/radius/shadow/ring rendering are **not complete**. Do not treat successful
construction of those properties as proof of rendering support. These are remaining
implementation tasks, not alternate interpretations or fallback behavior.
