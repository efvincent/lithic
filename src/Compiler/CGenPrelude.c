#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <limits.h>
#include <sys/types.h>

/*
 * Lithic Phase 10 C backend runtime prelude.
 *
 * This file defines the first-pass runtime carrier layout and helper ABI used
 * by generated C from Compiler.CGen.
 *
 * ABI contract:
 * - Helpers consume/produce intptr_t "value handles".
 * - 0 is treated as a null/failure/missing sentinel.
 * - This slice intentionally uses malloc-and-leak semantics; ownership and
 *   reclamation are deferred to later phases.
 *
 * Safety model (first pass):
 * - Runtime carriers embed a kind discriminator.
 * - Access helpers validate kind before field access.
 * - Record key 0 is reserved as an empty-slot sentinel.
 */

/* Runtime kind tags for discriminator checks. */
enum {
  LITHIC_KIND_VARIANT = 1,
  LITHIC_KIND_RECORD = 2
};

/*
 * Boxed variant carrier.
 *
 * kind: must be LITHIC_KIND_VARIANT.
 * tag:  constructor/tag identifier emitted by cgenVariantTag.
 * payload: opaque intptr_t payload value.
 */
typedef struct {
  intptr_t kind;
  intptr_t tag;
  intptr_t payload;
} lithic_variant_t;

/* One record slot in the structural record carrier. */
typedef struct {
  intptr_t key;
  intptr_t value;
} lithic_record_field_t;

/*
 * Boxed structural record carrier.
 *
 * kind: must be LITHIC_KIND_RECORD.
 * field_count: number of allocated field slots.
 * fields: flexible array of key/value slots.
 */
typedef struct {
  intptr_t kind;
  intptr_t field_count;
  lithic_record_field_t fields[];
} lithic_record_t;

/*
 * Helper-contract guards for value/tag/key/count assumptions.
 *
 * Contract intent:
 * - Tags and record keys emitted by CGen are strictly positive.
 * - Record counts must remain representable and allocation-safe.
 * - Invalid values fail closed before helper internals dereference/iterate.
 */
static inline bool lithic_tag_is_valid(intptr_t tag) {
  return tag > (intptr_t)0;
}

static inline bool lithic_record_key_is_valid(intptr_t key) {
  return key > (intptr_t)0;
}

static inline bool lithic_record_count_is_valid(intptr_t field_count) {
  if (field_count < (intptr_t)0) {
    return false;
  }

  size_t count = (size_t)field_count;
  size_t max_count = (SIZE_MAX - offsetof(lithic_record_t, fields)) / sizeof(lithic_record_field_t);
  return count <= max_count;
}

/*
 * Boxed-handle registry (Phase 10 safety hardening).
 *
 * Why this exists:
 * - Current runtime ABI passes values as intptr_t handles.
 * - For boxed values, non-zero handles are expected to be addresses returned
 *   by lithic_*_make helpers in this translation unit.
 * - Before this change, helper accessors could cast and dereference any non-zero
 *   intptr_t, which is unsafe for malformed non-pointer inputs.
 *
 * Contract:
 * - Each successful boxed allocation registers its address.
 * - Access helpers must verify registration before dereference.
 * - Unknown non-zero handles fail closed by returning 0.
 * - Access helpers validate registration and kind before field access.
 *
 * Scope and limitations:
 * - This registry is process-local and append-only in Phase 10.
 * - Memory is intentionally not reclaimed yet (consistent with current
 *   malloc-and-leak ownership model).
 * - Concurrency is intentionally out of scope for this phase.
 */
typedef struct lithic_box_addr_node {
  uintptr_t addr;
  struct lithic_box_addr_node *next;
} lithic_box_addr_node;

static lithic_box_addr_node *lithic_box_addr_head = NULL;

/*
 * Register a freshly allocated boxed address.
 * False means the registry node allocation failed.
 *
 * The helper stores raw uintptr_t addresses rather than void* so callers can
 * pass the allocation result without tripping spurious maybe-uninitialized
 * warnings under -Werror on some GCC versions.
 */
static inline bool lithic_box_addr_register(uintptr_t addr) {
  lithic_box_addr_node *node = (lithic_box_addr_node *)malloc(sizeof(lithic_box_addr_node));
  if (node == NULL) {
    return false;
  }
  node->addr = addr;
  node->next = lithic_box_addr_head;
  lithic_box_addr_head = node;
  return true;
}

/* True only for non-zero handles produced by registered boxed allocations. */
static inline bool lithic_box_addr_contains(intptr_t handle) {
  if (handle == (intptr_t)0) { 
    return false;
  }
  uintptr_t addr = (uintptr_t)handle;
  for (const lithic_box_addr_node *it = lithic_box_addr_head; it != NULL; it = it->next) {
    if (it->addr == addr) {
      return true;
    }
  }
  return false;
}

/*
 * Decode and validate a variant handle.
 * Returns NULL for unknown handles and kind mismatches.
 */
static inline const lithic_variant_t *lithic_variant_from_handle(intptr_t variant) {
  if (!lithic_box_addr_contains(variant)) {
    return NULL;
  }
  const lithic_variant_t *v = (const lithic_variant_t *)(uintptr_t)variant;
  if (v->kind != (intptr_t)LITHIC_KIND_VARIANT) {
    return NULL;
  }
  return v;
}

/*
 * Decode and validate a mutable record handle.
 * Returns NULL for unknown handles and kind mismatches.
 */
static inline lithic_record_t *lithic_record_mut_from_handle(intptr_t record) {
  if (!lithic_box_addr_contains(record)) {
    return NULL;
  }
  lithic_record_t *r = (lithic_record_t *)(uintptr_t)record;
  if (r->kind != (intptr_t)LITHIC_KIND_RECORD) {
    return NULL;
  }
  return r;
}

/*
 * Decode and validate a const record handle.
 * Returns NULL for unknown handles and kind mismatches 
 */
static inline const lithic_record_t *lithic_record_from_handle(intptr_t record) {
  if (!lithic_box_addr_contains(record)) {
    return NULL;
  }
  const lithic_record_t *r = (const lithic_record_t *)(uintptr_t)record;
  if (r->kind != (intptr_t)LITHIC_KIND_RECORD) {
    return NULL;
  }
  return r;
}

/*
 * Allocate and initialize a variant carrier.
 *
 * Safety contract:
 * - Registers the boxed address before exposing the handle.
 * - Returns 0 on allocation or registry failure.
 */
static inline intptr_t lithic_variant_make(intptr_t tag, intptr_t payload) {
  if (!lithic_tag_is_valid(tag)) {
    return (intptr_t)0;
  }

  lithic_variant_t *v = (lithic_variant_t *)malloc(sizeof(lithic_variant_t));
  if (v == NULL) {
    return (intptr_t)0;
  }
  if (!lithic_box_addr_register((uintptr_t)v)) {
    free(v);
    return (intptr_t)0;
  }
  v->kind = (intptr_t)LITHIC_KIND_VARIANT;
  v->tag = tag;
  v->payload = payload;
  return (intptr_t)(uintptr_t)v;
}

/*
 * Read the variant tag from a validated boxed variant handle.
 * Returns 0 for null, unknown, or non-variant handles.
 */
static inline intptr_t lithic_variant_tag(intptr_t variant) {
  const lithic_variant_t *v = lithic_variant_from_handle(variant);
  if (v == NULL) {
    return (intptr_t)0;
  }
  if (!lithic_tag_is_valid(v->tag)) {
    return (intptr_t)0;
  }
  return v->tag;
}

/*
 * Read the variant payload from a validated boxed variant handle.
 * Returns 0 for null, unknown, or non-variant handles.
 */
static inline intptr_t lithic_variant_payload(intptr_t variant) {
  const lithic_variant_t *v = lithic_variant_from_handle(variant);
  if (v == NULL) {
    return (intptr_t)0;
  }
  return v->payload;
}

/*
 * Insert or update a record key/value slot.
 *
 * Behavior:
 * - Rejects null/non-record handles and invalid field_count.
 * - Rejects non-positive field keys.
 * - Updates existing key if present.
 * - Otherwise fills first empty slot.
 * - If no slot is available, fails closed.
 *
 * Returns:
 * - The original record handle on success.
 * - 0 on invalid input or insertion failure.
 */
static inline intptr_t lithic_record_set(intptr_t record, intptr_t field, intptr_t value) {
  lithic_record_t *r = lithic_record_mut_from_handle(record);
  if (r == NULL) {
    return (intptr_t)0;
  }

  if (!lithic_record_count_is_valid(r->field_count)) {
    return (intptr_t)0;
  }

  if (!lithic_record_key_is_valid(field)) {
    return (intptr_t)0;
  }

  size_t count = (size_t)r->field_count;

  for (size_t i = 0; i < count; i++) {
    if (r->fields[i].key == field) {
      r->fields[i].value = value;
      return record;
    }
  }

  for (size_t i = 0; i < count; i++) {
    if (r->fields[i].key == (intptr_t)0) {
      r->fields[i].key = field;
      r->fields[i].value = value;
      return record;
    }
  }

  /* No existing key and no empty slot: fail closed. */
  return (intptr_t)0;
}

/*
 * Allocate and initialize a boxed structural record.
 *
 * Safety contract:
 * - Registers the boxed address before exposing the handle.
 * - Returns 0 on invalid count, overflow guard, allocation failure,
 *   or registry failure.
 */
static inline intptr_t lithic_record_make(intptr_t field_count) {
  if (!lithic_record_count_is_valid(field_count)) {
    return (intptr_t)0;
  }

  size_t count = (size_t)field_count;
  size_t bytes = sizeof(lithic_record_t) + count * sizeof(lithic_record_field_t);
  lithic_record_t *r = (lithic_record_t *)malloc(bytes);
  if (r == NULL) {
    return (intptr_t)0;
  }

  if (!lithic_box_addr_register((uintptr_t)r)) {
    free(r);
    return (intptr_t)0;
  }

  r->kind = (intptr_t)LITHIC_KIND_RECORD;
  r->field_count = field_count;
  for (size_t i = 0; i < count; i++) {
    r->fields[i].key = (intptr_t)0;
    r->fields[i].value = (intptr_t)0;
  }

  return (intptr_t)(uintptr_t)r;
}

/*
 * Select a value by key from a boxed structural record.
 * Returns 0 for null/mismatched/invalid records or missing key.
 */
static inline intptr_t lithic_record_select(intptr_t record, intptr_t field) {
  const lithic_record_t *r = lithic_record_from_handle(record);
  if (r == NULL) {
    return (intptr_t)0;
  }

  if (!lithic_record_count_is_valid(r->field_count)) {
    return (intptr_t)0;
  }

  if (!lithic_record_key_is_valid(field)) {
    return (intptr_t)0;
  }

  size_t count = (size_t)r->field_count;
  for (size_t i = 0; i < count; i++) {
    if (r->fields[i].key == field) {
      return r->fields[i].value;
    }
  }

  return (intptr_t)0;
}

/*
 * Builtin: print
 *
 * Treats the incoming intptr_t as a C string pointer, writes it to stdout,
 * and returns the original handle.
 */
static inline intptr_t lithic_builtin_print(intptr_t value) {
  if (value == (intptr_t)0) {
    return (intptr_t)0;
  }
  const char *s = (const char *)(uintptr_t)value;
  fputs(s, stdout);
  fflush(stdout);
  return value;
}

/*
 * Builtin: readLn
 *
 * Reads a single line from stdin, stopping on `\r` or `\n`.
 * Returns a heap-allocated NUL-terminated string handle, or 0 on EOF/failure.
 */
static inline intptr_t lithic_builtin_readln(void) {
  size_t cap = 128;
  char *buf = (char *)malloc(cap);
  if (buf == NULL) {
    return (intptr_t)0;
  }

  size_t len = 0;
  int ch;
  while ((ch = fgetc(stdin)) != EOF) {
    if (ch == '\n' || ch == '\r') {
      break;
    }

    if (len + 1 >= cap) {
      size_t nextCap = cap * 2;
      char *grown = (char *)realloc(buf, nextCap);
      if (grown == NULL) {
        free(buf);
        return (intptr_t)0;
      }
      buf = grown;
      cap = nextCap;
    }
    buf[len++] = (char)ch;
  }

  if (ch == '\r') {
    int next = fgetc(stdin);
    if (next != '\n' && next != EOF) {
      ungetc(next, stdin);
    }
  }

  if (ch == EOF && len == 0) {
    free(buf);
    return (intptr_t)0;
  }

  buf[len] = '\0';
  return (intptr_t)(uintptr_t)buf;
}

/* Marker helper used by unsupported generated paths in scaffold stages. */
static inline void lithic_unsupported_fn(intptr_t arg) {
  (void)arg;
}