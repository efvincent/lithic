# Bidirectional Typechecking & Stateful Unification

Lithic uses a bidirectional type system, augmented with a stateful unification engine for constraint solving. This architecture cleanly separates type synthesis from type checking and establishes the substitution machinery needed for future inference work without defaulting to Hindley-Milner assumptions.

## Core Architecture

The typechecker is split into two mutually recursive phases: **Synthesis** (`infer`) and **Checking** (`check`). 

### 1. Synthesis (`infer`)
*Bottom-up propagation.* The `infer` function takes an expression and attempts to deduce its type strictly from its sub-expressions. 
* Use case: Literals, variables, annotated bindings, and function applications.
* Example: For `f x`, the compiler infers the type of `f` (which must be an arrow type `a -> b`), checks `x` against `a`, and synthesizes `b` as the result.

### 2. Checking (`check`)
*Top-down propagation.*
The `check` function takes an expression and an *expected* type, pushing known type information down into the AST.
* Use case: Unannotated lambdas and explicitly typed `let` bindings.
* Example: If checking `\x => x` against `Int -> Int`, the compiler binds `x` to `Int` in the environment and checks the body `x` against the expected return type `Int`.

## The Bridge: `subsumes` and `unify`

When `check` encounters an expression it cannot break down directly (for instance, checking a variable against a specific type), it falls back to a synthesis-and-subsume strategy.

1. **Infer**: It synthesizes the actual type of the expression.
2. **Subsume**: It calls `subsumes inferred expected`.

Currently, `subsumes` acts as a direct wrapper around `unify`. In the future, `subsumes` will be expanded to handle **Rank-2 Skolemization** (instantiating polymorphic `forall` types with fresh variables or rigid constants) before handing the structural types off to the unification engine.

## The Substitution Engine, `force`, and `zonk`

To support advanced type inference, Lithic's `Type` AST includes `TMeta Int`, which represents a type that the compiler does not fully know yet.

These meta-variables are resolved through a stateful substitution engine tracked via a `Bluefin.State TCState` handle. `TCState` holds an `IntMap Type`, mapping meta-variable IDs to concrete types. The active executable allocates this state once in `Main` and threads the handle through the REPL so substitutions can persist for the lifetime of the session.

### Shallow Resolution (`force`)
`force` follows `TMeta` substitution chains until it reaches either an unbound meta-variable or a non-meta type. It does not recursively descend into arrow components. This makes it the right primitive for unification and the occurs check, where the typechecker needs to observe the current head constructor without fully normalizing the entire type tree.

### Unification (`unify`)
The `unify` function starts by `force`-ing both inputs, then walks the resulting types structurally. If it encounters a `TMeta`, it updates the `TCState` to bind that meta-variable to the other type, incrementally solving constraints.

### Deep Resolution (`zonk`)
Because the substitution map is updated incrementally, a meta-variable might point to another meta-variable, which points to a concrete type. 

`zonk` is a deep-resolution function that first `force`s the outermost type and then recursively walks the structure, replacing `TMeta` nodes with their fully resolved concrete types from the substitution map. The underlying substitution lookups also perform **path compression**, updating the map so subsequent lookups bypass chains and go straight to the resolved type.

You should use these operations for different purposes:
1. Call `force` before structural comparison in `unify` and before traversing types in the occurs check.
2. Call `zonk` before displaying inferred types to the user in the REPL or otherwise finalizing a type for presentation.

## Current Scope

This branch adds the stateful substitution infrastructure, persistent REPL-level `TCState`, and corrected deep resolution for displayed types. It does not yet broaden the set of programs that infer successfully by itself because fresh meta-variable generation is not yet threaded through additional inference rules.