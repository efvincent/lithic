# Strict Small-Step Evaluator Draft (Phase 8 Artifact)

Status: Draft formal artifact for Phase 8 baseline.
Semantics baseline: Strict, small-step.
Scope: Initial core sufficient to drive an interpreter prototype and educational exposition.

## 1. Purpose

This document defines an initial small-step operational semantics for Lithic's evaluator track.

Goals:
1. Make the evaluator model explicit before implementation.
2. Preserve precise correspondence between syntax and reduction behavior.
3. Prioritize pedagogical rigor over minimal implementation effort.

Non-goals for this draft:
1. Full feature coverage of every surface construct.
2. Mechanized proofs.
3. Runtime optimization strategy.

## 2. Core Judgment Forms

We use the following judgments:

1. Expression step:

```text
e -> e'
```

2. Multi-step closure:

```text
e ->* e'
```

3. Value classification:

```text
Value(e)
```

## 3. Core Syntax Slice (Evaluator Draft)

This initial slice covers:

```text
e ::= x
    | lit
    | \p => e
    | e e
    | let p = e in e
   | case e of p => e ; ...
    | Variant L e
    | { l1 = e1, ..., ln = en }
    | e.f
```

Pattern slice for this draft:

```text
p ::= _
    | x
    | lit
    | Variant L p
    | { l1 = p1, ..., ln = pn }
```

Notes:
1. Type annotations are erased for runtime semantics.
2. This draft assumes the parser and typechecker have already validated syntax and typing.
3. Record lens-update syntax (`r.{ f := v }`, `r.{ f %= fn }`) is deferred to a follow-up extension.

### 3.1 Minimal Core AST (Phase 8 Baseline)

The Phase 8 evaluator target is a minimal Core language for currently implemented
runtime-relevant features. This Core AST is intentionally smaller than the
surface parser AST and serves as the evaluation boundary.

Core expressions:

```text
ce ::= cvar x
     | clit lit
     | clam p ce
     | capp ce ce
     | clet p ce ce
   | ccase ce of p => ce ; ...
     | cvariant L ce
     | crec { l1 = ce1, ..., ln = cen }
     | cselect ce l
```

Core patterns:

```text
cp ::= _
     | x
     | lit
     | cvariant L cp
     | crec { l1 = cp1, ..., ln = cpn }
```

Core invariants for Phase 8:
1. `Ann` nodes do not appear in Core.
2. `RecUpdate` nodes do not appear in Core.
3. Record literals are represented canonically (single constructor form,
   no surface row-tail sugar).
4. Core `ccase` branch lists preserve source order.
5. Core retains source spans in implementation for diagnostics, even though
   spans are omitted in this formal shorthand.

Recommended module boundaries for this codebase:
1. Keep surface AST in `Compiler.AST` (existing parser/typechecker target).
2. Add Core AST in a separate module `Compiler.AST.Core`.
3. Keep shared primitive data (`Span`, `Literal`) in `Compiler.AST`
   initially for minimal churn; extract to a shared module later only if needed.
4. Evaluator and backend-facing passes should consume `Compiler.AST.Core`, not
   surface `Expr`, once the elaboration subset is in place.

Phase 8 migration sequence (practical):
1. Introduce `Compiler.AST.Core` with Phase 8 constructors only.
2. Add `Compiler.Elaborator` skeleton with `elabExpr`/`elabPattern`.
3. Implement elaboration for the Core subset: var/lit/lam/app/let/case/variant/
   record/select and annotation erasure.
4. Keep `RecUpdate` outside initial Core subset with explicit elaboration error.
5. Only after elaboration compiles, begin CEK machine implementation over Core.

### 3.2 Surface-to-Core Boundary (Phase 8)

Pipeline ordering constraint:

```text
parse -> expand-macros -> desugar/elaborate -> typecheck/evaluate
```

Phase 8 practical policy:
1. Macro expansion is a reserved pass in this phase. Operationally, it is the
   identity transformation until macros are implemented.
2. Desugaring/elaboration to Core is active in Phase 8 for the evaluator subset.
3. Evaluation semantics in this document are normative for Core terms.
4. Surface examples are interpreted as shorthand for their elaborated Core forms.

Initial desugaring commitments (Phase 8 subset):
1. `Ann e T` desugars to Core `ce` by erasing annotations after typechecking.
2. Surface record syntax desugars to canonical Core `crec` representation.
3. `RecSelect` desugars directly to Core `cselect`.
4. `RecUpdate` is out of initial Core scope; support is deferred to a follow-up
   Core extension and corresponding evaluator rule extension.

## 4. Values

This document uses a **substitution-based** formal model. In this model, lambdas
are values by syntax (canonical forms), not because they are closed. A lambda
body may still contain free variables before substitution/environment closing.
See §12 for the correspondence to environment-based implementation.

```text
v ::= lit
    | \p => e
    | Variant L v
    | { l1 = v1, ..., ln = vn }
```

Value predicate:

1. `Value(lit)`.
2. `Value(\p => e)` for any pattern `p` and expression `e`.
3. `Value(v)` implies `Value(Variant L v)`.
4. `Value(v1) ∧ ... ∧ Value(vn)` implies `Value({ l1 = v1, ..., ln = vn })`.

## 5. Runtime Environment Model

Even though the formal step rules use substitution notation, we define the runtime environment model explicitly because it motivates the implementation and appears in the pattern-match helper.

A runtime environment is a finite partial map:

```text
rho : Var ⇀ Val
```

The empty environment: `rho_0 = {}`.

Environment extension by a single binding:

```text
rho[x -> v]
```

Bulk extension by a binding map `theta`:

```text
rho [+] theta
```

A **binding map** `theta : Var ⇀ Val` is produced by pattern matching (§6) and
maps the variables bound by a pattern to the sub-values they matched.

Substitution notation `e[theta]` denotes capture-avoiding substitution of all
bindings in `theta` into expression `e`. In the implementation this is realised
as `eval (env <> theta) body`; the two are equivalent by the standard
"environment = accumulated delayed substitutions" correspondence (see §12).

## 6. Evaluation Contexts

We model call-by-value strictness with evaluation contexts.

```text
E ::= [.]
    | E e
    | v E
    | let p = E in e
    | case E of branches
    | Variant L E
    | { l1 = v1, ..., lk = vk, lk+1 = E, lk+2 = ek+2, ..., ln = en }
    | E.f
```

Record contexts enforce left-to-right, field-by-field evaluation: fields
`l1..lk` are already values; field `lk+1` is the current redex; fields
`lk+2..ln` are unevaluated.

Plugging notation: `E[e]` substitutes `e` at the hole `[.]` in context `E`.

Congruence rule:

```text
e -> e'
----------------
E[e] -> E[e']
```

## 7. Pattern Match Helper

Define a total helper returning a binding map or failure:

```text
match(v, p) = Just theta | Nothing
```

Cases:

1. `match(v, _) = Just {}`.
2. `match(v, x) = Just { x -> v }`.
3. `match(lit1, lit2) = Just {}` if `lit1 == lit2`, else `Nothing`.
4. `match(Variant L v, Variant L p) = match(v, p)`.
5. `match(Variant L1 v, Variant L2 p) = Nothing` when `L1 ≠ L2`.
6. `match({ l1=v1, ..., ln=vn }, { l1=p1, ..., ln=pn }) = combine(match(v1,p1), ..., match(vn,pn))`.
7. Any remaining shape mismatch yields `Nothing`.

Record-pattern policy in this draft is **exact-shape matching**: a record value
matches a record pattern iff they have the same field label set and each field
sub-match succeeds. This policy is independent of row polymorphism at the type
level and is chosen for deterministic runtime behavior in the Phase 8 baseline.

The `combine` helper:

```text
combine(Just t1, ..., Just tn) = Just (t1 ∪ ... ∪ tn)   -- theta maps are disjoint (enforced by typechecker)
combine(... Nothing ...)       = Nothing
```

## 8. Core Reduction Rules

### 8.1 Beta Reduction (Application)

Both sides must be values before the step fires.

```text
Value(v2)
match(v2, p) = Just theta
------------------------------------------
(\p => e) v2  ->  e[theta]
```

Match failure (irrefutable-pattern violation; see §11):

```text
Value(v2)
match(v2, p) = Nothing
------------------------------------------
(\p => e) v2  ->  RuntimeError(MatchError p v2)
```

### 8.2 Let Binding

```text
Value(v)
match(v, p) = Just theta
--------------------------------------------
let p = v in e  ->  e[theta]
```

Match failure:

```text
Value(v)
match(v, p) = Nothing
--------------------------------------------
let p = v in e  ->  RuntimeError(MatchError p v)
```

### 8.3 Case Dispatch

First-match wins in source order once the scrutinee is a value.

```text
Value(v)
selectBranch(v, [p1 => e1, ..., pk => ek]) = Just (ei, theta)
--------------------------------------------
case v of [p1 => e1, ..., pk => ek]  ->  ei[theta]
```

Exhaustion failure:

```text
Value(v)
selectBranch(v, branches) = Nothing
--------------------------------------------
case v of branches  ->  RuntimeError(NonExhaustive v)
```

`selectBranch` is defined by linear traversal:

1. If the branch list is empty, return `Nothing`.
2. If `match(v, p1) = Just theta`, return `Just (e1, theta)`.
3. Otherwise recurse on the tail.

### 8.4 Record Field Selection

```text
Value({ l1 = v1, ..., ln = vn })
lk ∈ { l1, ..., ln }
--------------------------------------------
{ l1 = v1, ..., ln = vn }.lk  ->  vk
```

Missing-field failure (unreachable after typechecking):

```text
{ l1 = v1, ..., ln = vn }.lk  ->  RuntimeError(MissingField lk)
   where lk ∉ { l1, ..., ln }
```

### 8.5 Variant and Record Construction

Strict payload/field evaluation is handled entirely by the context congruence rule
(§6). No additional head rules are required: once all sub-expressions are values,
`Variant L v` and `{ l1=v1,...,ln=vn }` are themselves values and no further
reduction applies.

## 9. Determinism Theorem

**Theorem (Determinism).** For any expression `e`, there is at most one `e'`
such that `e -> e'`.

**Proof sketch.**

1. **Unique decomposition.** The evaluation context grammar defines a unique
   decomposition of any non-value, non-error expression into a context `E` and a
   redex `r` such that `e = E[r]`. Uniqueness follows by structural induction:
   each case in the context grammar is guarded by a value predicate on the
   left and an unevaluated expression on the right (or the hole itself),
   preventing ambiguous decompositions.

2. **Unique rule per redex shape.** Each redex form — application, let,
   case, field selection — admits exactly one applicable rule per configuration
   (distinguished by whether `match` succeeds or fails, never both).

3. **First-match case.** `selectBranch` is a deterministic linear scan; it
   returns at most one result.

Therefore, each reduction step is unique. □

*Remark.* This argument assumes well-formed, well-typed expressions. An
ill-formed expression may have no applicable rule (a **stuck** term), which is
distinct from having multiple applicable rules.

## 10. Progress and Preservation (Sketch)

These are stated as design targets, not mechanized proofs, for Phase 8.

To avoid ambiguity, this section uses an explicit error-configuration judgment:

```text
e -> error(err)
```

where `error(err)` is terminal (no further reduction).

**Progress (with explicit errors).** If `⊢ e : T` and `e` is not a value, then
either `e -> e'` for some `e'`, or `e -> error(err)` for some `err`.

Notes:
1. Progress for `case` holds only when the pattern coverage checker has
   certified exhaustiveness. For open-universe variants, `RuntimeError(NonExhaustive)`
   is a valid and expected runtime outcome, not a violation.
2. `RuntimeError(MatchError)` in let/lambda binders is precluded once a
   coverage policy for irrefutable binder patterns is enforced; that policy
   is not yet implemented at the surface.

**Preservation (Subject Reduction, non-error steps).** If `⊢ e : T` and
`e -> e'` where `e'` is not `error(err)`, then `⊢ e' : T`.

Notes:
1. *Beta reduction.* Follows from the typing rule for application and the
   invariant that `match(v, p) = Just theta` produces a theta whose domain
   exactly matches the variables bound by `p` with compatible types.
2. *Let binding.* Analogous to beta reduction via the let-typing rule.
3. *Case dispatch.* Branch body `ei` is typed under variables bound by `pi`;
   theta-substitution from a successful match provides exactly those bindings.
4. *Record selection.* The record type carries field `lk : T`; selecting `lk`
   yields a value of type `T`.
5. Error configurations are terminal and intentionally excluded from the
   preservation claim above.

## 11. Relationship to Typechecker Guarantees

Given prior type-checking and pattern coverage checks:

1. `RuntimeError(NonExhaustive)` is unreachable for closed-universe `case`
   expressions that passed coverage analysis.
2. `RuntimeError(NonExhaustive)` may arise at runtime for open-universe
   `case` expressions by design; this is not a defect.
3. `RuntimeError(MissingField)` is unreachable for well-typed record-selection
   expressions.
4. `RuntimeError(MatchError)` in let/lambda binders may arise until a
   coverage policy for irrefutable patterns is enforced.

## 12. Implementation Correspondence

This section distinguishes the formal artifact (small-step relation) from
implementation strategies. The formal semantics in this document remains
small-step; implementation may choose either an explicit-step machine or a
big-step interpreter, with correspondence obligations stated below.

### 12.1 Formal-to-Haskell Mapping

| Formal concept              | Haskell representation                                      |
|-----------------------------|-------------------------------------------------------------|
| `e`                         | `CoreExpr` (in `Compiler.AST.Core`)                         |
| `v`                         | `Value` ADT (in `Compiler.Evaluator`)                       |
| `rho : Var ⇀ v`             | `type Env = Map Text Value`                                 |
| `theta` (binding map)       | `Map Text Value` returned by `matchPattern`                 |
| `e[theta]` (substitution)   | Environment extension at binder entry                        |
| `E[.]` (evaluation context) | Explicit machine context (CEK-style) or derived evaluation order in a big-step interpreter |
| `RuntimeError(...)`         | `Left EvalError` in `Either EvalError Value`                |
| `selectBranch`              | Linear scan over `[(CorePattern, CoreExpr)]` using `matchPattern` |

Architecture note (Surface/Core boundary):
1. Phase 8 evaluator execution is over Core (`CoreExpr`) after elaboration.
2. Surface AST remains frontend syntax; evaluation semantics are defined on Core.
3. Any new surface construct must elaborate into existing/new Core forms before evaluation.

### 12.2 Proposed Module and Key Types

Target module: `src/Compiler/Evaluator.hs`

```haskell
data Value
  = VLit    Literal
   | VClosure Env CorePattern CoreExpr   -- lambda value; captures environment at creation
   | VVariant Text Value
   | VRecord  [(Text, Value)]

type Env = Map Text Value

data EvalError
   = EvalUnboundVar Span Text
   | EvalNonFunctionApp Span Value
   | EvalPatternMismatch Span CorePattern Value
   | EvalNonExhaustiveCase Span Value
   | EvalMissingField Span Text Value
   | EvalNotImplemented Span Text

evalCore :: CoreExpr -> Either EvalError Value
```

If the implementation uses closures/environments rather than literal
capture-avoiding substitution, we require the standard correspondence lemma:

```text
If e ->* v in substitution semantics,
then evalEnv(rho0, e) = v in environment semantics,
up to alpha-equivalence of bound names.
```

This keeps the specification small-step while permitting a practical runtime
implementation strategy.

### 12.3 Evaluator-Driven REPL Output

Once the evaluator is wired to the REPL pipeline (parse → check → eval):

- Successful evaluation: `[Val] <show value>`
- Evaluation error: `Eval Error: <description>`

The existing `parse → check → elaborate` pipeline is preserved; evaluation is a new
final stage that consumes a well-typed `CoreExpr` and produces a `Value` or `EvalError`.

## 13. Open Follow-Ups

1. Extend pattern and syntax slices to cover lens-update syntax
   (`r.{ f := v }`, `r.{ f %= fn }`).
2. Define a runtime value display/`Show` specification for user-facing output.
3. Instrument the evaluator for step-count tracking to support an educational
   trace mode in the REPL.
4. State and prove the "environment vs. substitution equivalence" lemma formally,
   establishing the correspondence noted in §12.
5. Add an appendix comparing this strict small-step semantics with a
   call-by-need (lazy) alternative, without altering the strict baseline.

## 14. Implementation Strategy Comparison (Prior Art)

This section compares two implementation approaches for the same strict
call-by-value language semantics.

### 14.1 Big-Step Closure Evaluator

Shape:
1. `eval :: Env -> Expr -> Either EvalError Val`
2. Lambdas evaluate to closures (`Env`, binder, body).
3. Application evaluates function and argument, then evaluates body under
   extended environment.

Prior art alignment:
1. Common in educational interpreters and early compiler prototypes.
2. Matches many direct-style implementations inspired by the natural-semantics
   presentation in TAPL-style developments.
3. Similar engineering shape to many functional-language frontends before
   abstract-machine lowering.

Strengths for Lithic:
1. Fastest path to a working evaluator integrated into REPL.
2. Simple runtime representation and straightforward error handling.
3. Easy to read while still preserving strict order.

Costs for Lithic:
1. Harder to expose single-step traces directly from the evaluator core.
2. Harder to prove or test one-step correspondence against §8 rules.
3. Tends to blur the distinction between semantic specification and
   implementation behavior unless correspondence tests are added.

### 14.2 Small-Step CEK-Style Evaluator

Shape:
1. Machine state `(Control, Environment, Kontinuation)`.
2. One transition relation on machine states per step.
3. Values arise when control is value and continuation is empty.

Prior art alignment:
1. Classic abstract-machine lineage (CEK/CESK family) used to execute
   call-by-value lambda calculi with environments.
2. Closely aligned with small-step operational semantics and evaluation
   contexts (defunctionalized continuations).
3. Standard path when semantics-trace fidelity and mechanized reasoning matter.

Strengths for Lithic:
1. Directly mirrors this document's small-step intent.
2. Naturally supports step tracing, debugging, and pedagogical "next step"
   visualizations in REPL mode.
3. Cleaner foundation for later effects, control operators, or instrumentation.

Costs for Lithic:
1. More moving parts and steeper implementation complexity early.
2. Higher initial verbosity in both code and tests.
3. Slower first delivery than a direct closure evaluator.

### 14.3 Decision Guidance for Phase 8

Choose **Big-Step Closure** first if:
1. Primary short-term goal is a working evaluator quickly.
2. You accept adding a separate trace layer later.
3. You commit to documenting correspondence with §8 rules.

Choose **Small-Step CEK** first if:
1. Primary short-term goal is semantic transparency and educational stepping.
2. You want implementation and formal artifact to align one-to-one now.
3. You plan to emphasize trace-driven REPL features in Phase 9.

Recommended default for this project's stated goals (rigor + education):
1. Keep this document as the normative small-step specification.
2. Prefer CEK-style implementation when schedule allows.
3. If starting with big-step for delivery speed, explicitly mark it as a
   refinement implementation and add regression tests that witness alignment
   with selected small-step examples from §8.
