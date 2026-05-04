# Bidirectional Typechecking & Stateful Unification

Lithic uses a bidirectional type system, augmented with a stateful unification engine for constraint solving. This architecture cleanly separates type synthesis from type checking and establishes the substitution machinery needed for future inference work without defaulting to Hindley-Milner assumptions.

## Core Architecture

The typechecker is split into two mutually recursive phases: **Synthesis** (`infer`) and **Checking** (`check`). 

### 1. Synthesis (`infer`)
*Bottom-up propagation.* The `infer` function takes an expression and attempts to deduce its type strictly from its sub-expressions.
* Use case: literals, variables, lambdas (annotated and unannotated), annotated bindings, and function applications.
* Example: for `f x`, if `f` is currently unknown (`TMeta`), the checker allocates fresh meta-variables for domain/range, constrains `f` to an arrow type, then checks `x` against the inferred domain.

### 2. Checking (`check`)
*Top-down propagation.*
The `check` function takes an expression and an *expected* type, pushes known type information down into the AST, and first `force`s that expected type through substitutions.
* Use case: lambdas checked against known arrow types, lambdas checked against unresolved metas, and synthesis+unification fallback for all other terms.
* Example: if checking `\x => x` against an unresolved `TMeta m`, the checker allocates fresh domain/range metas, binds `m` to `domain -> range`, then checks the body against `range`.

## The Bridge: `subsumes` and `unify`

If terms such as `forall`, rigid skolems, unification, or occurs check are unfamiliar, read the short glossary in `docs/higher-rank-types.md` first.

When `check` encounters an expression it cannot break down directly (for instance, checking a variable against a specific type), it falls back to a synthesis-and-subsume strategy.

1. **Infer**: It synthesizes the actual type of the expression.
2. **Subsume**: It calls `subsumes inferred expected`.

`subsumes` now performs rank-2-aware routing before falling back to plain unification:

1. If the expected type is polymorphic (`forall`), it skolemizes the quantified variables into rigid skolems and recurses.
2. If the inferred type is polymorphic (`forall`), it instantiates the quantified variables into fresh flexible metas and recurses.
3. If both sides are arrow types, it applies arrow subsumption (contravariant domain, covariant codomain).
4. Otherwise, it falls back to structural unification.

## The Substitution Engine, `force`, and `zonk`

To support advanced type inference, Lithic's `Type` AST includes `TMeta Int`, which represents a type that the compiler does not fully know yet.

These meta-variables are resolved through a stateful substitution engine tracked via a `Bluefin.State TCState` handle. `TCState` holds an `IntMap Type`, mapping meta-variable IDs to concrete types. The active executable allocates this state once in `Main` and threads the handle through the REPL so substitutions can persist for the lifetime of the session.

### Shallow Resolution (`force`)
`force` follows `TMeta` substitution chains until it reaches either an unbound meta-variable or a non-meta type. It does not recursively descend into arrow components. This makes it the right primitive for unification and the occurs check, where the typechecker needs to observe the current head constructor without fully normalizing the entire type tree.

### Unification (`unify`)
The `unify` function starts by `force`-ing both inputs, then walks the resulting types structurally. If it encounters a `TMeta`, it updates the `TCState` to bind that meta-variable to the other type, incrementally solving constraints.

`TSkolem` nodes are rigid: they only unify with the exact same skolem identity. This is the mechanism that prevents invalid rank-2 instantiation through ordinary unification.

### Row Polymorphism and `TMeta` Expansion

Lithic implements order-independent structural records via Row Polymorphism. When the typechecker needs to access a field inside a record (e.g., `\r -> r.x`), it doesn't immediately fail if the record's exact shape isn't known. Instead, it relies on a combination of **Row Shifting** and **Lazy `TMeta` Expansion**.

When `infer` processes a record selection (`RecSelect`), it calls the `rewriteRow` helper. `rewriteRow` searches the record's type for the requested label. 

The true power of this system emerges when `rewriteRow` encounters an open meta-variable (`TMeta`):
1. **The Scenario:** A user writes `\r -> r.x`. The variable `r` is initially assigned a completely unconstrained meta-variable, say `?m1`.
2. **The Search:** `rewriteRow` is asked to find the label `"x"` inside `?m1`.
3. **The Expansion:** Because `?m1` is open, the typechecker safely assumes, *"If this code is valid, `?m1` must be a record containing at least an `"x"` field."*
4. **The Mutation:** It generates two new meta-variables: `?fieldTy` and `?restRow`. It then binds `?m1` in the stateful substitution dictionary to `TRowExtend "x" ?fieldTy ?restRow`.

By the time the function finishes checking, the type of `r` has organically grown from an unknown `?m1` into the polymorphic row type `{ x : ?fieldTy | ?restRow }`. If the user later accesses `r.y`, the `?restRow` meta-variable will seamlessly expand again to accommodate `"y"`.

### Native Lens Update Typing (`RecUpdate`)

Lens updates type-check by first resolving the target field through `resolvePath`, then validating the update operator against that field type.

1. For `record.{ path := value }`, the checker infers `value` and unifies it with the resolved field type.
2. For `record.{ path %= f }`, the checker requires `f` to unify with `fieldTy -> fieldTy`.
3. The expression result type is the original record type, modeling functional update semantics at the type level.

Current status note:
1. Structural records (`TRecord` over row types) are supported now.
2. Nominal-record path resolution is intentionally stubbed and currently returns a targeted type error.

### Deep Resolution (`zonk`)
Because the substitution map is updated incrementally, a meta-variable might point to another meta-variable, which points to a concrete type. 

`zonk` is a deep-resolution function that first `force`s the outermost type and then recursively walks the structure, replacing `TMeta` nodes with their fully resolved concrete types from the substitution map. The underlying substitution lookups also perform **path compression**, updating the map so subsequent lookups bypass chains and go straight to the resolved type.

You should use these operations for different purposes:
1. Call `force` before structural comparison in `unify` and before traversing types in the occurs check.
2. Call `zonk` before displaying inferred types to the user in the REPL or otherwise finalizing a type for presentation.

## Current Scope

This branch includes stateful substitution infrastructure, persistent REPL-level `TCState`, corrected deep resolution for displayed types, fresh-meta based inference/checking paths for previously unresolved lambda/application cases, HM-style let-polymorphism (`generalize`/`instantiate`) for `let` bindings, initial rank-2-aware subsumption via skolemization/instantiation, and initial structural row-polymorphism plus lens-update checking for records.

The rank-2 path is intentionally scoped to subsumption and rigid-skolem safety checks. Richer elaboration-oriented features (for example, macro-aware elaboration and deeper constraint systems beyond current unification/subsumption) remain future work.

Generalized type variables are currently rendered using compiler-generated internal names in user output; this is a presentation choice and not the required surface syntax for user-written type signatures.
