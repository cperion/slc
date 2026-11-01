# UI components: a fixed tree, events as values

**Status: partially implemented library, with remaining target contracts below.**
The instruction builders, native records, generated event sums, basic row/column
layout, pointer routing, modal outcomes and an SDL3/SDL_ttf counter now exist.
See [the runnable counter](../examples/ui/README.md) for observed checks and limits.
The rest of this document remains the design target, not a claim that every control,
layout utility or host capability is complete. The current authoring contract is
[Tailwind-granular instructions](ui-style.md).

**The primary declaration form is instructions inside `do(..)` blocks.** The
block receives and anonymously opens its construction vocabulary. Instructions set
properties and declare children. Tables remain for theme scales, native values and
sum matches—not control property bundles or lists of UI children.

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

The executable application is [the component counter](../examples/ui/counter.slc),
with [the SDL entry point](../examples/ui/main.slc) and
[the replay entry point](../examples/ui_counter.slc). A modal starts closed unless
its block contains `visible on`.

```lua
local Confirmation = ui.component "Confirmation" do(..)
    outcome oneof { reset: Unit, keep: Unit }
    modal do(..)
        w 80
        p 4
        gap 3
        bg white
        label "question" do(..) caption "Reset the counter?" end
        row do(..)
            gap 2
            button "reset_button" do(..) caption "Reset" end
            button "keep_button" do(..) caption "Keep value" end
        end
    end
end
```

Handlers remain methods on the component records. The runnable counter specifies
explicit control dimensions; the SDL host also supplies real text measurement.
Its font path is explicit, not an implicit replacement font.

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
| `component "Name" do(..) ... end` | Declare a component record and its generated event sum |
| `window "Title" do(..) ... end` | Declare the root and set its properties inside the block |
| `column do(..) ... end`, `row do(..) ... end`, `modal do(..) ... end` | Declare a layout container without adding a control-name scope |
| `label "name" do(..) ... end`, `number "name" do(..) ... end`, `button "name" do(..) ... end` | Declare a named control; instructions set its properties |
| `part "name" (T)` | Declare a child component |
| `outcome oneof { ... }` | Declare the owning component's outward sum |
| `fields { revision = U64 0 }` | Declare ordinary native fields with initial values |

**Each block opens a Lua vocabulary table.** Its applicable instructions and the
bound theme's typed tokens become bindings under ordinary lexical shadowing.
A name absent from that vocabulary falls through to enclosing scopes. A helper
declared later inside the block shadows an opened binding in turn. For example,
`outcome` inside a modal reaches the component, and `gap` inside a button can reach
its enclosing row. No UI-specific lookup or environment interception is used.

Unknown names must preserve normal resolution before receiving UI diagnostics.
The current builder adds the available instructions and scope to an unresolved-name
error; nearest-name suggestions are still pending. Wrong token kinds, duplicate
names and invalid child placement report construction errors.

Construction blocks run while declaring the type, not once per frame or input.
They can use locals and helpers; any branches or loops that determine the tree must
resolve during construction. A runtime collection is still explicit `ui.List(T)`.
Each scope appends declarations to its own parent tree and completes on return.
The result is the known tree and native type—not a retained construction callback,
a global current-builder variable, or an `interface` argument on application methods.

Tables remain data: theme scales, native initializers, `oneof` declarations and
event matches. Shared styles are `ui.style do(..) ... end` blocks. They do not enumerate UI children. This is
one authoring surface, not two parallel tree APIs. Grouping parentheses remain where
ordinary SLC grammar requires them, such as `part "confirm" (Confirmation)`.

A visual component has one root layout container; a nonvisual component can have
none. A window supplies its root layout. Multiple visual children of a window use
vertical flow by default. Control and part names are unique across all containers
of their owning component. Duplicates, reserved-name conflicts, and field/method
conflicts are errors that identify the declarations. Named child components start
a new namespace; layout containers do not.

**Addressing container properties:** the root container's public properties belong
to the component, so `self.gap_x` means its root horizontal gap. A container can optionally be
named, for example `row "actions" do(..) gap 2 ... end`, to expose `self.actions.gap_x`.
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
assign them directly: `self.increment_button.enabled = false`, `self.gap_x = 20`.
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

A style is an instruction block: `ui.style do(..) ... end`, applied with
`use primary`. One instruction corresponds to one utility: `px 4`, `rounded md`,
`bg red_600`, `text_size lg`, `line_height tight`. Instructions run in order and
later assignments win. `leading` and `trailing` are alignment tokens only.
See [the style contract](ui-style.md) for scales, tokens and variants.

Properties become ordinary native fields. Runtime style changes assign those
fields, for example `self.reset_button.background = ui.colors.red_700`.
Interaction and breakpoint blocks record overrides; generated property getters
select them from interaction fields and window width. Layout and drawing must use
the same resolved properties.

### 3.4 Text

The current label/button caption is owned `Chars 256` storage; construction rejects
longer UTF-8 byte strings. It is not a borrowed `Str`. Configurable capacities and
editable text controls remain future work. Number controls store their native
integer value, initialized by `value U32 0` (or another integer width).

## 4. Events and outcomes

### 4.1 The event of a component

The builder generates `T.Event` from the things in the tree that report:

| Tree declaration | Event contribution |
|---|---|
| `button "name" do(..) ... end` | `name: Unit` on activation |
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

Layout uses two passes of ordinary SLC words over the known tree: measure content
and constraints, then arrange according to the container's rules. Known properties
and dimensions can fold to constant positions; mutable dimensions and resizable
windows leave native arithmetic, not a layout interpreter. The target includes
row, column, flex, grid, stack and modal; children set their own placement through
instructions. Modals are centered overlays, not normal-flow slots. Full wrapping,
flex sizing, grid tracks and clipping remain incomplete in the current library;
see [the implementation boundary](ui-style.md#implementation-boundary).

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
