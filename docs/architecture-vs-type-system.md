# Architecture vs. Type System: Bidirectional Hindley-Milner

When discussing modern compiler design, there is often a terminology collision between **Hindley-Milner (HM)** and **Bidirectional Typechecking**. It is easy to assume they are mutually exclusive alternatives, but they actually answer two completely different questions:

1. **The Type System (The "What"):** Hindley-Milner defines *what* the type system can express. Specifically, it is the ability to support parametric polymorphism (e.g., `forall a. a -> a`) without requiring the programmer to explicitly annotate every function and variable.
2. **The Architecture (The "How"):** Algorithm W and Bidirectional Typechecking are algorithms that define *how* the compiler figures those types out.

Lithic uses a **Bidirectional Architecture** to implement the **Hindley-Milner Feature Set**, serving as the bedrock for advanced features like Rank-2 Polymorphism and Row Polymorphism.

---

## Why Abandon Algorithm W?

Traditionally, the Hindley-Milner type system is implemented using **Algorithm W**. Algorithm W is purely bottom-up: it synthesizes types from the leaves of the AST to the root, generating global constraints and solving them via unification. It has no concept of "checking against an expected type."

For a basic ML or Haskell 98 clone, Algorithm W is perfect. However, Lithic's goal is to support **Rank-2 Polymorphism** (functions that take polymorphic functions as arguments, e.g., `f :: (forall a. a -> a) -> Int`).

If you try to add Rank-2 types to standard Algorithm W, the typechecker breaks down. It becomes mathematically undecidable because a purely bottom-up algorithm cannot "guess" when to instantiate or generalize higher-rank types without context.

## The Bidirectional Solution

To solve the undecidability of higher-rank types, Lithic uses a **Bidirectional Typechecker**. This architecture splits the typechecker into two mutually recursive phases:
* **Synthesis (`infer`):** Bottom-up propagation (like Algorithm W).
* **Checking (`check`):** Top-down propagation.

By adding the `check` phase, the compiler can look at a Rank-2 type signature, push it *down* into a lambda, and cleanly verify it without having to magically guess the higher-rank structure. Because Bidirectional Typechecking is strictly more powerful than Algorithm W, modern languages (like Scala 3, PureScript, and modern GHC Haskell) use it as their foundational architecture.

---

## The Monomorphism Restriction & Let-Generalization

Before introducing Rank-2 types, a bidirectional HM checker must handle standard Rank-1 polymorphism. Consider the following completely valid functional program:

```haskell
let id = \x => x in id id 5
```

In a purely **monomorphic** bidirectional engine (one without HM let-generalization), this program will crash with an **Occurs Check (Infinite Type)** error. Here is why:

1. The compiler infers `id` as a single, concrete meta-variable type: `?0 -> ?0`.
2. It binds `id : ?0 -> ?0` in the environment.
3. When it evaluates `id id`, it tries to apply the function (`?0 -> ?0`) to the argument (`?0 -> ?0`).
4. This forces the engine to unify the domain (`?0`) with the argument (`?0 -> ?0`).
5. Unifying `?0` with `?0 -> ?0` creates an infinite loop, triggering the occurs check.

### The HM Fix: Let-Generalization
To fix this, the engine must implement **Let-Generalization**, the defining trick of Hindley-Milner. 

Instead of binding raw meta-variables into the environment, the compiler must:
1. **Generalize:** Close over the free meta-variables at the `let` binding to create a polytype (`TForall`). `id` becomes `forall a. a -> a`.
2. **Instantiate:** Every time `id` is looked up in the environment, the compiler strips the `forall` and replaces the bound variables with completely fresh meta-variables.
   * First `id` lookup: `?1 -> ?1`
   * Second `id` lookup: `?2 -> ?2`

Now, when unifying `id id`, the compiler unifies `?1` with `?2 -> ?2`. Because `?1` and `?2` are different, isolated meta-variables, unification succeeds safely.

## Lithic's Implementation Roadmap

By building the Bidirectional engine first, Lithic avoids massive rewrites later. The roadmap for the type system naturally unfolds as:

1. **Monomorphic Core:** Basic `infer`/`check` loop. *(Complete)*
2. **Stateful Unification:** Effectful constraint solving with `TMeta`. *(Complete)*
3. **Let-Polymorphism (HM):** Adding `TForall`, `generalize`, and `instantiate` to `Let` bindings.
4. **Rank-2 Skolemization:** Expanding the `subsumes` bridge to instantiate expected Rank-2 types with rigid constants (Skolems) before unification.