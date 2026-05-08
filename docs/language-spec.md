# Lithic Language Specification (Living Core Spec)

Status: Active living spec for implemented behavior.
Version: 0.3 (2026-05-08)
Scope baseline: Parser + current bidirectional checker through Phase 7.

This document is the normative source for the currently implemented Lithic surface language and static semantics. Where implementation and docs disagree, this spec is the authority to reconcile against.

## 1. Purpose and Governance

### 1.1 Purpose

Lithic is still in rapid language evolution phases. A complete formal report at this stage would incur frequent churn. This living core spec defines the stable implemented core needed to prevent semantic drift while Phase 7 (pattern exhaustiveness and reachability) is under active development.

Post-Phase-7 checkpoint note:
The formalization checkpoint for pattern coverage/reachability and specification boundaries has been completed in this revision.

### 1.2 Normative Status

Normative for:
- Lexical forms currently accepted by the lexer.
- Concrete syntax currently accepted by the parser.
- Pratt precedence and associativity behavior.
- Static typing behavior currently enforced by the bidirectional checker.
- Error-class contracts and source-span expectations.

Informative only for:
- Future evaluator/runtime semantics (baseline direction: strict, small-step; full formalization still in progress).
- Future elaboration/core lowering semantics.
- Future constraint solving and capability overloading semantics.

Current evaluator draft reference:
- `docs/evaluator-small-step.md` (Phase 8 formal artifact draft).

### 1.3 Change Policy (Anti-Drift)

Any change to lexer/parser/typechecker-observable behavior MUST update this spec in the same change.

Expected synchronization targets:
1. This file (`docs/language-spec.md`) (normative behavior).
2. `README.md` (user-facing summary/examples).
3. `docs/project-plan.md` and `.github/copilot-instructions.md` when roadmap scope or grammar commitments change.
4. Golden fixtures/snapshots in `test/fixtures` and `test/golden` for behavioral deltas.

### 1.4 Stability Labels

Each section is one of:
- Stable: intended to remain source-compatible during Phase 7.
- Provisional: implemented but likely to evolve before full formalization.
- Reserved: syntax/semantics intentionally not implemented yet.

### 1.5 Implemented vs Planned Semantics Split

Normative implemented semantics (this revision):
1. Surface syntax accepted by lexer/parser.
2. Bidirectional static semantics through current `infer`/`check`/`subsumes` pipeline.
3. Case-branch exhaustiveness and redundancy coverage semantics.
4. REPL diagnostic envelope and span-locality contracts.

Planned/informative semantics (non-normative in this revision):
1. Evaluator operational semantics and value model.
2. Minimal Core AST design and Surface-to-Core elaboration algorithm.
3. Macro expansion/desugaring ordering constraints (parse -> expand -> elaborate).
4. Capability/type-class solving coherence model.
5. Declaration-group semantics for function equations and guards.

## 2. Lexical Specification (Stable unless noted)

### 2.1 Identifier Classes

- Lowercase identifiers: `TokIdent`.
- Uppercase identifiers: `TokUIdent`.

Current role split:
- Term level: lowercase variables and uppercase variant constructors are accepted.
- Type level: lowercase type variables and uppercase concrete/nominal type names are accepted.

### 2.2 Keywords and Core Delimiters

The lexer recognizes the following core keywords/symbols used by the implemented grammar:

- `let`, `def`, `in`
- `case`, `of`
- `forall`
- `True`, `False`
- `\\`, `fn` (lambda introducers)
- `=>` (term-level lambda and case branch delimiter)
- `->` (type-level function arrow)
- `:` (type annotation)
- `=` (binding/field assignment)
- `.` (selection/path separator)
- `{`, `}`, `(`, `)`, `,`, `|`
- `:=` (lens set)
- `%=` (lens modify)
- `-` (prefix unary minus and infix subtraction)

Reserved (not currently implemented):
- Function-equation clause heads (for example, `name pat1 pat2 = expr`).
- Guarded declaration bars (for example, `| guard => expr`).

### 2.3 Literals

Supported literal token families:
- Integer literals.
- Floating-point literals.
- String literals (single-line quoted).
- Boolean literals (`True`, `False`).

### 2.4 Comments

Line comments are supported with `--` through end-of-line.

### 2.5 Source Location Contract

Every emitted token carries a `SourceSpan` and downstream parse/type diagnostics preserve source-location reporting.

## 3. Surface Grammar (Core, with Stability Labels)

Notation is EBNF-like and descriptive for implemented behavior.

### 3.1 Expressions (Stable core, some Provisional branches)

```text
Expr ::= LetExpr
       | LamExpr
       | CaseExpr
       | AnnExpr

LetExpr ::= "let" Pattern [":" Type] "=" Expr "in" Expr
LamExpr ::= "\\" Pattern [":" Type] "=>" Expr
CaseExpr ::= "case" Expr "of" Branch+
Branch ::= "|" Pattern "=>" Expr

AnnExpr ::= SubExpr [":" Type]

SubExpr ::= SubExpr "-" AppExpr              // infix subtraction
          | AppExpr

AppExpr ::= AppExpr Atom                      // implicit application
          | SelectExpr

SelectExpr ::= Primary "." ident             // record selection
             | Primary ".{" Path UpdateOp Expr "}"  // lens update
             | Primary

Path ::= ident ("." ident)*
UpdateOp ::= ":=" | "%="

Primary ::= ident
          | UIdent Expr                       // variant constructor application
          | Literal
          | "-" Primary                      // unary minus
          | "(" Expr ")"
          | RecordExpr

RecordExpr ::= "{}"
             | "{" FieldList "}"
FieldList ::= Field ("," Field)* ["|" Expr]
Field ::= label "=" Expr
```

Notes:
1. `UIdent Expr` payloads are currently required; nullary constructors are represented with an explicit empty-record payload (for example, `None {}`).
2. Record labels in row-like forms may be lowercase or uppercase at parser level.
3. `fn` and `\\` both tokenize to `TokLam` and are accepted as lambda introducers.

### 3.4 Declaration Forms (Reserved)

Current parser entrypoint status:
1. `runParser` remains expression-oriented.
2. `parseTopLevel` supports a minimal declaration form: `def Pattern = Expr`.
3. Declaration groups, signatures, guards, and function equations remain reserved roadmap syntax.

Status table for planned declaration forms:

| Form | Target Syntax | Implementation Status | Notes |
| --- | --- | --- | --- |
| Minimal top-level def declaration | `def pat = expr` | Implemented (parseTopLevel only) | Requires EOF after declaration; not yet threaded through REPL evaluation environment. |
| Function equation (single clause) | `f p1 ... pn = expr` | Not implemented yet | Will parse as a declaration clause, not an expression form. |
| Function equation (multi clause) | repeated `f ... = ...` clauses | Not implemented yet | Clauses will be grouped by function name into one declaration unit. |
| Guarded clause | `f p1 ... pn` then `| guard => expr` lines | Not implemented yet | Guard RHS uses fat arrow to remain consistent with term-level branch delimiters. |
| Pattern-headed clause | `f <pattern> ... = expr` | Not implemented yet | Will lower through the same match-analysis pipeline as `case`. |

```text
TopLevel ::= Decl | Expr

Decl ::= "def" Pattern "=" Expr
       | ident Pattern* "=" Expr
       | ident Pattern* GuardedRhs+

GuardedRhs ::= "|" GuardExpr "=>" Expr
GuardExpr ::= Expr
```

Examples (target surface syntax):

```haskell
isOdd n
       | n % 2 == 0 => False
       | otherwise => True
```

```haskell
isEmpty [] = True
isEmpty _ = False
```

Planned elaboration model:
1. Group clauses by function name.
2. Lower grouped equations to a single lambda/case decision tree.
3. Reuse pattern coverage machinery for exhaustiveness and redundancy reporting.

### 3.2 Patterns (Provisional for exhaustiveness details)

```text
Pattern ::= "_"
          | ident
          | Literal
          | UIdent Pattern
          | RecordPattern

RecordPattern ::= "{" ... "}"            // AST includes PRecord; parser coverage is partial/in-progress.
```

Implemented pattern spaces used by binder positions and `case` branches:
- Variable pattern.
- Wildcard pattern.
- Literal pattern.
- Variant pattern with payload pattern.

Record patterns exist in AST/typechecker shape but parser support remains partial; this is Provisional.

### 3.3 Types (Stable core)

```text
Type ::= TypeAtom ["->" Type]               // right-associative

TypeAtom ::= ident                            // type variable
           | UIdent                           // nominal or primitive name
           | "forall" ident+ "." Type
           | "{" RowType "}"
           | "(" Type ")"

RowType ::= "}"
          | label ":" Type ("," label ":" Type)* ["|" Type] "}"
```

Primitive names with dedicated type AST nodes:
- `Int`, `Float`, `String`, `Bool`.

Wrappers:
- `Record <row-type>` represented as `TRecord` over row kind.
- `Variant <row-type>` represented as `TVariant` over row kind.

## 4. Precedence and Associativity (Stable)

Current Pratt precedence table (high to low):
1. Selection / lens prefix after dot (`.`): precedence 40.
2. Prefix unary minus: precedence 35.
3. Implicit application: precedence 30.
4. Infix subtraction: precedence 10.
5. Type annotation (`:`): precedence 5.
6. Base expression level: precedence 0.

Operational notes:
- Type annotation binds lower than application, so `f x : T` parses as `(f x) : T`.
- Dot selection binds tighter than application, so `f r.x` parses as `f (r.x)`.
- Let RHS and lambda body parse at lowest precedence to capture full expression forms.

## 5. Static Semantics (Implemented Core)

### 5.1 Typechecking Architecture (Stable)

Lithic uses bidirectional typing:
- `infer`: synthesizes type from expression structure.
- `check`: validates expression against expected type.

When direct checking is not shape-driven, checker falls back to infer + `subsumes`.

### 5.2 Subsumption / Rank-2 Bridge (Stable with planned extension)

Current `subsumes` routing:
1. Expected polymorphic type (`forall`) is skolemized.
2. Inferred polymorphic type (`forall`) is instantiated with fresh metas.
3. Arrow-vs-arrow uses contravariant domain + covariant codomain subsumption.
4. Otherwise fallback to structural unification.

### 5.3 Stateful Unification (Stable)

- Meta-variables (`TMeta`) are solved through a mutable substitution map in `TCState`.
- `force` performs shallow head normalization for meta chains.
- `zonk` performs deep finalization for user-visible types.
- Occurs check rejects infinite types.

### 5.4 Let-Polymorphism (Stable)

- Let-bound values are inferred.
- Inferred type is generalized to `forall` over free metas not present in environment.
- Lookup instantiates generalized bindings to fresh metas.

### 5.5 Records, Rows, and Lens Updates (Stable structural mode; nominal mode Provisional)

Structural mode:
- Records use row-polymorphic types (`TRowEmpty`, `TRowExtend`, wrapped by `TRecord`).
- Row unification is label-order insensitive.
- Field selection can expand open row metas as needed.

Lens updates:
- `record.{path := value}` requires `value` unifies with resolved field type.
- `record.{path %= f}` requires `f` unifies with `fieldTy -> fieldTy`.
- Expression result type is the original record type.

Nominal path resolution is intentionally stubbed for now and reports targeted type errors.

### 5.6 Variants and Pattern-Driven Environments (Stable core, Stable case-branch coverage)

- Variant terms are typed through `TVariant` over row types.
- Pattern checking extends local environments for branch/body checking.
- Case branch result types must reconcile via checker constraints.

Current implemented Phase-7 boundary:
- Exhaustiveness is enforced for both finite and open constructor universes.
- Redundancy (unreachable-branch) errors are enforced for both finite and open constructor universes.
- For open literal/open variant spaces, usefulness and redundancy rely on exact observed literal/constructor heads plus wildcard/default decomposition rather than total-domain enumeration.

Current deferred scope:
- Guard-aware usefulness semantics.
- Exhaustiveness/redundancy checks for grouped function-equation clauses.
- Exhaustiveness/redundancy checks for binder patterns in `let` and lambda parameters.

### 5.7 Numeric Operators (Stable current policy, Provisional long-term model)

Current behavior:
- Unary minus and subtraction are primitive numeric operations over `Int`/`Float`.
- Concrete numeric context constrains unresolved metas where possible.
- Fully unresolved numeric arithmetic emits explicit ambiguity diagnostics.

Planned replacement:
- Constraint-driven capability predicates and evidence passing (future phase).

## 6. Error and Diagnostic Contracts (Stable)

Current REPL-visible categories:
- Lex error: `Lex Error: <msg>`
- Parse error: `Parse Error: <msg>`
- Type error: `Type Error: <msg> at <span>`

Contract requirements:
1. Diagnostics carry precise `SourceSpan` whenever an originating token/node exists.
2. Parser and checker should prefer targeted spans over coarse enclosing spans.
3. Changes to diagnostic formatting visible in REPL output require README/spec sync.

## 7. Out of Scope for This Living Core Spec

Explicitly deferred to later formalization:
- Full dynamic semantics specification and proof obligations for the strict, small-step evaluator baseline.
- Core language translation/elaboration judgments.
- Macro expansion semantics and hygiene model.
- Full constraint solver coherence proof/model.
- Full mechanized proof obligations for the pattern matrix algorithm.
- Full declaration-group parsing and function-equation formal semantics.

## 8. Post-Phase-7 Formalization Checkpoint (Completed)

During Phase 7, this living spec remains the anti-drift authority for implemented behavior.

Checkpoint outcomes now captured in this document:
1. Formal pattern matrix objects and coverage/redundancy judgments are normative in Section 9.
2. A stricter Surface/Core boundary statement is provided in Section 10.
3. A clear implemented-vs-planned semantics split is defined in Section 1.5.

## 9. Phase-7 Addendum (Maranget Matrix)

Status: Normative for implemented `case`-branch exhaustiveness/redundancy behavior.

### 9.1 Scope and Activation

Covered constructs:
1. `case` branch sets only.

Deferred to follow-up phase work:
1. Exhaustiveness/redundancy checks for binder patterns in `let` and lambda parameters.
2. Guard-aware usefulness semantics.
3. Exhaustiveness/redundancy checks for grouped function-equation clauses.

Diagnostic level:
1. Hard type errors (reject program).

Activation:
1. Enabled in the release containing `Compiler.PatternMatch` integration in `infer` for `Case` nodes.

### 9.2 Pattern Matrix Core Objects

Core representation:

```text
Occurrence o ::= Root
               | VariantPayload(o, ctor)
               | RecordField(o, label)

Row r ::= [Pattern]
Matrix P ::= [Row]
Query q ::= [Pattern]
```

Initial constructor universe policy:
1. Literal domains:
       - `Bool` is finite: `{True, False}`.
       - `Int`, `Float`, and `String` are treated as effectively open/infinite for coverage; only observed literal heads participate in specialization, with default branch required for totality.
       - Literal-head usefulness/redundancy for open or infinite domains is based on exact head equality of observed literals (for example `Ok "success"`), plus wildcard/default decomposition.
       - This does not require global enumeration of every literal value in the domain.
2. Variants (`TVariant` over row):
       - Constructors are enumerated from statically known row labels when row is closed enough after forcing/zonking.
       - If variant row remains open/unknown, algorithm may not claim totality from constructor enumeration alone; default/wildcard coverage is required.
       - Open-row universes participate in both exhaustiveness and redundancy through default/wildcard decomposition.
3. Record patterns:
       - Kept provisional until parser support for `PRecord` is complete.

Normalization policy:
1. `PVar` and `PWildcard` are treated as wildcard heads in matrix algorithms.
2. `PVariant ctor p` contributes constructor head `ctor` and one payload sub-column when specialized.
3. `PLit lit` contributes literal constructor head for specialization in that column.

### 9.3 Specialization and Default Operations

Operators:

```text
specialize(P, c) -> P_c
default(P) -> P_d
```

Semantics:
1. `specialize(P, c)` keeps rows whose head can match constructor/literal `c`:
       - Exact head `c`: include row, replacing head by constructor arguments (for `PVariant`, one payload pattern).
       - Wild head (`PVar`/`PWildcard`): include row, introducing fresh wildcard argument patterns matching `c` arity.
       - Any other concrete head: drop row.
2. `default(P)` keeps rows with wildcard-compatible heads (`PVar`, `PWildcard`) and removes that head column.
3. Column ordering is preserved by replacing the selected head with its argument subpatterns, then appending remaining original columns.

Operational judgment sketch:
1. `specialize([], c) = []`.
2. `specialize((h : t) : rows, c)` includes `args ++ t` when `h` matches `c` and contributes `args`; otherwise drops row.
3. Wild heads contribute constructor-arity wildcards to `args`.

### 9.4 Exhaustiveness Judgment

Judgment shape:

```text
Exhaustive(T, P) => Covered | Missing(W)
```

Where:
1. `T` is the scrutinee type after forcing current substitutions.
2. `P` is the matrix built from branch patterns.
3. `W` is a non-empty ordered list of witness patterns not covered by `P`.

Witness policy:
1. Witnesses are rendered as surface-like patterns (for example `True`, `Err _`, `Ok (Err _)`).
2. Ordering is deterministic by:
       - Constructor/literal order from row label iteration and literal sort order.
       - Left-to-right traversal of matrix columns.
3. Cap witness emission to a small fixed bound (for example 3) to keep diagnostics readable.

Recursive missing-row sketch:
1. `missing([], P) = Just []` iff `P` is empty, else `Nothing`.
2. For finite universes, recurse by constructor specialization and reconstruct witness heads.
3. For open universes, recurse through `default(P)` and prepend wildcard witness at that column.

### 9.5 Reachability / Redundancy Judgment

Usefulness judgment:

```text
Useful(P_prefix, r) => Useful | Redundant
```

Semantics:
1. A branch row `r` is redundant iff it is not useful relative to previously accepted rows `P_prefix`.
2. Redundancy check runs in source order for each case branch.
3. In Phase 7 target behavior, every redundant branch is reported as an error; multi-branch reporting is preferred if diagnostics accumulation remains practical.
4. Open-universe rows participate in redundancy through default/wildcard decomposition and constructor/payload projection; finite-universe enumeration is only required where domains are statically finite.
5. Capability/type-class resolution for operators is orthogonal to pattern usefulness: overloaded numeric operators do not change literal-pattern head matching semantics.

Recursive usefulness sketch:
1. `useful([], P, [])` iff `P` is empty.
2. Wild query heads branch over finite constructors or recurse via `default(P)` for open universes.
3. Constructor/literal heads recurse through `specialize(P, c)` with constructor arguments pushed into the query row.

Guard policy:
1. Pattern guards are not part of Phase 7 enforcement; this judgment applies to unguarded branch sets only.

### 9.6 Diagnostic Contract Addendum

User-visible errors:

```text
Type Error: Non-exhaustive patterns in case at <span>. Missing: <w1>, <w2>, ...
Type Error: Unreachable pattern branch at <span>
```

Span policy:
1. Non-exhaustive error span points at the `case` expression span.
2. Unreachable error span points at the redundant branch pattern span.

Emission policy:
1. If both kinds are present, prioritize unreachable diagnostics first when branch-local spans are available, then non-exhaustive summary.
2. If checker remains fail-fast, at least first deterministic diagnostic must be stable across runs.

### 9.7 Golden Test Obligations

Phase-7 merge gate expects fixtures for at least:
1. Exhaustive boolean case success.
2. Non-exhaustive boolean case failure with missing witness.
3. Redundant wildcard-after-wildcard branch failure.
4. Variant non-exhaustive failure with constructor witness (closed row case).
5. Nested variant redundancy or missing-case witness.

Expected output contract for failures:
1. Preserve existing `Type Error: <msg> at <span>` envelope.
2. Include witness text for non-exhaustive failures.

### 9.8 Implementation Cross-References

Modules and touch points:
1. New module: `src/Compiler/PatternMatch.hs`.
2. Typechecker integration: `infer` path for `Case` in `src/Compiler/TypeChecker.hs`.
3. Pipeline visibility: golden harness in `test/Main.hs` through existing REPL/type error formatting path.

Companion docs to update in same implementation change:
1. `README.md` examples/behavior bullets for exhaustiveness and unreachable branches.
2. `docs/project-plan.md` Phase 7 checklist status.
3. `CHANGELOG.md` release entry with diagnostics behavior details.

## 10. Surface-to-Core Boundary and Elaboration Relation

### 10.1 Current Implemented Boundary (Normative)

1. Parser output is `SurfaceExpr` only.
2. Typechecker consumes `SurfaceExpr` directly; there is no standalone Core IR boundary in the current execution path.
3. Pattern coverage machinery analyzes `SurfaceExpr` case branches directly.

### 10.2 Planned Elaboration Relation (Informative)

Future compiler architecture will introduce an explicit elaboration judgment:

```text
Gamma |- e_surface ~> e_core
Gamma |- t_surface ~> t_core
```

Boundary commitments for that phase:
1. Surface syntax remains parser-owned and frontend facing.
2. Core syntax remains evaluator/backend owned and intentionally smaller.
3. Coverage/type diagnostics must retain source-span provenance from surface nodes through elaboration.
