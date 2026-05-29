# Phase 10 C3.8 Prep: Zero-Arg Main as Executable Entrypoint

Status: Implemented on the C3.8 branch; kept as the design and validation note
for this slice.

## Goal

Make a Lithic source file that defines a zero-argument `main` produce a complete
native executable path without requiring an external C harness.

The immediate user-facing target is:

```haskell
def main =
  let input = readLn in
  print input
```

Running `--emit-c` on that file should emit generated C containing both:

1. a callable `lithic_main(void)` helper that lowers the Lithic body, and
2. a C `int main(void)` wrapper that invokes `lithic_main()` and returns `0`.

## Why This Slice Exists

C3.7 added first-pass `print` and `readLn` builtins and can generate a C
`main(void)` wrapper when a zero-argument Lithic `main` declaration exists.
However, complex zero-argument declarations still travel through expression-value
lowering. That path is intentionally narrow and currently falls back for nested
forms such as `let` and `case`.

The showcase therefore needed an external C harness around a one-argument
`lithic_main(int64_t seed)`. That is not acceptable as the ordinary executable
story.

## Design Decision

Do not introduce `Unit` / `()` yet in this slice.

A proper `main : Unit -> Unit`, `main : Unit`, or later `main : IO Unit` design is
the right long-term language direction, but adding real Unit now would touch the
surface AST, parser, typechecker, elaborator, evaluator, CGen, docs, and tests.
That is too broad for this follow-up.

For C3.8, use the syntax that is already implemented:

```haskell
def main = expr
```

and make CGen lower helper-backed zero-argument declarations through the existing
statement-level body lowering path instead of the weaker expression-value path.

## Expected Lowering Shape

For a non-static zero-argument declaration:

```haskell
def name = expr
```

CGen should emit a zero-argument C function:

```c
<retTy> lithic_name(void) {
  <statement-level lowering for expr>
}
```

For `name == "main"`, `cgenProgram` should additionally emit:

```c
int main(void) {
  (void)lithic_main();
  return 0;
}
```

This preserves the current wrapper strategy while making `lithic_main(void)`
capable of lowering nested `let`, `case`, builtin calls, arithmetic, records, and
other statement-level forms already supported by `cgenFunctionBodyScoped`.

## Implemented Source Change

Primary target: `src/Compiler/CGen.hs`.

In the `DeclConstant body` branch of `cgenDecl`:

1. Keep the static-initializer path unchanged for non-`main` literals.
2. For non-static constants, emit the zero-argument function body using
   `cgenFunctionBodyScoped [] valTy body`, not `cgenExprValueAs valTy body`.
3. Avoid generating `return $fBody;` around statement-level output; the statement
   lowering already emits returns.

Conceptual shape:

```haskell
DeclConstant body ->
  let valTy = maybe "intptr_t" cgenCType mTy
      fName = cFunctionName name
  in TB.fromText $
    if name /= "main" && isStaticCInitializer body
    then ... existing static initializer path ...
    else
      let fBody = cgenFunctionBodyScoped [] valTy body
      in blks [c|
      /* definition: $name */
      $valTy $fName(void) {
        $fBody
      } |]
```

The implementation keeps the source change scoped to this `DeclConstant` case.
Static non-`main` constants still use `cgenExprValueAs` for file-scope C
initializers; non-static zero-argument declarations now use
`cgenFunctionBodyScoped [] valTy body` and splice the resulting statement body
directly into the generated function.

## Implementation Result

The target source now works as the ordinary first-pass executable entrypoint:

```haskell
def main =
  let input = readLn in
  print input
```

`--emit-c` emits `const char* lithic_main(void)` plus `int main(void)`, and the
generated C can be compiled, linked, and run without an external harness.

## Test Plan

Implemented tests/docs after the source patch:

1. Add a CGen unit test for a zero-argument `main` with nested `let` and `print`:
   - generated C includes `const char* lithic_main(void)`,
   - generated C includes `int main(void)`,
   - generated C includes `lithic_builtin_print`,
   - generated C does not include `unsupported-rhs:CLet`,
   - generated C compiles with `gcc -std=c11 -Wall -Wextra -Werror -c`.
2. Add a CLI `--emit-c` integration test using a temp source like:

   ```haskell
   def main =
     let input = readLn in
     print input
   ```

  Assert that emitted C compiles and links without an external harness, then
  run the executable with stdin.
3. The active showcase can now be updated to:

   ```haskell
   def main =
     let input = readLn in
     print input
   ```

   Then verify:

   ```bash
   cabal run lithic-cli -- --emit-c tmp/current-c-backend-showcase.lithic -o tmp/showcase.c
   gcc -std=c11 -Wall -Wextra -Werror tmp/showcase.c -o tmp/showcase
   printf 'hello from lithic\n' | tmp/showcase
   ```

4. Updated README/spec/CGen docs to say zero-argument `def main = ...` is the
   current executable entrypoint convention for Phase 10.

## Validation Gate

Run:

```bash
cabal test lithic-test --test-options='-p "CGen Unit Tests"'
cabal test lithic-test --test-options='-p "CLI --emit-c Integration"'
cabal test lithic-test
```

Expected full-suite baseline after PR #34 follow-up: 192 passing.

## Deferred Design

After C3.8, revisit a principled entrypoint type once Unit/effects are available:

- `main : Unit`
- `main : Unit -> Unit`
- `main : IO Unit`
- capability/evidence-based terminal effects

Do not invent fake Unit semantics in C3.8 just to make the type prettier.
