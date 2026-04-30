# Terminal Custom Effect

`src/Compiler/REPL.hs` defines a custom `Terminal` effect handle that isolates REPL interaction from any specific UI backend.

```haskell
data Terminal es = MkTerminal
  { prompt :: Text -> Eff es (Maybe Text)
  , output :: Text -> Eff es ()
  } deriving (Generic)
```

## Purpose

The `Terminal` handle abstracts two operations needed by the REPL loop:

1. Prompt for input.
2. Emit output.

Because these operations are encoded as `Eff es` actions, the REPL logic can remain effect-polymorphic and independent from concrete IO strategy.

## Core mechanics

### 1) Effect-polymorphic interface

The type parameter `es` is the active Bluefin effect stack. `Terminal es` stores functions that run inside `Eff es`, so the same REPL loop can execute with different interpreters.

### 2) Exit signaling with `Maybe Text`

`prompt` returns `Maybe Text`:

- `Just input` means continue the loop with user input.
- `Nothing` means terminate gracefully after a frontend shutdown signal or other interpreter-specific close condition.

### 3) REPL loop depends only on Terminal

`replLoop` is typed as:

```haskell
replLoop :: Terminal es -> Eff es ()
```

That signature is the architectural boundary. The loop knows nothing about stdin/stdout, `brick`, or any other frontend API. It only consumes `prompt` and `output`.

## Active executable wiring

The current executable starts the Brick UI on the main thread and runs the REPL loop in a background thread. `app/Main.hs` wires startup like this conceptually:

```haskell
main :: IO ()
main = do
  eventChan <- newBChan 10
  inputMVar <- newEmptyMVar

  _ <- forkIO $ runEff \io -> do
    let term = runTerminalBrick eventChan inputMVar io
    replLoop term
    effIO io $ writeBChan eventChan TUIQuit

  runTUI eventChan inputMVar
```

That means the user-facing path today is the Brick-backed interpreter, not the plain stdin/stdout one.

## Alternate interpreter: IO-backed terminal

`runTerminalIO` builds a concrete `Terminal` using Bluefin IO capabilities:

```haskell
runTerminalIO :: forall io es. (io :> es) => IOE io -> Terminal es
```

Implementation behavior:

- `prompt` prints the prompt text.
- Flushes stdout to ensure prompt visibility before blocking.
- Reads one line from standard input.
- Wraps the line as `Just input`.
- `output` writes a line to standard output.

This interpreter remains useful as a minimal backend, but it is not the one currently launched by `lithic-cli`.

## Brick-backed interpreter

The repository now also has a Brick-backed interpreter in `runTerminalBrick`. It keeps the same `Terminal es` interface, but instead of reading from stdin and writing to stdout directly, it communicates with the UI thread through two concurrency primitives:

- `BChan TUIEvent` for one-way messages from the REPL thread into Brick.
- `MVar (Maybe Text)` for handing submitted user input from Brick back to the REPL thread.

Conceptually, the Brick backend works like this:

1. `prompt` writes `TUIPrompt p` to the Brick event channel.
2. The REPL thread blocks on `takeMVar inputMVar`.
3. Brick updates the on-screen prompt when it receives `TUIPrompt`.
4. When the user presses Enter, Brick extracts the editor contents and attempts to write `Just content` into the `MVar`.
5. The blocked REPL thread wakes up, receives the submitted text, and continues through `replLoop`.
6. Any REPL output is sent back to the UI as `TUIOutput msg` through the event channel.

That round-trip is what allows the REPL logic to stay frontend-agnostic while still supporting an interactive TUI.

## What `MVar` is

`MVar` is a synchronization primitive from Haskell's concurrency library. You can think of it as a mutable box with exactly two states:

- empty
- full

Unlike a plain mutable variable, an `MVar` is designed for safe coordination between threads. The REPL side uses:

```haskell
takeMVar :: MVar a -> IO a
```

The Brick side currently uses:

```haskell
tryPutMVar :: MVar a -> a -> IO Bool
```

Their behavior here is:

- `takeMVar` removes and returns the value if the `MVar` is full.
- `takeMVar` blocks if the `MVar` is empty.
- `tryPutMVar` stores a value if the `MVar` is empty.
- `tryPutMVar` returns `False` immediately if the `MVar` is already full.

That combination is useful for this handoff. The REPL thread can wait for the next response, while the UI thread can avoid blocking if it tries to submit while a previous response is still pending.

## What `BChan` is

`BChan` is Brick's bounded event channel. It is used to send custom application events into the Brick event loop from outside the UI thread.

In this project, the custom event type is `TUIEvent`, and values such as `TUIPrompt`, `TUIOutput`, and `TUIQuit` are written into the channel for Brick to process.

You can think of `BChan` as a queued mailbox for UI-facing events:

- one thread writes events into it
- Brick receives those events as `AppEvent ...` inside `handleEvent`

Unlike `MVar`, which is a single-slot synchronization cell, `BChan` is a channel intended for event delivery.

That makes it a better fit for messages such as:

- "update the visible prompt"
- "append this line to the log"
- "shut down the UI"

Those are not request-response handoffs. They are discrete events the UI should consume in order.

## Why `MVar` is used in this TUI REPL

In the Brick REPL, there are two cooperating threads:

- the REPL thread, which runs `replLoop`
- the Brick UI thread, which owns the event loop and text editor widget

The REPL thread needs a way to say "I am ready for the next line of input" and then wait until the UI has that line. `MVar (Maybe Text)` is the handoff point for exactly that.

The responsibilities are split like this:

- `BChan TUIEvent` carries prompt and output events into the UI.
- `MVar (Maybe Text)` carries submitted input back from the UI to the REPL.

That separation is deliberate.

- `BChan` is a good fit for queued UI events that Brick should handle in order.
- `MVar` is a good fit for a single pending request-response handoff where one side waits for exactly one answer.

So the design is directional:

- REPL thread to UI thread: use `BChan`
- UI thread to REPL thread: use `MVar`

## How the `MVar` handoff works here

The current flow is:

1. `replLoop` asks the `Terminal` for input.
2. `runTerminalBrick` sends `TUIPrompt` to Brick.
3. `runTerminalBrick` then calls `takeMVar inputMVar` and blocks.
4. The Brick UI lets the user type in the editor.
5. When the user presses Enter, Brick extracts the text and calls `tryPutMVar inputMVar (Just content)`.
6. The blocked REPL thread wakes up immediately, receives the submitted line, and continues processing.

At the same time, output travels in the opposite direction through `BChan`:

1. The REPL produces a prompt or output message.
2. `runTerminalBrick` writes a `TUIEvent` into `BChan`.
3. Brick receives that value as `AppEvent ...` in `handleEvent`.
4. The UI updates prompt text, log lines, or shutdown state.

For shutdown, the same mechanism is reused:

- Ctrl-C in the Brick handler attempts to write `Nothing` into the `MVar`.
- The REPL interprets `Nothing` as termination.
- When the REPL exits normally, it writes `TUIQuit` into `BChan` so the UI can halt.

Using `Maybe Text` on top of `MVar` gives the handoff two meanings:

- `Just input` means a normal submitted line
- `Nothing` means end the session

## Why `MVar` fits better than direct UI access

The REPL thread does not own Brick widgets, and Brick's event loop does not directly run inside `replLoop`. That is a good separation of concerns.

If the REPL tried to read UI widget state directly, it would couple the core loop to Brick internals. By using `MVar`, the REPL only knows that input will eventually arrive, not where it came from.

Likewise, by using `BChan`, the REPL does not need direct access to Brick's UI state in order to request redraw-relevant changes. It can simply emit events and let the UI thread apply them.

This preserves the abstraction boundary:

- the REPL depends on `Terminal`
- the Brick backend handles cross-thread coordination with both `BChan` and `MVar`
- the UI remains responsible for text editing and key events

## Important `MVar` behavior to keep in mind

There is an important operational detail: `MVar` is single-slot, not an unbounded queue.

That means:

- if the REPL is waiting and the `MVar` is empty, `tryPutMVar` succeeds and wakes the REPL
- if the REPL is not waiting and the `MVar` is already full, `tryPutMVar` returns `False` and the UI thread keeps running

In this REPL, that is acceptable because the design is intentionally request-response oriented: one prompt should correspond to one submitted line. The UI should only place one response into the `MVar` for each waiting prompt, and the non-blocking write avoids freezing the event loop if a second submission races ahead.

If the design ever changes to allow multiple queued submissions or more asynchronous command traffic, a channel or queue would likely be a better fit than `MVar`.

By contrast, `BChan` is already queue-shaped, which is why it is used for prompt/output events rather than input submission.

## Why the earlier Brick bug happened

The earlier failure mode was subtle but straightforward: the Enter handler in the Brick UI was echoing the typed command into the log buffer, but it was not handing the command back to the REPL thread.

That meant:

1. The UI showed the entered expression because it appended the prompt and editor contents to `logLines`.
2. The REPL thread was still blocked inside `takeMVar inputMVar` waiting for input.
3. Since `replLoop` never received the submitted expression, it never called `runLexer`.
4. Because the compiler pipeline never ran, no `TUIOutput` event containing a parsed AST or compiler error was ever produced.

So the visible symptom was "the TUI only shows what I typed" even though the real issue was that the REPL and UI had stopped short of completing the handoff.

The first fix was to hand the submitted input back to the REPL through the `MVar` when Enter is pressed. The current code does that with a non-blocking write:

```haskell
liftIO $ void $ tryPutMVar inputMVar (Just content)
```

Once that happens, the blocked REPL thread resumes, tokenizes the input, and emits output back into the log via `TUIOutput`.

## Why `liftIO` is needed in the Brick UI

The Brick event handler does not run in plain `IO`. Its type is:

```haskell
handleEvent :: MVar (Maybe Text) -> BrickEvent WidgetName TUIEvent -> EventM WidgetName AppState ()
```

`EventM` is Brick's application monad for handling UI state, events, cursor behavior, and redraws. Inside `EventM`, you can use Brick state operations such as `get`, `put`, `modify`, and `zoom`, but `tryPutMVar` itself has the type:

```haskell
tryPutMVar :: MVar a -> a -> IO Bool
```

That means `tryPutMVar` is a raw `IO` action, not an `EventM` action. `liftIO` is the bridge that takes an `IO` action and embeds it into a larger monad that supports `IO`, in this case `EventM`.

In practical terms:

- Without `liftIO`, Brick code can update UI state, but it cannot directly call `tryPutMVar` or other `IO` functions.
- `liftIO` says: run this `IO` action from inside the current `EventM` handler.

That is why both of these are valid inside `handleEvent`:

```haskell
liftIO $ void $ tryPutMVar inputMVar Nothing
liftIO $ void $ tryPutMVar inputMVar (Just content)
```

The first is used for shutdown signaling, and the second is used for input submission.

## `liftIO` versus `effIO`

This codebase uses both `liftIO` and `effIO`, but they solve different problems in different layers.

- `effIO` is used in Bluefin code to lift `IO` into `Eff es` when you have an `IOE io` capability.
- `liftIO` is used in Brick code to lift `IO` into `EventM`.

So the distinction is architectural:

- In `runTerminalIO` and `runTerminalBrick`, the code is living inside Bluefin's `Eff es`, so `effIO` is the right tool.
- In `handleEvent`, the code is living inside Brick's `EventM`, so `liftIO` is the right tool.

They play similar roles, but in different effect systems.

## Why this helps for a robust TUI

This design makes UI replacement a local change:

- Keep `replLoop` as-is.
- Provide another constructor function that returns `Terminal es` but delegates to a TUI runtime (for example `brick`).
- Swap which interpreter is constructed at startup.

Benefits:

1. REPL behavior is consistent across frontends.
2. UI migration risk is reduced because domain logic is unchanged.
3. Testing improves because you can inject a deterministic test terminal.
4. Frontend-specific complexity stays outside core REPL logic.
5. Cross-thread coordination is explicit, which makes prompt, submit, output, and shutdown behavior easier to reason about.

## Example evolution path

A future TUI interpreter might conceptually look like:

```haskell
runTerminalTUI :: forall io es. (io :> es) => IOE io -> TUIRuntime -> Terminal es
```

Where:

- `prompt` reads from the TUI input widget/event queue.
- `output` writes to a scrollback/log pane.
- `Nothing` is returned when the TUI session is closed.

No signature changes are required for `replLoop`.

## Practical guidance

When adding features to the REPL:

- Extend logic in `replLoop` and related compiler modules.
- Avoid embedding frontend calls directly into REPL logic.
- If a new UI capability is truly required, add it to `Terminal` deliberately and implement it across interpreters.
- In the Brick layer, use `liftIO` whenever a handler must perform real `IO` such as attempting to write to an `MVar`, interacting with channels, or coordinating with another thread.
- Keep the direction of data flow clear: `TUIPrompt` and `TUIOutput` move through `BChan`, while submitted user input moves back through `MVar`.
- Treat the `MVar` as a one-response handoff per prompt, not as a general-purpose queue.
