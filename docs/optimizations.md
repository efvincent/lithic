# Compiler Optimizations and Technical Debt

## 1. Let-Generalization Environment Traversal

### The Problem
The current Hindley-Milner let-generalization implementation relies on naive set subtraction: `ftv(Type) \ ftv(Env)`.
At every `let` boundary, the compiler executes an $O(N)$ traversal of the entire lexical environment, recursively calling the effectful `force` function to resolve substitutions. This degrades compilation performance non-linearly as environment sizes grow or during persistent REPL sessions.

### The Solution: Level-Based Generalization
To achieve $O(1)$ environment checks, the unification engine must be upgraded to **Level-Based Generalization** (Didier Rémy's algorithm).

### Implementation Roadmap
1. **Lexical Levels:** Add `currentLevel :: Int` to the `Env` Reader handle. The top-level scope is `1`. Entering a `let` body increments the level.
2. **Meta Tagging:** Expand `TMeta` to store its birth level: `TMeta SourceSpan Int Int` (Span, ID, Level). `freshMeta` must assign the current lexical level to new meta-variables.
3. **Level Promotion (Escape):** Modify `unify`. If a meta-variable from a deeper level unifies with a type containing meta-variables from a shallower level, the deeper meta-variable's level must be mutated down (promoted) to record that it has escaped its local scope.
4. **$O(1)$ Generalization:** Rewrite `generalize` to traverse only the inferred `Type`. Any `TMeta` with a level strictly greater than the current `Env` level is generalized. The `ftvEnv` traversal is completely eliminated.
