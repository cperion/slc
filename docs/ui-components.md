# UI components: a fixed tree, events as values

**Status: proposed library API, second version.** The UI builders, controls and hosts
below are not implemented. No language syntax is added: builders are Lua functions
that construct ordinary SLC types, words and sums. The general evaluator change for
field-wise loop state is present in the checkout; its scope and the evidence are
recorded in §12.

**The primary declaration form is instructions inside `do(..)` blocks.** The
block receives and anonymously opens its construction receiver. Tables remain for
property bundles, styles, native values and sum matches—not lists of UI children.

A component is a persistent record with methods and a declared tree. Content,
style, layout and behavior belong to the same component. The tree is known while
compiling, so its layout, routing and drawing specialize for it. A normalized input
produces at most one leaf report. Each component on its ownership path handles an
event value with an exhaustive match and returns its declared outcome to its parent.
A component that returns `Unit` ends the chain. No callbacks are stored.

Every property is a field. Binding time is the evaluator's responsibility, not an
annotation the UI author must supply. Known fields can fold into generated code;
mutation, ownership and materialization retain their ordinary SLC rules.

## 1. What changes from the first version, and why

| First version | This version | Why |
|---|---|---|
| Root `interact` walks controls and discards unconsumed outcomes | Route to one control and deliver events along its known ownership path | An unwired button is an unhandled sum alternative, not a silently lost click |
| Components report through trailing continuation blocks | Components return declared outcome sums | The body returns an outcome; the enclosing activity matches it |
| Parent checks modal visibility while consuming outcomes | Host applies modal scope before delivery | Application code does not re-derive the routing decision |
| Layout containers add field-path levels | Only component boundaries add levels | Moving a button between rows does not change application code |
| A type declares its placement name | Names are given at the use site | A type does not know where it will be used |
| Nested tables enumerate UI children | Instructions declare children inside anonymous-open blocks | Construction scope is explicit without receiver names or prefixes |
| Property storage is assumed to be dynamic | Ordinary field-wise specialization determines storage | Unchanged style need not become runtime loads |
| Logic is exercised through the host | Call `component:handle(event)` directly | Logic needs no window and can fold over known inputs |

The application remains a component. `ui.run` is the resource-owning activity that
constructs and drives it; it is not a second application/controller object.

## 2. A complete application

This is the target library API, not an example that can run against the current
checkout. A modal starts closed unless its declaration specifies `visible true`.

```lua
local ui = require "slc.ui"
local component, window = ui.component, ui.window
local theme = ui.theme

local Confirmation = component "Confirmation" do(..)
    outcome oneof { reset: Unit, keep: Unit }

    modal { width = 320, padding = 16, gap = 12, style = theme.panel } do(..)
        label "question" { text = "Reset the counter?" }

        row { gap = 8 } do(..)
            button "reset_button" { text = "Reset", style = theme.accent }
            button "keep_button" { text = "Keep value" }
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

local Counter = component "Counter" do(..)
    column { padding = 24, gap = 12 } do(..)
        number "count" { value = U32 0, font_size = 40 }

        row { gap = 8 } do(..)
            button "increment_button" { text = "Increase" }
            button "reset_button" { text = "Reset…" }
        end

        part "confirm" (Confirmation)
    end
end

function Counter:increment(): Unit
    if self.count.value < 999999 then
        self.count.value = self.count.value + 1
    end
    self.increment_button.enabled = self.count.value < 999999
end

function Counter:reset(): Unit
    self.count.value = 0
    self.increment_button.enabled = true
end

function Counter:handle(event: Counter.Event): Unit
    event {
        increment_button = do() self:increment() end,
        reset_button = do() self.confirm:open() end,
        confirm = do(decision)
            decision {
                reset = do() self:reset() end,
                keep = do() end,
            }
        end,
    }
end

local App = window "SLC counter" { width = 640, height = 480, style = theme.window } do(..)
    part "counter" (Counter)
end

function App:handle(event: App.Event): ui.Reply
    return event { close_requested() = ui.Reply.quit() }
end

local main = do(): I32
    local result = ui.run App
    return result {
        quit() = I32 0,
        failed(failure) = I32 1,
    }
end
export main
```

Reading it:

- `Counter.Event` is generated as
  `oneof { increment_button: Unit, reset_button: Unit, confirm: Confirmation.Outcome }`.
  The `row` adds no level: the control is `self.increment_button` and its event
  alternative is `Counter.Event.increment_button`.
- `Counter` declares no outcome, so it contributes no alternative to `App.Event`.
  Its handlers still run; they simply finish without notifying the parent.
- Adding a button adds an event alternative. The exhaustive handler must account
  for it, even when the intended action is explicitly nothing.
- The confirmation closes itself and returns one decision. The parent does not
  check its visibility. While open, the host routes user input inside its scope.
- The count is the persistent numeric content of the control, not a rendered copy
  of another counter model. Its methods can change content, style and layout in
  the same transition.

Name controls for their role (`increment_button`, `reset_button`) and methods for
what they do (`increment`, `reset`). This avoids unnecessary competition for names;
SLC still rejects any remaining field/method collision. The final result is bound
before matching:
`ui.run App { ... }` would associate the table with `App` under the ordinary
[application rules](syntax.md#24-application).

## 3. Declaring a component

### 3.1 Builders, names and layout

| Builder or instruction | Meaning |
|---|---|
| `component "Name" do(..) ... end` | Declare a component record type, its event/outcome types and generated words |
| `window "Title" { ... } do(..) ... end` | Declare a window root with its properties and child declarations |
| `column { ... } do(..) ... end`, `row { ... } do(..) ... end`, `modal { ... } do(..) ... end` | Declare a layout container with properties and child declarations; do not create a control-name scope |
| `label "name" { ... }`, `number "name" { ... }`, `button "name" { ... }` | Declare a named control with a property bundle |
| `part "name" (T)` | Declare a named child component of type `T` |
| `part "name" (ui.List(T))` | Declare a collection of child components, subject to §6 |
| `outcome oneof { ... }` | Declare the owning component's outward sum |
| `fields { revision = U64 0, phase = Phase.editing() }` | Declare ordinary native fields with their initial values; no separate state dictionary |

**Tables supply properties; blocks contain declarations.** There are no property
setter instructions such as `gap 8`. Use `row { gap = 8 } do(..) ... end`.
`outcome` and `fields` remain instructions because they declare a type and fields.
An empty property table may be omitted; this does not enable setter instructions.

Instructions declare children in execution order. Each block receives a receiver
and opens it with [anonymous spread](syntax.md#anonymous-spread). Bare calls resolve
against the innermost receiver that supplies the method. No construction-scope name
or repeated receiver prefix is needed.

These receivers expose **methods**, not repeated keys in opened Lua vocabulary
tables. Methods stay attached under [the opening rules](syntax.md#105-opening), so
nested declaration calls select the inner receiver without introducing shadowing names.
Receiver bookkeeping should avoid unintentionally hiding user bindings with opened
fields. The library follows ordinary lexical shadowing; it has no special lookup rules.

An unresolved declaration call must identify the current construction scope and
list its available declarations, for example:

```text
'buton' is not a declaration in a row
available: label, number, button, part, row, column
```

Preserve ordinary lexical helpers and valid enclosing-receiver calls. Emit this
contextual diagnostic only after normal name resolution fails; do not intercept
all Lua globals or invent UI-specific lookup semantics. Unknown property names in
a bundle, such as `gapp`, must similarly name the owning container and valid
properties. If existing diagnostic facilities cannot expose this information, the
implementation must identify the smallest general diagnostic hook needed. These
are required builder diagnostics, not claims of an already implemented hook.

Construction blocks run while declaring the type, not once per frame or input.
They can use locals and helpers; any branches or loops that determine the tree must
resolve during construction. A runtime collection is still explicit `ui.List(T)`.
Each scope appends declarations to its own parent tree and completes on return.
The result is the known tree and native type—not a retained construction callback,
a global current-builder variable, or an `interface` argument on application methods.

Tables remain data: control property bundles, reusable styles, native initializers,
`oneof` declarations and event matches. They do not enumerate UI children. This is
one authoring surface, not two parallel tree APIs. Grouping parentheses remain where
ordinary SLC grammar requires them, such as `part "confirm" (Confirmation)`.

A visual component has one root layout container; a nonvisual component can have
none. A window supplies its root layout. Multiple visual children of a window use
vertical flow by default. Control and part names are unique across all containers
of their owning component. Duplicates, reserved-name conflicts, and field/method
conflicts are errors that identify the declarations. Named child components start
a new namespace; layout containers do not.

**Addressing container properties:** the root container's public properties belong
to the component, so `self.gap` means its root gap. A container can optionally be
named, for example `row "actions" { gap = 8 } do(..) ... end`, to expose `self.actions.gap`.
Its controls remain directly named fields of the component, not fields under
`actions`. Anonymous nested containers have internal property storage and no public
field name; name one when application code needs to address its properties. This
names a layout object without making it a control-name scope.

The builders use Lua for type construction and known tree composition. Layout,
routing, drawing and control algorithms are ordinary SLC words, specialized with
the program. Generated words are not an excuse to put those algorithms in opaque
Lua or C helpers.

### 3.2 Properties and binding time

Properties have their declared values as initial values. Application code can
assign them directly: `self.increment_button.enabled = false`, `self.gap = 20`.
The author does not classify properties as static or dynamic.

For an ordinary tracked record in a loop, fields whose values agree across rounds
can remain known while changed fields become storage. Known style and geometry
then become constants in specialized layout and drawing. This general language
support is present in [the evaluator](../slc/stage.lua), described in
[syntax §6](syntax.md#6-loops-are-tail-recursion), and exercised by
[the loop-field examples](../examples/loop_fields.slc).

This is not a guarantee that every unwritten property disappears from every
program. Address escape, function/foreign boundaries and ownership can require
materialization. Resizable owners, atomic storage and scoped views retain their
contracts. A field that changes only on a loop exit also participates in agreement.
The UI library must preserve these rules rather than introduce special UI storage
semantics. No zero-byte claim is made for an enclosing C aggregate merely because
some of its field reads folded.

### 3.3 Style

A style is a Lua table of property defaults. `style = theme.accent` in a control
or container's property bundle supplies its defaults. Explicit properties in that
bundle override the style. This is the same rule for controls and containers;
there is no style instruction, selector, cascade engine or independent style tree.

Theme tables are known descriptions. Their resulting properties are ordinary
fields. Runtime theme changes use typed native palette/property values assigned by
handlers, not a Lua table retained in native storage.

### 3.4 Text

Mutable text is owned and bounded in the first version:
`label "title" { capacity = 64 }` and `text_entry "name" { capacity = 64 }` have
`Chars 64` storage. A literal initializer must fit the declared capacity. When a declaration supplies
only a literal, its size determines the default capacity; specify a larger capacity
when subsequent content needs it. This is a storage bound, not a static/dynamic
annotation. The compiler can fold known text and its uses where ordinary
binding-time rules permit it. A borrowed `Str` is never stored in a component.

## 4. Events and outcomes

### 4.1 The event of a component

The builder generates `T.Event` from the things in the tree that report:

| Tree declaration | Event contribution |
|---|---|
| `button "name" { ... }` | `name: Unit` on activation |
| `checkbox`, `slider`, `text_entry` without `report` | None; the control updates its own content |
| A control with `report = { "changed" }` or `{ "submitted" }` | Its named, typed report under the control's name |
| `part "name" (C)` with a declared outcome | `name: C.Outcome` |
| `part "name" (C)` without an outcome | None |
| `part "name" (ui.List(C))`, with a declared child outcome | `name: { id: Id C, outcome: C.Outcome }` |
| A job part | Its completion result under the part's name |
| A window | `close_requested: Unit`, plus explicitly requested window reports |

A control defines the payloads of its reports. With one requested report, that
payload is used directly; with several, a sum distinguishes the requested reports.
For example, a checkbox's `changed` payload is `Bool`. Control mutation happens
before its report reaches the owner. A control that can both change and submit on
one input must define one combined/submitted report for that input, not secretly
deliver two sibling events.

A component with event alternatives must define `handle`. A component with none
must not; there is no public empty `Event` sum to construct. Check these contracts
when the component is used as a part or host root, after its methods can be defined.
Diagnostics list the alternatives. Exhaustiveness remains the language's ordinary
sum-matching rule.

### 4.2 Outcomes

`outcome oneof { ... }` declares `T.Outcome`; its `handle` returns that type.
Without a declared outcome, `handle` returns `Unit` and ends delivery to parents.

A component that sometimes reports nothing says so explicitly, for example
`oneof { nothing: Unit, chose: Color }`. `nothing` is still a real outcome that the
parent must match. It is not silently filtered out. An explicit empty arm documents
that an event is intentionally ignored.

The window root returns `ui.Reply = oneof { stay: Unit, quit: Unit }`. Only `quit`
requests normal completion of the activity. An event handled by a descendant that
returns `Unit` implicitly leaves the window running; it need not call the root.

### 4.3 One input, one report, one ownership chain

For each normalized input, the host:

1. Ensures current layout before geometric routing.
2. Routes to one eligible control, applying clipping, modal scope, focus and capture.
3. Advances that control's input machine. A press persists in the control; an
   eligible matching release can report activation.
4. Delivers the report as the owning component's event and calls its `handle`.
5. If the handler returns an outcome, delivers that value as its parent's event,
   continuing until a handler returns `Unit` or the root returns a reply.
6. After the delivery chain unwinds, completes requested focus, capture and
   participation changes, updates layout, and draws when a frame is due.

There may be several event values along this chain, but at most one originating
report for the normalized input. There is no per-widget mailbox, no application
walk that polls all children, and no discarded unwired activation. A press or
hover change need not produce an application event at all.

A handler may change anything its component owns, including hiding the clicked
control. The input has already been routed; it is not delivered again to an
uncovered control. Layout and painting do not call application handlers. There is
no recursive pumping of platform events during a handler.

Child handling returns before parent handling begins. Generated routing must not
retain or reuse an item borrow after invoking a parent that may remove that item.
Structural retirement that still has outstanding borrows or external users must
wait for those uses to end. Visibility alone does not destroy an owned component.

### 4.4 Specialization, not a universal zero-cost promise

For a fixed tree, routing ends at a known control with a known owner chain. The
builder composes that chain from ordinary SLC words. At a selected leaf, the event
tag is known; matching it can specialize to the relevant arm without constructing
an event aggregate at runtime.

For the counter, the intended residual route for Increase is its hit test followed
by `increment`. Confirmation decisions can specialize in the same way.
Verify this against generated C as an acceptance check, not as a backend-inlining
assumption.

Dynamic information remains dynamic. Checkbox values, text reports, collection IDs
and job results can carry runtime payloads. A handler can also choose an outcome
tag based on runtime state, requiring a subsequent match. Known outer tags may
still disappear. The claim is that known event structure specializes away, not that
all events, outcomes, payloads or dispatch costs disappear in every program.

## 5. Focus, keyboard, modals and layout

- Focus order is declaration order among visible, enabled, focusable controls in
  the current scope. Tab and Shift+Tab traverse that order.
- A shortcut is a known property, such as `key = "ctrl+s"`. Generate routing for its
  scope; duplicate shortcuts in one scope are compile-time errors.
- A modal is an overlay and input scope. While open, user input is restricted to
  it; focus starts at its first eligible control. Job completions are not user
  input and remain deliverable to their owning operations.
- On closing, restore the opener's focus if still eligible, otherwise the first
  eligible control of the parent scope, or no focus if none exists.
- Components whose root is declared with `modal` have `open` and `close` methods and a
  `visible` property. They start closed by default. Later-declared open sibling
  modals are above earlier ones.
- Pointer/key gestures record their initiating identity and participation
  generation. Disable, hide, capture loss or relevant focus loss cancels them.
  Reopening a component cannot complete an old press. Key repeat does not create
  extra button activations unless explicitly part of that control's contract.

Rows and columns arrange visible children in declaration order with gaps and
padding. Content determines default size; explicit dimensions constrain it.
Overflow is clipped. Modals are centered overlays, not normal-flow slots. Initial
scope excludes automatic wrapping, flexible sizing and scrolling; these are later
layout features, not prerequisites for the event model.

## 6. Collections

A fixed component shape can contain a dynamic collection of instances:

```lua
local TodoRow = component "TodoRow" do(..)
    outcome oneof { toggled: Bool, removed: Unit }

    row { gap = 8 } do(..)
        checkbox "done" { report = { "changed" } }
        label "title" { capacity = 64 }
        button "remove" { text = "×" }
    end
end

function TodoRow:handle(event: TodoRow.Event): TodoRow.Outcome
    return event {
        done(checked) = TodoRow.Outcome.toggled checked,
        remove() = TodoRow.Outcome.removed(),
    }
end

local Todos = component "Todos" do(..)
    column { gap = 4 } do(..)
        part "rows" (ui.List(TodoRow))
    end
end

function Todos:handle(event: Todos.Event): Unit
    event {
        rows = do(row_event)
            row_event.outcome {
                toggled = do(checked)
                    -- The checkbox already owns its new value.
                    -- This parent deliberately needs no additional effect.
                end,
                removed = do() self.rows:remove row_event.id end,
            }
        end,
    }
end
```

`ui.List(C)` uses `Store C` for owned item slots and generational identity.
`self.rows:add(C { ... })` accepts a fully initialized copyable item and returns
`Id C`; `self.rows[id]` yields a checked place. IDs are not owners or stable indexes.
A stale ID must not name a replacement item. The host rejects stale external targets
before delivery; explicit invalid application lookups retain normal store checks.

List events carry both the item ID and its outcome. Routing stops after delivering
one item; it must not continue through an invalidated iterator or dereference the
item after its parent removes it.

### Storage and ordering boundaries

The [current ownership contract](syntax.md#92-resizable-values) permits one resizable
field per struct, in final position. A component containing one is created in place,
used through `Ref`, and cannot be copied or returned as an ordinary value. Physical
field order can differ from layout order, so the builder can put a single list last
without moving it visually.

This does **not** make arbitrary multiple or nested growing lists representable.
The first list implementation must enforce the existing ownership restrictions and
reject unsupported shapes explicitly. General multi-list ownership is a separate
storage design, not an implicit heap fallback or an assumed evaluator capability.
A resizable component's initialization must construct it in its owner's place;
`T.new()` must not mean a native word returning a resizable value.

A store supplies identity, not the desired display-order contract. Before the list
milestone, specify whether order follows store slots or an explicit ordered sequence
of IDs, including what removal and insertion do to order. The API must not promise
insertion ordering merely by calling the storage a list. Layout, drawing and routing
iterate the same declared order.

Resizable stores are runtime-only under current SLC semantics. Compile-time replay
claims for fixed records do not extend to store-backed lists. Their logic can still
be tested headlessly at runtime.

## 7. Work that finishes later

A job is a part whose event is its completion:

```lua
part "save" (ui.Job(write_file))
-- write_file(snapshot: Snapshot): SaveResult runs as a task.
```

`self.save:start(snapshot)` starts work with an independently owned payload and a
fresh request generation. For the initial API, the payload must satisfy the task
contract and be copyable into task-owned storage; a borrowed view or reference to
UI state is not an owned snapshot. Noncopyable payload transfer needs an explicit
supported ownership contract, not an implicit copy.

The result is delivered as `save: SaveResult` through the same owner chain as a
click, on the window's thread. The host checks the live owner and request generation
before delivery. Results from superseded requests are discarded for business state,
with their resources still released. `self.save.running` exposes the current
operation state; clear it for the matching completion before invoking its handler.

A worker completion wakes the window loop through a thread-safe platform mechanism
such as an SDL user event. The window takes completions at turn boundaries. SDL
video, input and drawing stay on their owning thread. The scheduler-to-window bridge
must establish this explicitly; task scheduling alone is not proof of thread affinity.

Cancellation stops interest in an outcome; it does not roll back external effects.
The host must retain an owner for task resources until completion or acknowledged
cancellation. Shutdown must drain or safely cancel outstanding work before releasing
resources still in use. No implicit fire-and-forget detachment is part of this API.

## 8. Drawing a custom control

A custom leaf is a record with size, paint and optional input methods. Define the
type before attaching its methods so its name is in scope:

```lua
local Swatch = ui.widget "Swatch" do(..)
    fields { color = ui.colors.black }
end

function Swatch:size(limits: ui.Limits): ui.Size
    local requested = ui.Size { width = 24, height = 24 }
    return limits:clamp requested
end

function Swatch:paint(canvas: Ref ui.Canvas): Unit
    canvas:fill(canvas.bounds, self.color)
end
```

For an interactive widget, declare its outcome sum and define an input method that
updates its own record and returns a typed report: either no report or one declared
outcome. The widget's generated report type distinguishes these cases. Application
`handle` is not called by painting. The canvas parameter belongs at this leaf's
actual drawing boundary, not on every application component method.

Library controls must use the same public widget mechanism rather than retain a
privileged second implementation. The layout and drawing algorithms invoke these
ordinary SLC methods in place.

## 9. What the builders generate

| Generated for `T` | Contract |
|---|---|
| Native record `T` | Owned controls/parts, application fields, layout properties and required interaction bookkeeping |
| `T.Event` | Sum of reporting alternatives, when nonempty |
| `T.Outcome` | The explicitly declared outward outcome, when present |
| Default initialization | `T.new()` for fixed records; in-place construction for resizable owners |
| `T.measure`, `T.arrange` | Layout specialized over the known tree and current properties |
| `T.draw` | Painting in declaration order, overlays last |
| `T.route` | Input routing ending in the known chain of `handle` calls |

Lua supplies schema construction and composes known words. Expressible algorithms
remain SLC, so they can fold, specialize and residualize with the application.
C is limited to necessary platform/runtime mechanisms.

`ui.run` is an activity: construct the root once, open resources, process turns,
draw, and close resources on quit or failure. Its result is
`oneof { quit: Unit, failed: Failure }` with an owned diagnostic. It handles resource
cleanup, not application close policy. An ordinary window close request is an input
for the root to interpret.

The existing [SDL resource activities](../lib/sdl.slc) are the platform foundation.
The [canvas convenience layer](../lib/canvas.slc) currently stops on close and lacks
the full UI input vocabulary. Preserve that contract; build the UI host over the
lower layer rather than silently changing canvas behavior. Real text metrics and
rendering need a font capability; do not substitute an undocumented fallback.

## 10. Testing

Application logic is methods and event values, independent of a window:

```lua
local counted = do(): U32
    local counter = Counter.new()
    counter:handle(Counter.Event.increment_button())
    counter:handle(Counter.Event.increment_button())
    counter:handle(Counter.Event.confirm(Confirmation.Outcome.reset()))
    return counter.count.value
end
assert(host(counted()) == 0)
```

This tests handler behavior, not whether a hidden dialog could receive a click.
Routing, focus, geometry and modal eligibility are separate host tests.

`ui.replay(App, inputs)` is a headless host using the same initialization, routing
and handler paths as `ui.run`, with explicit synthetic input and deterministic
layout/text metrics supplied by the test. It returns the fixed root's state for
inspection. Symbolic inputs such as `ui.click "counter.increment_button"` resolve known
field paths in the test API; they are not production styling selectors. A simulated
click must follow routing/eligibility rules rather than call a handler directly.

Known fixed-tree input sequences and pure test capabilities can fold into compile-time
assertions. External I/O, runtime-only storage and dynamic input require runtime
tests. Replay must not claim that a real task, platform renderer or store was evaluated
at compile time. Resizable roots must be inspected while their owner scope is alive,
not returned by value from replay.

## 11. Implementation plan and acceptance

These are coherent feature milestones, not another series of standalone probes.

| Step | Deliverable | Acceptance |
|---|---|---|
| 0 | General field-wise loop state | Implementation and examples are present; retain ordinary ownership/materialization rules and regression coverage |
| 1 | Anonymous-open construction scopes; `component`, `column`, `row`, `label`, `number`, `button`; generated events and handler checks; headless replay host | Counter without modal works; nested method scopes obey opening rules; missing event arm is rejected; two instances are independent; routed-click C specializes the known event chain; unchanged tracked properties become constants |
| 2 | `ui.run` over SDL, input normalization and real font metrics/rendering | Counter runs in a window, handles resize, draws text and cleans up on quit/failure |
| 3 | Modal scope, focus, keyboard and shortcuts | Full §2 application works; focus returns correctly; no click-through or activation after a cancelled press; duplicate shortcuts are rejected |
| 4 | Store-backed lists, Checkbox and bounded TextEntry | Resolve ordering and enforce supported storage shapes; to-do interactions work; stale IDs cannot select replacements; parent removal does not leave live child borrows |
| 5 | Jobs and the scheduler/window bridge | Retriable save; stale completion rejected; payload ownership and shutdown accounted for; SDL thread affinity verified |
| 6 | Public widget extension mechanism | Custom leaf works and built-in controls use the same methods/contracts |

The early control implementation must already factor size/paint/input into ordinary
SLC methods so step 6 exposes the common mechanism rather than rewriting a private
control engine. Dynamic lists, editable text, jobs and custom widgets are later
scope, not implied capabilities of the first window milestone.

## 12. Evidence and remaining decisions

**Observed in the checkout:** field-wise loop generalization exists in
[the evaluator](../slc/stage.lua), with [example coverage](../examples/loop_fields.slc)
and the updated [language specification](syntax.md). This document revision does
not claim a fresh execution of those tests.

**Reported evidence from the supplied design:** a hand-generated counter reportedly
specializes Increase to a hit test and increment, and confirmation choices to a hit
test and reset/no-op, with only changing fields participating in runtime state.
That generated-counter source and C were not located during this review. Preserve
the report as evidence to inspect, not as a newly reproduced acceptance result.
The builder implementation must meet the corresponding step-1 acceptance checks.

**Remaining design work before the affected milestones:**

- Ordered-list storage and supported combinations of resizable component owners.
- The concrete task-completion bridge and shutdown/cancellation ownership protocol.
- The platform font capability and its metrics/rendering contract.

These do not reopen the core model: a declared tree of persistent records with
methods; generated event sums; exhaustive handlers; outcomes delivered up the known
ownership chain. No stored callbacks, per-widget mailboxes, interface argument,
selector engine or parallel application model is needed.
