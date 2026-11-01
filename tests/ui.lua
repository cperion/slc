-- Real library construction tests, including lexical opening and native storage.
package.loaded['slc.driver_loaded'] = true
local slc = require 'slc'
local count = 0
local function compile(source) return slc.compile(source, 'tests/ui.slc') end
local function check(name, source, expected)
    local ok, result = pcall(compile, source)
    assert(ok, name .. ': ' .. tostring(result))
    if expected then assert(result:find(expected, 1, true), name .. ': missing ' .. expected .. '\n' .. result) end
    count = count + 1
end
local function reject(name, source, expected)
    local ok, result = pcall(compile, source)
    assert(not ok and tostring(result):find(expected, 1, true), name .. ': ' .. tostring(result))
    count = count + 1
end
local prefix = 'local ui = require "slc.ui"\n'
check('native component, methods, outcome and root properties', prefix .. [[
local Confirmation = ui.component "Confirmation" do(..)
    outcome oneof { reset: Unit, keep: Unit }
    modal do(..)
        w 80
        p 4
        gap 3
        rounded lg
        bg white
        label "question" do(..) caption "Reset the counter?" end
        row do(..)
            gap 2
            button "reset_button" do(..)
                px 4
                py 2
                bg red_600
                caption "Reset"
            end
            button "keep_button" do(..) caption "Keep value" end
        end
    end
end
function Confirmation:handle(event: Confirmation.Event): Confirmation.Outcome
    self:close()
    return event {
        reset_button() = Confirmation.Outcome.reset(),
        keep_button() = Confirmation.Outcome.keep(),
    }
end
local Counter = ui.component "Counter" do(..)
    column do(..)
        p 6
        number "count" do(..) value U32 0 end
        button "increment_button" do(..) caption "Increase" end
        part "confirm" (Confirmation)
    end
end
function Counter:handle(event: Counter.Event): Unit
    event {
        increment_button = do() self.count.value = self.count.value + 1 end,
        confirm = do(decision)
            decision { reset = do() self.count.value = 0 end, keep = do() end }
        end,
    }
end
local result = do(): U32
    local counter = ui.new Counter
    counter:handle(Counter.Event.increment_button())
    counter.confirm:open()
    counter:handle(Counter.Event.confirm(counter.confirm:handle(Confirmation.Event.keep_button())))
    return counter.count.value + U32 counter.padding_left
end
export result
]], 'return 25u;')
check('lexical fallback and restoration', prefix .. [[
local C = ui.component "Lexical" do(..)
    column do(..)
        gap 1
        row do(..)
            gap 2
            button "a" do(..)
                gap 3
                outcome oneof { done: Unit }
                caption "A"
            end
        end
        gap 4
    end
end
local f = do(): U32
    local c = ui.new C
    return U32 c.gap_x + U32 c.layout_2.gap_x
end
export f
]], 'return 28u;')
check('shared styles and last instruction wins', prefix .. [[
local primary = ui.style do(..)
    px 4
    bg blue_600
    hover do(..) bg blue_700 end
end
local C = ui.component "Styled" do(..)
    column do(..)
        button "save" do(..)
            use primary
            bg red_600
            caption "Save"
        end
    end
end
local f = do(): U32
    local c = ui.new C
    return U32 c.save.background.r + U32 c.save.padding_left
end
export f
]], 'return 236u;')
check('custom theme and explicit raw dimensions', prefix .. [[
local theme = ui.theme { spacing = 5, colors = ui.palettes.tailwind { accent = ui.colors.blue_600 } }
local component = ui.with_theme(theme).component
local C = component "Custom" do(..)
    column do(..)
        p 4
        w(pixels 201)
        button "b" do(..) bg accent end
    end
end
local f = do(): U32
    local c = ui.new C
    return U32 c.padding_left + U32 c.requested_width
end
export f
]], 'return 221u;')
check('line height and leading token coexist', prefix .. [[
local C = ui.component "Typography" do(..)
    row do(..)
        items leading
        label "text" do(..)
            line_height tight
            text_align leading
            caption "hello"
        end
    end
end
]])
check('utility vocabulary and nested variants', prefix .. [[
local C = ui.component "Utilities" do(..)
    grid do(..)
        cols(pixels 200, fr 1, auto)
        rows 2
        gap_x 2
        gap_y 4
        items stretch
        justify center
        clip on
        label "text" do(..)
            span 2
            row_span 1
            col_start 2
            mx auto
            min_w 0
            max_w md
            h full
            min_h 0
            max_h full
            square 8
            text_size lg
            text_color gray_500
            weight bold
            font mono
            line_height tight
            tracking wide
            text_align center
            truncate on
            border 2
            border_color gray_200
            rounded full
            shadow none
            opacity 50
            ring 2
            ring_color blue_500
            bg(black / 50)
            cursor pointer
            visible off
            from_md do(..)
                px 6
                hover do(..) bg blue_700 end
            end
            disabled do(..) opacity 50 end
        end
    end
end
]])
check('flex and stack vocabularies', prefix .. [[
local C = ui.component "Placement" do(..)
    column do(..)
        flex do(..)
            direction vertical
            wrap on
            button "b" do(..)
                grow 1
                shrink 0
                basis third
                align center
            end
        end
        stack do(..)
            label "overlay" do(..)
                inset 0
                layer 10
            end
        end
    end
end
]])
reject('wrong colour kind', prefix .. [[
local C = ui.component "Bad" do(..) column do(..) bg md end end
]], 'bg takes a colour; md is a size')
reject('wrong spacing kind', prefix .. [[
local C = ui.component "Bad" do(..) column do(..) p red_600 end end
]], 'p takes a pixels; red_600 is a colour')
reject('token collision', prefix .. [[local t = ui.theme { colors = { md = ui.colors.red_600 } }]], "theme token 'md' collides")
reject('instruction token collision', prefix .. [[
local component = ui.with_theme(ui.theme { colors = { bg = ui.colors.red_600 } }).component
local C = component "Bad" do(..) column do(..) end end
]], "collides with an instruction")
reject('duplicate name across containers', prefix .. [[
local C = ui.component "Bad" do(..)
    column do(..)
        label "a" do(..) end
        row do(..) button "a" do(..) end end
    end
end
]], "duplicate UI declaration 'a'")
reject('placement in wrong parent', prefix .. [[
local C = ui.component "Bad" do(..) row do(..) button "a" do(..) span 2 end end end
]], 'span on button is not valid in row')
reject('unknown name keeps ordinary resolution', prefix .. [[
local C = ui.component "Bad" do(..) row do(..) buton "a" do(..) end end end
]], 'UI vocabulary in Bad/row')
reject('missing size in relevant scale', prefix .. [[
local C = ui.component "Bad" do(..) row do(..) label "a" do(..) text_size md end end end
]], "text_size: no size 'md' in its scale")
check('variant getters fold known state and preserve declaration order', prefix .. [[
local C = ui.component "Variants" do(..)
    column do(..)
        button "b" do(..)
            bg red_600
            hover do(..) bg red_700 end
            from_md do(..) hover do(..) bg blue_700 end end
            disabled do(..) opacity 50 end
        end
    end
end
local node = ui.description(C).nodes[2]
local background, opacity = ui.property(node, "background"), ui.property(node, "opacity")
local result = do(): U32
    local c = ui.new C
    c.b.hovered = true
    local narrow = background(c.b, 640)
    local wide = background(c.b, 800)
    return U32 narrow.r + U32 wide.r + U32(opacity(c.b, 800))
end
export result
]], 'return 314u;')
check('window owns ordinary declared fields', prefix .. [[
local W = ui.window "StatefulWindow" do(..)
    fields { revision = U32 9 }
    label "title" do(..) caption "State" end
end
local result = do(): U32
    local window = ui.new W
    return window.revision
end
export result
]], 'return 9u;')
print(('UI builders: %d checks passed'):format(count))
