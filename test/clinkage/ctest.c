/* The C library of test/clinkage.jl: built natively as a shared library (clang) and for
 * wasm64 (emscripten -m64), the same source, so that the same Julia functions can call it
 * natively and compiled to Wasm, and their results be compared. Each function exercises a
 * part of the C ABI (scalars, pointers, structs by value, results by sret, varargs) or of
 * C memory seen from Julia (static data, globals, the heap). */

#include <stdarg.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef __EMSCRIPTEN__
#include <emscripten.h>
#define EXPORT EMSCRIPTEN_KEEPALIVE
#else
#define EXPORT __attribute__((visibility("default")))
#endif

/* scalars of each width and signedness: small ones come back as an int, so that an argument
 * not extended as its type says shows */
EXPORT int32_t ct_sext8(int8_t x) { return x; }
EXPORT int32_t ct_sext16(int16_t x) { return x; }
EXPORT uint32_t ct_zext8(uint8_t x) { return x; }
EXPORT uint32_t ct_zext16(uint16_t x) { return x; }
EXPORT int8_t ct_neg8(int8_t x) { return (int8_t)-x; }
EXPORT uint8_t ct_inc8(uint8_t x) { return (uint8_t)(x + 1); }
EXPORT int16_t ct_neg16(int16_t x) { return (int16_t)-x; }
EXPORT uint16_t ct_inc16(uint16_t x) { return (uint16_t)(x + 1); }
EXPORT int32_t ct_mul32(int32_t a, int32_t b) { return a * b; }
EXPORT uint32_t ct_xor32(uint32_t a, uint32_t b) { return a ^ b; }
EXPORT int64_t ct_mul64(int64_t a, int64_t b) { return a * b; }
EXPORT uint64_t ct_rot64(uint64_t a, int s) { return (a << s) | (a >> (64 - s)); }
EXPORT float ct_fma32(float a, float b, float c) { return a * b + c; }
EXPORT double ct_div64(double a, double b) { return a / b; }
EXPORT bool ct_not(bool b) { return !b; }
EXPORT int ct_bool_int(bool b) { return b ? 7 : -7; }
EXPORT char ct_upper(char c) { return (c >= 'a' && c <= 'z') ? (char)(c - 32) : c; }
EXPORT long ct_long(long x) { return x - 1; }
EXPORT size_t ct_size(size_t x) { return x * 2; }
/* all of them in one call: the parameters in order */
EXPORT double ct_mix(int8_t a, uint16_t b, int32_t c, int64_t d, float e, double f, bool g, uint8_t h) {
    return a * 1.0 + b * 10.0 + c * 100.0 + (double)d * 1000.0 + e * 0.5 + f * 0.25 + (g ? 3 : 0) + h * 0.125;
}

/* an enum: an int */
enum ct_color { CT_RED = 0, CT_GREEN = 5, CT_BLUE = -3 };
EXPORT enum ct_color ct_next_color(enum ct_color c) {
    return c == CT_RED ? CT_GREEN : c == CT_GREEN ? CT_BLUE : CT_RED;
}

/* pointers to scalars, read and written */
EXPORT void ct_bump_i8(int8_t *p) { *p = (int8_t)(*p * 2 - 1); }
EXPORT void ct_bump_u16(uint16_t *p) { *p = (uint16_t)(*p * 3 + 1); }
EXPORT void ct_bump_i32(int32_t *p) { *p = *p * 3 + 1; }
EXPORT void ct_bump_i64(int64_t *p) { *p = *p * -5 + 2; }
EXPORT void ct_bump_f32(float *p) { *p = *p * 0.5f + 1.0f; }
EXPORT void ct_bump_f64(double *p) { *p = *p * 1.5 - 2.0; }
EXPORT void ct_flip(bool *p) { *p = !*p; }
EXPORT void ct_divmod(int a, int b, int *q, int *r) { *q = a / b; *r = a % b; }

/* arrays: read (sums), written (fills) */
EXPORT double ct_sum_f64(const double *a, size_t n) {
    double s = 0;
    for (size_t i = 0; i < n; i++) s += a[i] * (double)(i + 1);
    return s;
}
EXPORT int64_t ct_sum_i16(const int16_t *a, size_t n) {
    int64_t s = 0;
    for (size_t i = 0; i < n; i++) s += a[i];
    return s;
}
EXPORT float ct_sum_f32(const float *a, int n) {
    float s = 0;
    for (int i = 0; i < n; i++) s += a[i];
    return s;
}
EXPORT void ct_fill_i32(int32_t *a, size_t n, int32_t start) {
    for (size_t i = 0; i < n; i++) a[i] = start + (int32_t)(i * i);
}
EXPORT void ct_scale_f64(double *a, size_t n, double k) {
    for (size_t i = 0; i < n; i++) a[i] *= k;
}
EXPORT void ct_reverse_u8(uint8_t *a, size_t n) {
    for (size_t i = 0; i < n / 2; i++) { uint8_t t = a[i]; a[i] = a[n - 1 - i]; a[n - 1 - i] = t; }
}
/* two pointers that may alias: dst[i] += src[i] */
EXPORT void ct_add_into(double *dst, const double *src, size_t n) {
    for (size_t i = 0; i < n; i++) dst[i] += src[i];
}
/* a pointer read before it (C may read a whole object through a pointer into it) */
EXPORT double ct_prev(const double *p) { return p[-1]; }

/* strings */
EXPORT size_t ct_count_char(const char *s, char c) {
    size_t n = 0;
    for (; *s; s++) n += *s == c;
    return n;
}
EXPORT uint32_t ct_hash(const char *s) {
    uint32_t h = 2166136261u;
    for (; *s; s++) h = (h ^ (uint8_t)*s) * 16777619u;
    return h;
}
EXPORT const char *ct_greeting(void) { return "hello from C"; }
EXPORT const char *ct_name(int i) {
    static const char *names[] = {"zero", "one", "two", "three"};
    return (i >= 0 && i < 4) ? names[i] : NULL;
}
/* a string of the heap, which the caller frees */
EXPORT char *ct_repeat(const char *s, int n) {
    size_t len = strlen(s);
    char *r = malloc(len * n + 1);
    for (int i = 0; i < n; i++) memcpy(r + i * len, s, len);
    r[len * n] = 0;
    return r;
}
/* arrays of strings (char **) */
EXPORT size_t ct_total_len(const char **ss, int n) {
    size_t t = 0;
    for (int i = 0; i < n; i++) t += strlen(ss[i]) * (i + 1);
    return t;
}
EXPORT int ct_count_nonnull(const char **ss) {
    int n = 0;
    while (ss[n]) n++;
    return n;
}
/* out-pointers to strings */
EXPORT void ct_get_name(int i, const char **out) { *out = ct_name(i); }
/* replace the odd elements by static strings, keep the others */
EXPORT void ct_replace_odd(const char **ss, int n) {
    for (int i = 1; i < n; i += 2) ss[i] = ct_name(i % 4);
}
/* pointers C gives back into its arguments: a result, an out-parameter, a permuted array */
EXPORT const char *ct_find(const char *s, int c) { return strchr(s, c); }
EXPORT double *ct_find_f64(double *a, size_t n, double x) {
    size_t i = 0;
    while (i < n && a[i] < x) i++;
    return a + i;                                       /* one past the end if none */
}
EXPORT double ct_strtod(const char *s, char **end) { return strtod(s, end); }
EXPORT void ct_point_into(double *a, double **out, size_t i) { *out = a + i; }
static int ct_cmp_str(const void *a, const void *b) {
    return strcmp(*(const char *const *)a, *(const char *const *)b);
}
EXPORT void ct_sort_strings(const char **ss, int n) { qsort(ss, n, sizeof *ss, ct_cmp_str); }
/* the buffers reversed, then the first byte of each written by its new place */
EXPORT void ct_reverse_mark(unsigned char **bufs, int n) {
    for (int i = 0; i < n / 2; i++) { unsigned char *t = bufs[i]; bufs[i] = bufs[n - 1 - i]; bufs[n - 1 - i] = t; }
    for (int i = 0; i < n; i++) bufs[i][0] = (unsigned char)('A' + i);
}
/* a struct of Julia's (a mutable struct) by a pointer to it, whose fields are pointers */
typedef struct { const char *name; double *data; int n; } ct_holder;
EXPORT double ct_holder_sum(ct_holder *h) {
    double s = 0;
    for (int i = 0; i < h->n; i++) s += h->data[i];
    h->data[0] = s;
    h->n = (int)strlen(h->name);
    return s;
}
EXPORT void ct_holder_advance(ct_holder *h) { h->data += 1; h->n -= 1; }
EXPORT void ct_holder_rename(ct_holder *h) { h->name = ct_name(1); }
/* write into a buffer */
EXPORT int ct_format(char *buf, size_t n, int x, double y) { return snprintf(buf, n, "x=%d y=%.3f", x, y); }

/* structs by value, as ImGui's */
typedef struct { float x, y; } ct_vec2;                 /* ImVec2 */
typedef struct { float x, y, z, w; } ct_vec4;           /* ImVec4 */
typedef struct { double re, im; } ct_complex;
typedef struct { float v; } ct_one;                     /* one scalar: passed as it */
typedef struct { ct_one inner; } ct_nested_one;
typedef struct { int64_t id; } ct_handle;
typedef struct { } ct_empty;                            /* no size (a GNU extension) */
typedef struct { char a; double b; short c; } ct_mixed; /* padding: 24 bytes */
typedef struct { const char *name; int n; } ct_named;   /* a pointer and an int: 16 bytes */
typedef struct { double m[6]; int32_t k; } ct_big;      /* 56 bytes, returned by sret */

EXPORT ct_vec2 ct_vec2_add(ct_vec2 a, ct_vec2 b) { ct_vec2 r = {a.x + b.x, a.y + b.y}; return r; }
EXPORT ct_vec2 ct_vec2_scale(ct_vec2 a, float k) { ct_vec2 r = {a.x * k, a.y * k}; return r; }
EXPORT float ct_vec2_dot(ct_vec2 a, ct_vec2 b) { return a.x * b.x + a.y * b.y; }
EXPORT ct_vec4 ct_vec4_mix(ct_vec4 a, ct_vec4 b, float t) {
    ct_vec4 r = {a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t, a.z + (b.z - a.z) * t, a.w + (b.w - a.w) * t};
    return r;
}
EXPORT ct_complex ct_cmul(ct_complex a, ct_complex b) {
    ct_complex r = {a.re * b.re - a.im * b.im, a.re * b.im + a.im * b.re};
    return r;
}
EXPORT ct_one ct_one_twice(ct_one a) { ct_one r = {a.v * 2}; return r; }
EXPORT float ct_nested_get(ct_nested_one a) { return a.inner.v; }
EXPORT ct_handle ct_handle_next(ct_handle h) { ct_handle r = {h.id + 1}; return r; }
EXPORT int ct_empty_arg(int a, ct_empty e, int b) { (void)e; return a * 10 + b; }
EXPORT ct_empty ct_empty_ret(void) { ct_empty e; return e; }
EXPORT double ct_mixed_sum(ct_mixed m) { return m.a + m.b + m.c; }
EXPORT ct_mixed ct_mixed_make(char a, double b, short c) { ct_mixed m = {a, b, c}; return m; }
EXPORT size_t ct_named_len(ct_named s) { return s.name ? strlen(s.name) * s.n : (size_t)s.n; }
EXPORT ct_named ct_named_make(int i) { ct_named s = {ct_name(i), i}; return s; }
EXPORT ct_big ct_big_make(double x, int32_t k) {
    ct_big b;
    for (int i = 0; i < 6; i++) b.m[i] = x * i;
    b.k = k;
    return b;
}
EXPORT double ct_big_sum(ct_big b) {
    double s = b.k;
    for (int i = 0; i < 6; i++) s += b.m[i];
    return s;
}
/* a struct by value and a pointer to one, written */
EXPORT void ct_vec2_store(ct_vec2 v, ct_vec2 *out) { out->x = v.y; out->y = v.x; }

/* a struct with pointers to arrays, as ImPlot's ImPlotSpec: by value, through a pointer, in an
 * array, and returned (by sret) pointing into an argument */
typedef struct { float scale, offset; const float *xs; int n; double *ys; } ct_spec;    /* 32 bytes */
EXPORT double ct_spec_sum(ct_spec s) {
    double t = 0;
    for (int i = 0; i < s.n; i++) {
        t += s.xs[i] * s.scale + s.offset;
        if (s.ys) s.ys[i] = t;
    }
    return t;
}
EXPORT void ct_spec_advance(ct_spec *s) { ct_spec_sum(*s); s->xs += 1; s->n -= 1; }
EXPORT ct_spec ct_spec_tail(ct_spec s, int k) { s.xs += k; s.n -= k; return s; }
EXPORT double ct_specs_sum(ct_spec *ss, int m) {
    double t = 0;
    for (int i = 0; i < m; i++) { t += ct_spec_sum(ss[i]) * (i + 1); ss[i].xs += i; ss[i].n -= i; }
    return t;
}
/* a struct holding one pointer: passed as the pointer */
typedef struct { double *p; } ct_ptrbox;
EXPORT ct_ptrbox ct_ptrbox_next(ct_ptrbox b) { b.p[0] += 1; b.p += 1; return b; }

/* a struct aligned to 16 (an __int128), by value, by pointer and in an array: each where its
 * alignment says (emscripten's malloc aligns only to 8) */
typedef struct { unsigned __int128 a; double b; } ct_wide;     /* 32 bytes, aligned to 16 */
EXPORT int ct_wide_check(ct_wide w, const ct_wide *p, const ct_wide *arr, int n) {
    int bad = ((uintptr_t)&w % _Alignof(ct_wide)) != 0;
    bad |= (((uintptr_t)p % _Alignof(ct_wide)) != 0) << 1;
    for (int i = 0; i < n; i++) bad |= (((uintptr_t)&arr[i] % _Alignof(ct_wide)) != 0) << 2;
    double s = 0;
    for (int i = 0; i < n; i++) s += (double)(arr[i].a >> 64) + arr[i].b;
    return bad * 1000000 + (int)s * 10 + (w.a == p->a && w.b == p->b);
}
EXPORT size_t ct_wide_layout(void) { return _Alignof(ct_wide) * 100 + sizeof(ct_wide); }

/* C's own data, read and written by Julia through pointers: an IO-like struct (as ImGuiIO) */
typedef struct {
    int32_t frame;      /* 0 */
    float dt;           /* 4 */
    ct_vec2 display;    /* 8 */
    double time;        /* 16 */
    ct_vec2 mouse[3];   /* 24 */
    bool keys[5];       /* 48 */
    const char *label;  /* 56 */
    int64_t total;      /* 64 */
} ct_io;                /* 72 */
static ct_io io = {1, 0.25f, {800, 600}, 0.5, {{1, 2}, {3, 4}, {5, 6}}, {true, false, true, false, false}, "io", 0};
EXPORT ct_io *ct_get_io(void) { return &io; }
EXPORT double ct_io_digest(void) {
    double s = io.frame + io.dt + io.display.x * 2 + io.display.y * 3 + io.time * 5;
    for (int i = 0; i < 3; i++) s += io.mouse[i].x * (i + 7) + io.mouse[i].y * (i + 11);
    for (int i = 0; i < 5; i++) s += io.keys[i] * (i + 13);
    return s + (io.label ? strlen(io.label) : 0) + (double)io.total;
}
EXPORT void ct_io_tick(void) {
    io.frame++;
    io.time += io.dt;
    io.total += io.frame;
}
EXPORT size_t ct_sizeof_io(void) { return sizeof(ct_io); }

/* a global mutated across calls */
static int counter = 0;
EXPORT int ct_count(void) { return ++counter; }
EXPORT void ct_count_reset(void) { counter = 0; }

/* varargs */
EXPORT int ct_vsum(int n, ...) {
    va_list ap;
    va_start(ap, n);
    int s = 0;
    for (int i = 0; i < n; i++) s += va_arg(ap, int) * (i + 1);
    va_end(ap);
    return s;
}
/* by a format: i (int), l (int64), d (double), s (a string: its length), p (a pointer to an int) */
EXPORT double ct_vmix(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    double s = 0;
    int k = 1;
    for (const char *f = fmt; *f; f++, k++) {
        switch (*f) {
        case 'i': s += va_arg(ap, int) * k; break;
        case 'l': s += (double)va_arg(ap, int64_t) * k; break;
        case 'd': s += va_arg(ap, double) * k; break;
        case 's': s += strlen(va_arg(ap, const char *)) * k; break;
        case 'p': { int *p = va_arg(ap, int *); s += *p * k; *p += 100; break; }
        }
    }
    va_end(ap);
    return s;
}
EXPORT int ct_sprintf(char *buf, size_t n, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    int r = vsnprintf(buf, n, fmt, ap);
    va_end(ap);
    return r;
}

/* the heap: blocks Julia allocates (Libc.malloc), read and written here */
EXPORT int64_t ct_heap_sum(const int64_t *p, size_t n) {
    int64_t s = 0;
    for (size_t i = 0; i < n; i++) s += p[i] * (int64_t)(i + 1);
    return s;
}
EXPORT int64_t *ct_heap_make(size_t n) {
    int64_t *p = malloc(n * sizeof(int64_t));
    for (size_t i = 0; i < n; i++) p[i] = (int64_t)(i * 3);
    return p;
}
/* a pointer stored in C memory, read back */
static void *stored = NULL;
EXPORT void ct_store_ptr(void *p) { stored = p; }
EXPORT void *ct_load_ptr(void) { return stored; }
/* a pointer to a pointer written: a block of the heap */
EXPORT void ct_alloc_into(double **out, size_t n) {
    double *p = malloc(n * sizeof(double));
    for (size_t i = 0; i < n; i++) p[i] = i + 0.5;
    *out = p;
}
