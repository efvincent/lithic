# Theory and Resources: Rank-2 Polymorphism and Skolemization

This document explains the theory behind Lithic's rank-2 support and then lists recommended resources for deeper study.

Lithic intentionally uses a bidirectional typechecker instead of relying on purely bottom-up Hindley-Milner (HM) inference. HM handles rank-1 polymorphism well (`let`-generalization), but higher-rank polymorphism requires top-down information to remain decidable and predictable.

## Core concepts used in this document

Before discussing rank-2 behavior, define core terms that appear throughout type-inference literature.

### `forall`

`forall` introduces universal quantification in a type. It means the type must work uniformly for any type substituted for the quantified variable.

Example:

```haskell
forall a. a -> a
```

This says: for every type `a`, the function takes an `a` and returns an `a`.

In practical typechecking terms, `forall` marks a polymorphic boundary. Depending on context, the checker may instantiate it with fresh flexible unknowns (metas) or replace it with rigid skolem constants.

### Rigid skolems

A rigid skolem is a fresh, abstract type constant introduced during checking to stand in for a universally-quantified variable.

"Rigid" means it is not allowed to unify with arbitrary types. It can only match the exact same skolem identity.

Purpose: prevent accidental specialization of polymorphic requirements.

Example intuition:

- Expected type: `forall a. a -> a`
- Skolemized view: `s -> s` where `s` is rigid
- Invalid specialization such as `s ~ Int` is rejected

### Synthesizing local constraints

When a checker reads an expression bottom-up, each syntax node contributes small typing requirements derived from its local shape. These requirements are called local constraints.

Example (application):

```haskell
f x
```

From this node alone, the checker can synthesize the constraint that `f` must have a function type whose domain matches the type of `x`:

```text
type(f) ~ type(x) -> result
```

Where `result` is an unknown type variable (or meta-variable) representing the application's output type.

As the checker walks the tree, it accumulates many such constraints and then solves them together.

### Unification

Unification is the constraint-solving process that tries to make two types equal by assigning values to unknowns (meta-variables), while rejecting impossible equalities.

Simple examples:

- `?a ~ Int` can be solved by setting `?a := Int`.
- `?a -> ?a ~ Int -> Int` can be solved by setting `?a := Int`.
- `Int ~ Bool` fails (constructors do not match).
- `?a ~ ?a -> Int` fails by the occurs check (would require an infinite type).

In Lithic, unification is also where rigidity is enforced for skolems: rigid skolems do not unify with arbitrary concrete types.

### Occurs check

The occurs check is a safety check during unification that prevents assigning a type variable/meta-variable to a type that already contains that same variable.

Canonical bad equation:

```text
?a ~ ?a -> Int
```

If accepted, this would imply an infinite type expansion:

```text
?a = (?a -> Int) = ((?a -> Int) -> Int) = ...
```

So unification must reject it.

## What "rank" means

Intuitively, the rank of a type describes how deeply `forall` appears to the left of function arrows.

- Rank-1: quantified variables appear only at the outermost level.
- Rank-2: a function argument itself may be polymorphic.

Concrete examples:

```haskell
-- Rank-1
forall a. a -> a

-- Rank-2 (argument is polymorphic)
(forall a. a -> a) -> Int
```

The second type is the important one for Lithic's current direction: callers pass a polymorphic function as an argument.

## Why pure HM breaks here

Algorithm W style inference is bottom-up. It works by synthesizing local constraints and then unifying them.

For rank-2 inputs, the checker must decide whether a polymorphic argument should remain polymorphic or be instantiated. Making that choice without expected-type context is ambiguous and can become undecidable in the general case.

Bidirectional checking fixes this by separating:

- Synthesis (`infer`): figure out a type from the expression itself.
- Checking (`check`): verify an expression against an expected type.

The expected type gives the checker the context needed to handle higher-rank boundaries safely.

## Lithic strategy: subsumption plus skolemization

Lithic routes fallback compatibility checks through `subsumes`. At a high level:

1. If the expected type is polymorphic (`forall`), replace bound vars with rigid skolems.
2. If the inferred type is polymorphic, instantiate with fresh flexible metas.
3. If both sides are arrows, apply arrow subsumption:
   - domain is contravariant,
   - codomain is covariant.
4. Otherwise, use ordinary structural unification.

This keeps rank-2 behavior explicit and local to the compatibility boundary rather than trying to infer everything from unification alone.

## Why rigid skolems matter

Skolemization protects soundness.

When the checker expects a polymorphic argument such as `forall a. a -> a`, replacing `a` with a rigid skolem says: "treat this as an abstract, unknown-but-fixed type." A rigid skolem cannot unify with arbitrary concrete types unless it is the same skolem identity.

That prevents accidental specialization like forcing `a` to become `Int` just because a local use site happens to involve integers.

In practice, this is the guardrail that distinguishes:

- valid rank-2 use of truly polymorphic arguments, and
- invalid cases that try to pass monomorphic functions where polymorphism is required.

## Reading the behavior in Lithic

Rank-2 behavior is visible in the golden tests:

- `rank2-success` demonstrates a polymorphic argument accepted at a rank-2 call site.
- `rank2-rigid-fail` demonstrates rigid-skolem rejection when a monomorphic function is passed where `forall` polymorphism is required.

These tests are useful as executable documentation for the current implementation boundary.

## Scope note

This document describes Lithic's current rank-2-oriented subsumption behavior. It is not claiming full arbitrary-rank inference or elaboration-heavy polymorphism yet. Future work can extend this foundation with richer diagnostics and broader rank coverage.

## Recommended references

The resources below range from first-principles textbooks to implementation-focused papers.

### 1. Foundational textbook

- **"Types and Programming Languages" (TAPL), Benjamin C. Pierce**
  - Why read: Strong foundation for universal types and polymorphism mechanics.
  - Key chapters:
    - Chapter 23 (Universal Types)
    - Chapter 25 (ML-style Let-Polymorphism)

### 2. Core papers

- **"Complete and Easy Bidirectional Typechecking for Higher-Rank Polymorphism"** (Dunfield and Krishnaswami, 2013)
  - Why read: A clear blueprint for modern bidirectional higher-rank checking.
  - Link: [ACM Digital Library](https://dl.acm.org/doi/10.1145/2500365.2500582) (free versions are often available from author pages).

- **"Practical type inference for arbitrary-rank types"** (Jones, Vytiniotis, Weirich, Shields, 2007)
  - Why read: Practical treatment of higher-rank inference design trade-offs in GHC-style systems.
  - Link: [Journal of Functional Programming](https://www.cambridge.org/core/journals/journal-of-functional-programming/article/practical-type-inference-for-arbitraryrank-types/612DB0E7DEEE5601DDAE54F38B95328C)

### 3. Article

- **"Let Should Not Be Generalized" by Alexis King**
  - Why read: Useful perspective on the tension between HM-style generalization and modern top-down typing constraints.
  - Link: [lexi-lambda.github.io](https://lexi-lambda.github.io/blog/2020/08/13/let-should-not-be-generalized/)

### 4. Lectures

- **Simon Peyton Jones talks on type inference and GHC internals**
  - Why watch: High-quality explanations of unification, skolems, and inference design decisions.