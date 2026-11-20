# Linking with a C module (`Config(c_linkage)`, src/clinkage.jl): the module imports the
# memory and the functions of a C library compiled for wasm64, and a pointer without owner is
# an address in that memory. Differential: the same functions call the C library of
# test/clinkage/ctest.c natively (a shared library, clang) and compiled to Wasm (the library
# built by emscripten with -m64, the module linked with it in Node.js), and their results must
# be equal. The toolchains are those of test/clinkage/shell.nix; without `emcc` and `clang` on
# the PATH these tests are skipped.

const CTEST_DIR = joinpath(@__DIR__, "clinkage")
const HAS_C_TOOLCHAIN = Sys.which("emcc") !== nothing && Sys.which("clang") !== nothing
HAS_C_TOOLCHAIN || @warn "test/clinkage.jl: emcc or clang not on the PATH: the C linkage tests are skipped (run them in `nix-shell test/clinkage/shell.nix`)"

# the library, as a JLL package declares it: a global variable, set when the package loads to
# the path of the library (here the native one), which is the library's identity for the C linkage
global libctest::String = ""

"""
    build_ctest() -> (native library, emscripten module's JavaScript)

test/clinkage/ctest.c built natively and for wasm64 (emscripten 6: memory64, its loader an ES
module exporting the module's factory), in a new directory.
"""
function build_ctest()
    dir = mktempdir()
    src = joinpath(CTEST_DIR, "ctest.c")
    native = joinpath(dir, "libctest." * Base.Libc.Libdl.dlext)
    run(`clang -shared -fPIC -O2 -o $native $src`)
    js = joinpath(dir, "ctest.mjs")
    # (the exports the C linkage imports: the stack's and the allocator's, which emscripten keeps
    # only when they are named; the test's functions are EMSCRIPTEN_KEEPALIVE)
    exports = join(["_malloc", "_free", "_calloc", "_realloc", "_emscripten_stack_get_current",
                    "__emscripten_stack_alloc", "__emscripten_stack_restore"], ",")
    run(`emcc -m64 -O2 $src -o $js -sMODULARIZE -sEXPORT_ES6 -sENVIRONMENT=node -sALLOW_MEMORY_GROWTH
         -sEXPORTED_FUNCTIONS=$exports`)
    return native, js
end

const CTEST_JS = Ref("")
const CCOMPILED = IdDict{Any,Any}()

"The configuration of the tests' modules: linked with the C library, by its identity `libctest`."
ctest_config(; kw...) = test_config(; c_linkage=CLinkage(; libraries=[libctest], kw...))

ccompile(f, argtypes::Tuple) = get!(() -> WasmCodegen.compile(f, argtypes; config=ctest_config()), CCOMPILED, (f, argtypes))

"`f(args...)` compiled (linked with the C library) and run: the value, or `(:trap, message)`."
crun(f, args...) = wasm_run(ccompile(f, map(Core.Typeof, args)), string(nameof(f)), args...;
                            rettype=Base.return_types(f, map(Core.Typeof, args))[1], cmodule=CTEST_JS[])

"""
    @ctest f(args...)

`f(args...)` natively, calling the native library, and compiled to Wasm, calling the C module:
equal results, of the same type.
"""
macro ctest(ex)
    Meta.isexpr(ex, :call) || error("@ctest expects a call")
    f = esc(ex.args[1])
    args = map(esc, ex.args[2:end])
    quote
        local f = $f
        local args = ($(args...),)
        local expected = Base.invokelatest(f, args...)
        local got = crun(f, args...)
        @test isequal(got, expected) && typeof(got) === typeof(expected)
        isequal(got, expected) && typeof(got) === typeof(expected) ||
            println("mismatch: ", f, args, "\n  native: ", repr(expected), "\n  wasm:   ", repr(got))
    end
end

# (the runner returns isbits values: strings and vectors as digests of their contents)
sdigest(s::AbstractString) = (ncodeunits(s), foldl((h, b) -> h * 0x100000001b3 ⊻ b, codeunits(s); init=0xcbf29ce484222325))
vdigest(v::AbstractVector) = (length(v), foldl((h, x) -> h * 31.0 + x, v; init=0.0))

## scalars, pointers passed through, C memory from Julia (D1-D3)

ct_sext(x::Int8, y::Int16) = (ccall((:ct_sext8, libctest), Int32, (Int8,), x),
                              ccall((:ct_sext16, libctest), Int32, (Int16,), y))
ct_zext(x::UInt8, y::UInt16) = (ccall((:ct_zext8, libctest), UInt32, (UInt8,), x),
                                ccall((:ct_zext16, libctest), UInt32, (UInt16,), y))
ct_small(x::Int8, y::UInt8, z::Int16, w::UInt16) =
    (ccall((:ct_neg8, libctest), Int8, (Int8,), x), ccall((:ct_inc8, libctest), UInt8, (UInt8,), y),
     ccall((:ct_neg16, libctest), Int16, (Int16,), z), ccall((:ct_inc16, libctest), UInt16, (UInt16,), w))
ct_wide(a::Int32, b::UInt32, c::Int64, d::UInt64) =
    (ccall((:ct_mul32, libctest), Int32, (Int32, Int32), a, a + Int32(3)),
     ccall((:ct_xor32, libctest), UInt32, (UInt32, UInt32), b, 0xdeadbeef),
     ccall((:ct_mul64, libctest), Int64, (Int64, Int64), c, c - 7),
     ccall((:ct_rot64, libctest), UInt64, (UInt64, Cint), d, Cint(13)))
ct_floats(x::Float32, y::Float64) = (ccall((:ct_fma32, libctest), Float32, (Float32, Float32, Float32), x, x, 1.5f0),
                                     ccall((:ct_div64, libctest), Float64, (Float64, Float64), y, 3.0))
ct_bools(b::Bool) = (ccall((:ct_not, libctest), Bool, (Bool,), b), ccall((:ct_bool_int, libctest), Cint, (Bool,), b))
ct_chars(c::UInt8) = (ccall((:ct_upper, libctest), Cchar, (Cchar,), c % Cchar),
                      ccall((:ct_long, libctest), Clong, (Clong,), Clong(c) << 40),
                      ccall((:ct_size, libctest), Csize_t, (Csize_t,), Csize_t(c) << 33))
ct_mix(a::Int8, b::UInt16, c::Int32, d::Int64, e::Float32, f::Float64, g::Bool, h::UInt8) =
    ccall((:ct_mix, libctest), Float64, (Int8, UInt16, Int32, Int64, Float32, Float64, Bool, UInt8), a, b, c, d, e, f, g, h)
# an enum (`@enum` of a C int): passed and returned as its integer
@enum CtColor::Cint CtRed = 0 CtGreen = 5 CtBlue = -3
ct_enum(c::CtColor) = ccall((:ct_next_color, libctest), CtColor, (CtColor,), c)
ct_enums() = (ct_enum(CtRed), ct_enum(CtGreen), ct_enum(CtBlue))

# a C global, mutated across calls (and across the calls of separate entry points)
ct_count3() = (ccall((:ct_count_reset, libctest), Cvoid, ()); a = ccall((:ct_count, libctest), Cint, ());
               b = ccall((:ct_count, libctest), Cint, ()); c = ccall((:ct_count, libctest), Cint, ()); (a, b, c))
ct_count_more() = ccall((:ct_count, libctest), Cint, ())

# static strings of C: pointers without owner, read by Julia
ct_greeting() = sdigest(unsafe_string(ccall((:ct_greeting, libctest), Cstring, ())))
ct_names() = sdigest(join([unsafe_string(ccall((:ct_name, libctest), Ptr{Cchar}, (Cint,), i)) for i in 0:3], ","))
ct_null_name() = ccall((:ct_name, libctest), Ptr{Cchar}, (Cint,), 9) == C_NULL
ct_partial_name(n::Int) = sdigest(unsafe_string(ccall((:ct_name, libctest), Ptr{UInt8}, (Cint,), 3) + 1, n))

# the IO-like struct of C (as ImGuiIO): read and written field by field through pointer
# arithmetic (`Ptr{T}(io + offset)`, as CImGui's accessors), and as a whole
struct CtVec2
    x::Float32
    y::Float32
end
struct CtIO
    frame::Int32
    dt::Float32
    display::CtVec2
    time::Float64
    mouse::NTuple{3,CtVec2}
    keys::NTuple{5,Bool}
    label::Ptr{Cchar}
    total::Int64
end
ct_io() = ccall((:ct_get_io, libctest), Ptr{CtIO}, ())
ct_io_digest() = ccall((:ct_io_digest, libctest), Cdouble, ())
function ct_io_fields()
    io = ct_io()
    p = Ptr{UInt8}(io)
    frame = unsafe_load(Ptr{Int32}(p + 0))
    display = unsafe_load(Ptr{CtVec2}(p + 8))
    mouse2 = unsafe_load(Ptr{CtVec2}(p + 24), 2)
    key2 = unsafe_load(Ptr{Bool}(p + 48), 3)
    label = sdigest(unsafe_string(unsafe_load(Ptr{Ptr{Cchar}}(p + 56))))
    return (frame, display, mouse2, key2, label, ccall((:ct_sizeof_io, libctest), Csize_t, ()) == sizeof(CtIO))
end
function ct_io_write(x::Float32)
    io = ct_io()
    p = Ptr{UInt8}(io)
    before = ct_io_digest()
    unsafe_store!(Ptr{Float32}(p + 4), x)                   # dt
    unsafe_store!(Ptr{CtVec2}(p + 8), CtVec2(x, 2x))        # display
    unsafe_store!(Ptr{CtVec2}(p + 24), CtVec2(-x, x), 3)    # mouse[2]
    unsafe_store!(Ptr{Bool}(p + 48), true, 2)               # keys[1]
    unsafe_store!(Ptr{Ptr{Cchar}}(p + 56), ccall((:ct_greeting, libctest), Ptr{Cchar}, ()))
    ccall((:ct_io_tick, libctest), Cvoid, ())
    after = ct_io_digest()
    whole = unsafe_load(io)
    unsafe_store!(io, CtIO(whole.frame, whole.dt, whole.display, 0.5, whole.mouse, whole.keys, whole.label, 0))
    return (before, after, whole.frame, whole.time, whole.mouse[3], whole.keys, sdigest(unsafe_string(whole.label)), ct_io_digest())
end
# (restores the struct's fields that `ct_io_write` changes, for the native and the Wasm runs to
# start alike)
function ct_io_reset()
    io = ct_io()
    w = unsafe_load(io)
    unsafe_store!(io, CtIO(1, 0.25f0, CtVec2(800, 600), 0.5, (CtVec2(1, 2), CtVec2(3, 4), CtVec2(5, 6)),
                           (true, false, true, false, false), w.label, 0))
    return ct_io_digest()
end

# the heap of C: Libc's allocator, blocks read and written from Julia and C
function ct_heap(n::Int)
    p = Ptr{Int64}(Libc.malloc(n * sizeof(Int64)))
    for i in 1:n
        unsafe_store!(p, Int64(i * i - 3), i)
    end
    s = ccall((:ct_heap_sum, libctest), Int64, (Ptr{Int64}, Csize_t), p, n)
    q = ccall((:ct_heap_make, libctest), Ptr{Int64}, (Csize_t,), n)
    t = sum(unsafe_load(q, i) for i in 1:n)
    Libc.free(q)
    z = Ptr{Int32}(Libc.calloc(n, 4))
    zs = sum(unsafe_load(z, i) for i in 1:n)
    z2 = Ptr{Int32}(Libc.realloc(z, 8n))
    unsafe_store!(z2, Int32(42), 2n)
    zl = unsafe_load(z2, 2n)
    Libc.free(z2)
    Libc.free(p)
    return (s, t, zs, zl)
end
# a pointer stored in C memory and loaded back: an address without owner
function ct_ptr_roundtrip(n::Int)
    p = Ptr{Float64}(Libc.malloc(8n))
    for i in 1:n; unsafe_store!(p, i / 2, i); end
    ccall((:ct_store_ptr, libctest), Cvoid, (Ptr{Cvoid},), p)
    q = Ptr{Float64}(ccall((:ct_load_ptr, libctest), Ptr{Cvoid}, ()))
    pp = Ptr{Ptr{Float64}}(Libc.malloc(8))
    unsafe_store!(pp, q + 8)
    r = unsafe_load(pp)
    v = (q == p, unsafe_load(r), unsafe_load(q, n), r - q, UInt(r) - UInt(p), q < r)
    Libc.free(pp); Libc.free(p)
    return v
end

# pointer operations on C memory and between it and Julia's (owned) memory
function ct_ptr_ops(n::Int)
    a = collect(1.0:n)
    p = Ptr{Float64}(Libc.malloc(8n))
    GC.@preserve a unsafe_copyto!(p, pointer(a), n)                # Julia to C
    unsafe_store!(p, -1.0, 2)
    b = zeros(n)
    GC.@preserve b unsafe_copyto!(pointer(b), p, n)                # C to Julia
    q = Ptr{Float64}(Libc.malloc(8n))
    unsafe_copyto!(q, p, n)                                        # C to C
    Libc.memmove(q + 8, q, 8 * (n - 1))                            # overlapping
    Libc.memset(q, 0, 8)
    c = [unsafe_load(q, i) for i in 1:n]
    eq = sign(Libc.memcmp(p, q, 8n)), sign(Libc.memcmp(p + 16, q + 24, 8))
    s = Ptr{UInt8}(Libc.malloc(16))
    GC.@preserve a unsafe_copyto!(s, Ptr{UInt8}(pointer("hello, C\0")), 9)
    str = sdigest(unsafe_string(s)), sdigest(unsafe_string(s + 7)), sdigest(unsafe_string(s, 4)),
          ccall(:strlen, Csize_t, (Ptr{UInt8},), s),
          ccall(:memchr, Ptr{UInt8}, (Ptr{UInt8}, Cint, Csize_t), s, Cint('l'), 9) - s
    Libc.free(s); Libc.free(q); Libc.free(p)
    return (vdigest(b), vdigest(c), eq, str)
end
# loads and stores of each isbits type through C pointers, at indices
function ct_types(x::Int64)
    p = Libc.malloc(64)
    vals = (Int8(-3), UInt16(0xbeef), Int32(x), x, UInt128(x) << 70 | 5, Float32(x) / 3, Float64(x) / 7,
            true, 'λ', CtVec2(1.5, -2.5), (Int8(1), 2.0, Int16(-3)))
    out = map(vals) do v
        q = Ptr{typeof(v)}(p)
        unsafe_store!(q, v, 2)
        (unsafe_load(q, 2) === v, unsafe_load(Ptr{UInt8}(p) + sizeof(v)))
    end
    Libc.free(p)
    return out
end
# a pointer whose owner is known only at run time (an argument): through C memory or Julia's
@noinline ct_load_via(p::Ptr{Float64}, i::Int) = unsafe_load(p, i)
@noinline ct_store_via(p::Ptr{Float64}, v::Float64, i::Int) = unsafe_store!(p, v, i)
function ct_dynamic(n::Int)
    c = Ptr{Float64}(Libc.malloc(8n))
    j = zeros(n)
    s = 0.0
    GC.@preserve j for i in 1:n
        ct_store_via(c, i * 1.25, i)
        ct_store_via(pointer(j), i * 2.5, i)
        s += ct_load_via(c, i) + ct_load_via(pointer(j), i)
    end
    Libc.free(c)
    return s, vdigest(j)
end

# copies between C memory and arrays of each kind, whole elements or not, from offsets
function ct_copies(n::Int)
    c = Ptr{UInt8}(Libc.malloc(16n + 16))
    Libc.memset(c, 0x5a, 16n + 16)
    f = [i * 0.5 for i in 1:n]
    GC.@preserve f unsafe_copyto!(Ptr{Float64}(c) + 8, pointer(f, 2), n - 1)    # elements
    h = Int16[i for i in 1:n]
    GC.@preserve h unsafe_copyto!(c + 1, Ptr{UInt8}(pointer(h)), 2n - 1)      # bytes of elements
    s = "abcdefgh"
    GC.@preserve s unsafe_copyto!(c + 3, pointer(s, 3), 6)                      # with the NUL after it
    back = zeros(Float64, n + 2)
    GC.@preserve back unsafe_copyto!(Ptr{UInt8}(pointer(back, 2)), c, 8n)
    t = Tuple{Int8,Float64}[(Int8(i), i / 3) for i in 1:n]                   # padded elements
    GC.@preserve t unsafe_copyto!(c, Ptr{UInt8}(pointer(t)), 16n)
    tb = [unsafe_load(Ptr{Tuple{Int8,Float64}}(c), i) for i in 1:n]
    Libc.free(c)
    return (vdigest(back), tb[1], tb[n])
end
ct_wrap(n::Int) = (p = Ptr{Float64}(Libc.malloc(8n)); sum(unsafe_wrap(Array, p, n)))

@testset "C linkage: scalars, C memory (D1-D3)" begin
    if HAS_C_TOOLCHAIN
        native, js = build_ctest()
        global libctest = native
        CTEST_JS[] = js
        @ctest ct_sext(Int8(-1), Int16(-300))
        @ctest ct_sext(Int8(127), Int16(32767))
        @ctest ct_zext(0xff, 0xfffe)
        @ctest ct_small(Int8(-128), 0xff, Int16(-5), 0xffff)
        @ctest ct_small(Int8(5), 0x01, Int16(300), 0x0007)
        @ctest ct_wide(Int32(-12345), 0x12345678, Int64(-1) << 40, 0x0123456789abcdef)
        @ctest ct_floats(1.25f0, -7.5)
        @ctest ct_floats(NaN32, Inf)
        @ctest ct_bools(true)
        @ctest ct_bools(false)
        @ctest ct_chars(UInt8('q'))
        @ctest ct_chars(0xe9)
        @ctest ct_mix(Int8(-7), 0xfffe, Int32(-3), Int64(5), 0.5f0, 2.0, true, 0xff)
        @ctest ct_enums()
        @ctest ct_count3()
        @ctest ct_count_more()
        @ctest ct_count_more()
        @ctest ct_greeting()
        @ctest ct_names()
        @ctest ct_null_name()
        @ctest ct_partial_name(3)
        @ctest ct_io_fields()
        @ctest ct_io_write(3.5f0)
        @ctest ct_io_reset()
        @ctest ct_heap(10)
        @ctest ct_ptr_roundtrip(4)
        @ctest ct_ptr_ops(6)
        @ctest ct_types(1234567)
        @ctest ct_dynamic(5)
        @ctest ct_copies(7)
        # the module's memory is the C module's
        c = ccompile(ct_ptr_roundtrip, (Int,))
        @test c.cgm.mod.memory.imported == ("c", "memory") && c.cgm.mod.memory.index64
    else
        @test_skip "C linkage"
    end
end

## errors: run-time errors of the program, constructs reported when compiling, configurations

# a pointer into a Julia object stored in C memory, as a value or a field: an error (the C
# module cannot address the object), its message on stderr too (natively a store does not
# throw, so nothing may catch it); natively it is stored
struct CtNamedJ
    name::Ptr{Cchar}
    n::Cint
end
function ct_store_owned_value(n::Int)
    p = Ptr{Ptr{Float64}}(Libc.malloc(16))
    v = fill(1.5, n)
    GC.@preserve v unsafe_store!(p, pointer(v))
    Libc.free(p)
    return n
end
function ct_store_owned_field(n::Int)
    q = Ptr{CtNamedJ}(Libc.malloc(16))
    s = "name"
    GC.@preserve s unsafe_store!(q, CtNamedJ(pointer(s), Cint(n)))
    Libc.free(q)
    return n
end
# (an address without owner is stored)
function ct_store_address(a::UInt)
    q = Ptr{CtNamedJ}(Libc.malloc(16))
    unsafe_store!(q, CtNamedJ(Ptr{Cchar}(a), 2))
    r = unsafe_load(q)
    Libc.free(q)
    return (UInt(r.name), r.n)
end

# signatures C cannot be called with
ct_bad_any(x) = ccall((:ct_mul32, libctest), Int32, (Any, Int32), x, Int32(1))
mutable struct CtMutable
    x::Int32
end
ct_bad_mutable(x::CtMutable) = ccall((:ct_mul32, libctest), Int32, (CtMutable, Int32), x, Int32(1))
ct_bad_f16(x::Float16) = ccall((:ct_div64, libctest), Float64, (Float16, Float64), x, 1.0)
ct_bad_i128(x::Int128) = ccall((:ct_mul64, libctest), Int64, (Int128, Int64), x, 1)
ct_bad_two(x::Int32) = ccall((:ct_mul32, libctest), Int32, (Int32, Int32), x, x) +
                       ccall((:ct_mul32, libctest), Int64, (Int64, Int64), Int64(x), Int64(x))
ct_bad_bytes(v::Vector{UInt8}) = ccall((:send, "ct_host"), Cvoid, (Vector{UInt8},), v)
# (a C library not linked: as without a C module)
ct_other_lib(x::Int32) = ccall((:ct_mul32, "libother"), Int32, (Int32, Int32), x, x)
# without a C module, a pointer without owner cannot be dereferenced
ct_no_linkage(x::UInt) = unsafe_load(Ptr{Int64}(x))

function ct_unsupported(f, argtypes; config=ctest_config())
    err = try
        WasmCodegen.compile(f, argtypes; config)
        nothing
    catch e
        e
    end
    return err isa WasmCodegen.UnsupportedConstructs ? sprint(showerror, err) : err
end

@testset "C linkage: errors, diagnostics, configurations" begin
    if HAS_C_TOOLCHAIN
        for f in (ct_store_owned_value, ct_store_owned_field)
            @test f(3) == 3
            @test crun(f, 3)[1] === :trap
            @test occursin(WasmCodegen.Runtime.CLink.OWNED_STORE, LAST_OUTPUT[])
        end
        @ctest ct_store_address(UInt(1) << 40)
    end
    # (compiling needs no C toolchain)
    for (f, T, what) in [(ct_bad_any, (Int32,), "the type Any by value"),
                         (ct_bad_mutable, (CtMutable,), "CtMutable by value"),
                         (ct_bad_f16, (Float16,), "the type Float16, which no scalar"),
                         (ct_bad_i128, (Int128,), "the type Int128, which no scalar"),
                         (ct_bad_two, (Int32,), "calls of the C function ct_mul32 with two Wasm types")]
        msg = ct_unsupported(f, T)
        @test msg isa String && occursin(what, msg) && occursin("ct_", msg)
        msg isa String && occursin(what, msg) || @info "unexpected" f msg
    end
    msg = ct_unsupported(ct_bad_bytes, (Vector{UInt8},); config=test_config(import_libraries=["ct_host"],
                                                                             c_linkage=CLinkage(libraries=[libctest])))
    @test msg isa String && occursin("the linear memory is the C module's", msg)
    msg = ct_unsupported(ct_wrap, (Int,))
    @test msg isa String && occursin("unsafe_wrap: an array cannot share the bytes", msg)
    msg = ct_unsupported(ct_other_lib, (Int32,))
    @test msg isa String && occursin("the foreign call ct_mul32", msg)
    # the library's identity: its value when compiling, equal as a String
    msg = ct_unsupported(ct_count_more, (); config=test_config(c_linkage=CLinkage(libraries=[Symbol(libctest)])))
    @test msg isa String && occursin("the foreign call ct_count", msg)
    c = ccompile(ct_count_more, ())
    @test any(f -> f.imported == ("c", "ct_count"), c.cgm.mod.funcs)
    # configurations
    @test_throws ArgumentError WasmCodegen.compile(ct_count_more, (); config=WasmCodegen.Config(host=:wasi, c_linkage=CLinkage(libraries=[libctest])))
    @test_throws ArgumentError WasmCodegen.compile(ct_count_more, (); config=ctest_config(memory64=false))
    @test_throws ArgumentError WasmCodegen.compile(ct_count_more, (); config=test_config(import_libraries=[libctest], c_linkage=CLinkage(libraries=[libctest])))
    @test_throws ArgumentError WasmCodegen.compile(ct_count_more, (); config=ctest_config(import_module="julia"))
    # without a C module: no memory, a pointer without owner traps
    c = wcompile(ct_no_linkage, (UInt,))
    @test c.cgm.mod.memory === nothing
    @test wasm_run(c, "ct_no_linkage", UInt(64); rettype=Int64)[1] === :trap
end

## pointers into Julia objects passed to C: a copy of the object, written back (D4)

function ct_refs(a::Int8, b::UInt16, c::Int32, d::Int64, e::Float32, f::Float64, g::Bool)
    ra, rb, rc, rd, re, rf, rg = Ref(a), Ref(b), Ref(c), Ref(d), Ref(e), Ref(f), Ref(g)
    ccall((:ct_bump_i8, libctest), Cvoid, (Ref{Int8},), ra)
    ccall((:ct_bump_u16, libctest), Cvoid, (Ptr{UInt16},), rb)
    ccall((:ct_bump_i32, libctest), Cvoid, (Ref{Int32},), rc)
    ccall((:ct_bump_i64, libctest), Cvoid, (Ref{Int64},), rd)
    ccall((:ct_bump_f32, libctest), Cvoid, (Ref{Float32},), re)
    ccall((:ct_bump_f64, libctest), Cvoid, (Ptr{Float64},), rf)
    ccall((:ct_flip, libctest), Cvoid, (Ref{Bool},), rg)
    q, r = Ref{Cint}(0), Ref{Cint}(0)
    ccall((:ct_divmod, libctest), Cvoid, (Cint, Cint, Ref{Cint}, Ref{Cint}), Cint(c), Cint(7), q, r)
    return (ra[], rb[], rc[], rd[], re[], rf[], rg[], q[], r[])
end

function ct_arrays(n::Int)
    v = [sin(i) for i in 1:n]
    s = ccall((:ct_sum_f64, libctest), Float64, (Ptr{Float64}, Csize_t), v, n)
    s2 = ccall((:ct_sum_f64, libctest), Float64, (Ptr{Float64}, Csize_t), pointer(v, 3), n - 2)   # a part
    w = Int16[i * 1000 - 7 for i in 1:n]
    t = ccall((:ct_sum_i16, libctest), Int64, (Ref{Int16}, Csize_t), w, n)
    f = Float32[i / 4 for i in 1:n]
    u = ccall((:ct_sum_f32, libctest), Float32, (Ptr{Float32}, Cint), f, n)
    a = zeros(Int32, n)
    ccall((:ct_fill_i32, libctest), Cvoid, (Ptr{Int32}, Csize_t, Int32), a, n, Int32(-5))
    GC.@preserve a ccall((:ct_fill_i32, libctest), Cvoid, (Ptr{Int32}, Csize_t, Int32), pointer(a, n ÷ 2), 2, Int32(100))
    ccall((:ct_scale_f64, libctest), Cvoid, (Ptr{Float64}, Csize_t, Float64), v, n, 2.0)
    b = UInt8[i for i in 1:n]
    ccall((:ct_reverse_u8, libctest), Cvoid, (Ptr{UInt8}, Csize_t), b, n)
    # two pointers into one array: one copy, as natively one object
    x = collect(1.0:n)
    GC.@preserve x ccall((:ct_add_into, libctest), Cvoid, (Ptr{Float64}, Ptr{Float64}, Csize_t), pointer(x, 3), pointer(x, 1), n - 2)
    # C reads before the pointer, in its object
    prev = GC.@preserve x ccall((:ct_prev, libctest), Float64, (Ptr{Float64},), pointer(x, 4))
    return (s, s2, t, u, vdigest(a), vdigest(v), vdigest(b), vdigest(x), prev)
end
# larger than the C stack's share: on the C heap
ct_big_array(n::Int) = ccall((:ct_sum_f64, libctest), Float64, (Ptr{Float64}, Csize_t), [1 / i for i in 1:n], n)
# a vector deleted at the front: its pointer is not its memory's first element
function ct_offset_vector(n::Int)
    v = collect(1.0:n+3)
    deleteat!(v, 1:3)
    ccall((:ct_scale_f64, libctest), Cvoid, (Ptr{Float64}, Csize_t, Float64), v, n, -1.0)
    return vdigest(v)
end
# a mutable struct's fields (`Ref` of it, as `Ptr`)
mutable struct CtPair
    a::Int32
    b::Int32
end
function ct_mutable_struct(x::Int32)
    p = CtPair(x, x + Int32(1))
    ccall((:ct_bump_i32, libctest), Cvoid, (Ptr{Int32},), pointer_from_objref(p))
    return (p.a, p.b)
end

function ct_strings(i::Int)
    s = ("hello, world: foo", "", "ooo")[i]
    n = ccall((:ct_count_char, libctest), Csize_t, (Cstring, Cchar), s, Cchar('o'))
    h = ccall((:ct_hash, libctest), UInt32, (Ptr{Cchar},), s)
    hs = ccall((:ct_hash, libctest), UInt32, (Cstring,), :a_symbol)
    r = ccall((:ct_repeat, libctest), Ptr{Cchar}, (Cstring, Cint), s, Cint(3))
    rep = sdigest(unsafe_string(r))
    Libc.free(r)
    return (n, h, hs, rep)
end
function ct_string_arrays(n::Int)
    strs = [repeat(string(Char('a' + i)), i) for i in 1:n]
    t = ccall((:ct_total_len, libctest), Csize_t, (Ptr{Ptr{Cchar}}, Cint), strs, n)
    t2 = ccall((:ct_total_len, libctest), Csize_t, (Ptr{Cstring}, Cint), strs, n)
    k = ccall((:ct_count_nonnull, libctest), Cint, (Ptr{Cstring},), strs)
    # an out-pointer: a string of C's
    out = Ref{Ptr{Cchar}}(C_NULL)
    ccall((:ct_get_name, libctest), Cvoid, (Cint, Ref{Ptr{Cchar}}), Cint(2), out)
    out2 = Ref{Cstring}(C_NULL)
    ccall((:ct_get_name, libctest), Cvoid, (Cint, Ptr{Cstring}), Cint(3), out2)
    # pointers C replaces (its strings), and keeps (Julia's)
    ptrs = [pointer(s) for s in strs]
    GC.@preserve strs ccall((:ct_replace_odd, libctest), Cvoid, (Ptr{Ptr{Cchar}}, Cint), ptrs, n)
    names = GC.@preserve strs join([unsafe_string(p) for p in ptrs], ",")
    return (t, t2, k, sdigest(unsafe_string(out[])), sdigest(unsafe_string(out2[])), sdigest(names))
end
# a buffer C writes
function ct_buffer(x::Int32, y::Float64)
    buf = zeros(UInt8, 64)
    r = ccall((:ct_format, libctest), Cint, (Ptr{UInt8}, Csize_t, Cint, Float64), buf, 64, x, y)
    return sdigest(String(buf[1:r]))
end
# an out-pointer to a block of the C heap
function ct_out_block(n::Int)
    r = Ref{Ptr{Float64}}(C_NULL)
    ccall((:ct_alloc_into, libctest), Cvoid, (Ref{Ptr{Float64}}, Csize_t), r, n)
    p = r[]
    s = sum(unsafe_load(p, i) for i in 1:n)
    Libc.free(p)
    return s
end
# a pointer into a memory of references cannot be passed; realloc of a Julia object's pointer
function ct_pass_references(n::Int)
    v = Any[1.0 for _ in 1:n]
    GC.@preserve v ccall((:ct_sum_f64, libctest), Float64, (Ptr{Cvoid}, Csize_t), pointer(v), 0)
end
function ct_realloc_owned(n::Int)
    v = zeros(n)
    GC.@preserve v Libc.realloc(pointer(v), 16)
    return n
end
# a Julia exception thrown between the copies and the call (here an error of the copy): the C
# stack is restored (the next calls' space is where it was)
function ct_stack_after_error(n::Int)
    sp = ccall((:emscripten_stack_get_current, libctest), UInt64, ())
    ok = try
        ct_pass_references(n)
        false
    catch e
        e isa ArgumentError
    end
    return (ok, ccall((:emscripten_stack_get_current, libctest), UInt64, ()) == sp)
end

# pointers C gives back into the copies of its arguments are pointers into the objects (the
# differential results show the copies only where C returns, writes or compares pointers: these)
function ct_back_pointers(i::Int)
    s = ("hello, world", "xyz", "")[i]
    p = ccall((:ct_find, libctest), Ptr{UInt8}, (Cstring, Cint), s, Cint('o'))
    found = p == C_NULL ? (-1, sdigest("")) : GC.@preserve s (Int(p - pointer(s)), sdigest(unsafe_string(p)))
    v = [1.5, 2.5, 3.5, 4.5]
    q = ccall((:ct_find_f64, libctest), Ptr{Float64}, (Ptr{Float64}, Csize_t, Float64), v, 4, 3.0)
    off = GC.@preserve v (unsafe_store!(q, -1.0); Int(q - pointer(v)))       # a store into `v`
    e = ccall((:ct_find_f64, libctest), Ptr{Float64}, (Ptr{Float64}, Csize_t, Float64), v, 4, 99.0)
    endoff = GC.@preserve v Int(e - pointer(v))                                # one past its end
    # an out-parameter set into another argument (strtod's `endptr`)
    t = "  -12.5e1xyz"
    endp = Ref{Ptr{UInt8}}(C_NULL)
    x = ccall((:ct_strtod, libctest), Float64, (Cstring, Ref{Ptr{UInt8}}), t, endp)
    rest = GC.@preserve t (Int(endp[] - pointer(t)), sdigest(unsafe_string(endp[])))
    w = zeros(5)
    out = Ref{Ptr{Float64}}(C_NULL)
    ccall((:ct_point_into, libctest), Cvoid, (Ptr{Float64}, Ref{Ptr{Float64}}, Csize_t), w, out, 3)
    GC.@preserve w unsafe_store!(out[], 7.0)
    return (found, off, vdigest(v), endoff, x, rest, vdigest(w))
end
# C permutes an array of pointers: each element still points into its object
function ct_sorted(n::Int)
    strs = ["pear", "apple", "fig", "banana", "cherry", "date"][1:n]
    ptrs = [pointer(s) for s in strs]
    GC.@preserve strs ccall((:ct_sort_strings, libctest), Cvoid, (Ptr{Ptr{UInt8}}, Cint), ptrs, n)
    idx = GC.@preserve strs [findfirst(s -> pointer(s) == p, strs) for p in ptrs]
    sorted = GC.@preserve strs join([unsafe_string(p) for p in ptrs], ",")
    return (sdigest(sorted), vdigest(Float64.(idx)))
end
# and writes the objects through the permuted pointers: each written back
function ct_marked(n::Int)
    bufs = [fill(UInt8('a' + i), 3) for i in 1:n]
    ptrs = [pointer(b) for b in bufs]
    GC.@preserve bufs ccall((:ct_reverse_mark, libctest), Cvoid, (Ptr{Ptr{UInt8}}, Cint), ptrs, n)
    idx = GC.@preserve bufs [findfirst(b -> pointer(b) == p, bufs) for p in ptrs]
    return (sdigest(join([String(copy(b)) for b in bufs], ",")), vdigest(Float64.(idx)))
end

# a mutable struct of pointers, by a pointer to it: its pointers passed as pointer arguments
# are, those C does not change kept (with their owners), those it changes mapped back
mutable struct CtHolder
    name::Ptr{Cchar}
    data::Ptr{Float64}
    n::Cint
end
function ct_holders(n::Int)
    s = "julia"
    v = collect(1.0:n)
    h = GC.@preserve s v CtHolder(pointer(s), pointer(v), n)
    GC.@preserve s v h begin
        t = ccall((:ct_holder_sum, libctest), Float64, (Ref{CtHolder},), h)
        kept = (h.name == pointer(s), h.data == pointer(v), sdigest(unsafe_string(h.name)), h.n)
        ccall((:ct_holder_advance, libctest), Cvoid, (Ptr{CtHolder},), pointer_from_objref(h))
        moved = (Int(h.data - pointer(v)), unsafe_load(h.data), h.n)
        ccall((:ct_holder_rename, libctest), Cvoid, (Ref{CtHolder},), h)
        renamed = sdigest(unsafe_string(h.name))
    end
    return (t, kept, moved, renamed, vdigest(v))
end
# a mutable object holding references cannot be copied for C (its references would be zeros):
# an error when compiling, where the pointer's object is known, else when running
mutable struct CtWithRef
    x::Float64
    s::String
end
ct_ref_fields(x::Float64) = (o = CtWithRef(x, "a");
    GC.@preserve o ccall((:ct_bump_f64, libctest), Cvoid, (Ptr{CtWithRef},), pointer_from_objref(o)); o.x)
@noinline ct_object_ptr(o) = Ptr{Float64}(pointer_from_objref(o))
ct_ref_fields_dynamic(x::Float64) = (o = CtWithRef(x, "a");
    GC.@preserve o ccall((:ct_bump_f64, libctest), Cvoid, (Ptr{Float64},), ct_object_ptr(o)); o.x)

# a module where nothing catches (a Julia exception traps): a call that traps midway, having
# copied `CT_BUF` (on the C heap: larger than the stack's share), leaves its copy behind; a later
# call of another export copying the same object must not reuse it, nor write it back
const CT_BUF = zeros(4000)
function ct_trap_midway(n::Int)
    v = Any[1.0]
    GC.@preserve v ccall((:ct_add_into, libctest), Cvoid, (Ptr{Float64}, Ptr{Float64}, Csize_t), CT_BUF, pointer(v), 0)
    return n
end
function ct_after_trap(x::Float64)
    fill!(CT_BUF, x)
    ccall((:ct_scale_f64, libctest), Cvoid, (Ptr{Float64}, Csize_t, Float64), CT_BUF, length(CT_BUF), 2.0)
    return (sum(CT_BUF), ccall((:ct_sum_f64, libctest), Float64, (Ptr{Float64}, Csize_t), CT_BUF, 3))
end

@testset "C linkage: pointers into Julia objects" begin
    if HAS_C_TOOLCHAIN
        @ctest ct_refs(Int8(-3), 0x1234, Int32(77), Int64(-9), 1.5f0, 3.25, false)
        @ctest ct_arrays(9)
        @ctest ct_big_array(100_000)
        @ctest ct_offset_vector(5)
        @ctest ct_mutable_struct(Int32(41))
        @ctest ct_strings(1)
        @ctest ct_strings(2)
        @ctest ct_strings(3)
        @ctest ct_string_arrays(5)
        @ctest ct_buffer(Int32(-42), 3.14159)
        @ctest ct_out_block(6)
        @ctest ct_back_pointers(1)
        @ctest ct_back_pointers(2)
        @ctest ct_back_pointers(3)
        @ctest ct_sorted(6)
        @ctest ct_marked(5)
        @ctest ct_marked(4)
        @ctest ct_holders(4)
        @test ct_ref_fields_dynamic(2.0) == 1.0
        @test crun(ct_ref_fields_dynamic, 2.0)[1] === :trap
        @test occursin(WasmCodegen.Runtime.CLink.NOT_ADDRESSABLE, LAST_OUTPUT[])
        @test crun(ct_pass_references, 3)[1] === :trap
        @test occursin(WasmCodegen.Runtime.CLink.NOT_ADDRESSABLE, LAST_OUTPUT[])
        @test crun(ct_realloc_owned, 3)[1] === :trap
        @test occursin(WasmCodegen.Runtime.CLink.REALLOC_OWNED, LAST_OUTPUT[])
        @test crun(ct_stack_after_error, 3) == (true, true)
        c = WasmCodegen.compile([(ct_trap_midway, (Int,)), (ct_after_trap, (Float64,))]; config=ctest_config())
        @test c.cgm.exceptions === :none
        expected = ct_after_trap(1.5)
        @test wasm_run(c, "ct_trap_midway", 1; rettype=Int, cmodule=CTEST_JS[])[1] === :trap
        @test occursin(WasmCodegen.Runtime.CLink.NOT_ADDRESSABLE, LAST_OUTPUT[])
        @test wasm_run(c, "ct_after_trap", 1.5; rettype=Tuple{Float64,Float64}, cmodule=CTEST_JS[]) == expected
        @test wasm_run(c, "ct_trap_midway", 1; rettype=Int, cmodule=CTEST_JS[])[1] === :trap
        @test wasm_run(c, "ct_after_trap", -0.25; rettype=Tuple{Float64,Float64}, cmodule=CTEST_JS[]) == ct_after_trap(-0.25)
        @test ct_ref_fields(2.0) == 1.0
    end
    msg = ct_unsupported(ct_ref_fields, (Float64,))
    @test msg isa String && occursin("a pointer to a CtWithRef, whose fields are not all isbits", msg)
end

## structs by value: in registers when they hold one scalar, else by the address of a copy;
## results by sret (D4)

struct CtVec4
    x::Float32
    y::Float32
    z::Float32
    w::Float32
end
struct CtComplex
    re::Float64
    im::Float64
end
struct CtOne
    v::Float32
end
struct CtNestedOne
    inner::CtOne
end
struct CtHandle
    id::Int64
end
struct CtEmpty end
struct CtMixed
    a::Cchar
    b::Float64
    c::Cshort
end
struct CtBig
    m::NTuple{6,Float64}
    k::Int32
end

function ct_structs(x::Float32, y::Float64)
    a, b = CtVec2(x, 2x), CtVec2(-1, 0.5f0)
    s = ccall((:ct_vec2_add, libctest), CtVec2, (CtVec2, CtVec2), a, b)
    k = ccall((:ct_vec2_scale, libctest), CtVec2, (CtVec2, Float32), s, 3f0)
    d = ccall((:ct_vec2_dot, libctest), Float32, (CtVec2, CtVec2), a, k)
    m = ccall((:ct_vec4_mix, libctest), CtVec4, (CtVec4, CtVec4, Float32), CtVec4(1, 2, 3, 4), CtVec4(x, x, x, x), 0.25f0)
    c = ccall((:ct_cmul, libctest), CtComplex, (CtComplex, CtComplex), CtComplex(y, 1), CtComplex(2, -y))
    o = ccall((:ct_one_twice, libctest), CtOne, (CtOne,), CtOne(x))
    n = ccall((:ct_nested_get, libctest), Float32, (CtNestedOne,), CtNestedOne(CtOne(-x)))
    h = ccall((:ct_handle_next, libctest), CtHandle, (CtHandle,), CtHandle(Int64(1) << 40))
    er = ccall((:ct_empty_ret, libctest), CtEmpty, ())
    mx = ccall((:ct_mixed_sum, libctest), Float64, (CtMixed,), CtMixed(Cchar(-3), y, Cshort(300)))
    mm = ccall((:ct_mixed_make, libctest), CtMixed, (Cchar, Float64, Cshort), Cchar(9), y, Cshort(-2))
    big = ccall((:ct_big_make, libctest), CtBig, (Float64, Int32), y, Int32(7))
    bs = ccall((:ct_big_sum, libctest), Float64, (CtBig,), big)
    # a struct by value and a pointer to one (a `Ref`, written back)
    out = Ref(CtVec2(0, 0))
    ccall((:ct_vec2_store, libctest), Cvoid, (CtVec2, Ref{CtVec2}), a, out)
    return (s, k, d, m, c, o, n, h, er, mx, mm, big, bs, out[])
end
# an empty struct as an argument: none (natively Julia does not pass a value of no size)
ct_empty_arg(a::Cint) = ccall((:ct_empty_arg, libctest), Cint, (Cint, CtEmpty, Cint), a, CtEmpty(), Cint(2))
# a struct holding a pointer (and its padding): of C's string, passed and returned
function ct_named(i::Int32)
    s = ccall((:ct_named_make, libctest), CtNamedJ, (Cint,), i)
    n = ccall((:ct_named_len, libctest), Csize_t, (CtNamedJ,), s)
    return (sdigest(unsafe_string(s.name)), s.n, n)
end
# a pointer into a Julia object in a struct by value: passed as a pointer argument is
function ct_named_owned(n::Int)
    s = "julia"
    GC.@preserve s ccall((:ct_named_len, libctest), Csize_t, (CtNamedJ,), CtNamedJ(pointer(s), Cint(n)))
end
# ImPlot's way: a struct whose pointer fields point at Julia vectors, by value (C writes through
# one), by `Ref` (C moves one), in an array, and returned by sret pointing into an argument
struct CtSpec
    scale::Float32
    offset::Float32
    xs::Ptr{Float32}
    n::Cint
    ys::Ptr{Float64}
end
struct CtPtrBox
    p::Ptr{Float64}
end
# a struct aligned to 16, by value, by `Ref` and in an array (on the C heap when large, after a
# block of `k` bytes: emscripten's malloc aligns to 8, and a block of 32 makes the next one's
# address 8 past a multiple of 16): C sees each at its alignment
struct CtWide
    a::UInt128
    b::Float64
end
function ct_aligned(n::Int, k::Int)
    w = CtWide(UInt128(3) << 64 | 5, 1.5)
    arr = [CtWide(UInt128(i) << 64, i / 4) for i in 1:n]
    p = Libc.malloc(k)
    chk = ccall((:ct_wide_check, libctest), Cint, (CtWide, Ref{CtWide}, Ptr{CtWide}, Cint), w, Ref(w), arr, n)
    Libc.free(p)
    return (chk, ccall((:ct_wide_layout, libctest), Csize_t, ()), sizeof(CtWide), Base.datatype_alignment(CtWide))
end
function ct_specs(n::Int)
    xs = Float32[i / 2 for i in 1:n]
    ys = zeros(n)
    GC.@preserve xs ys begin
        s = CtSpec(2, 0.5, pointer(xs), n, pointer(ys))
        a = ccall((:ct_spec_sum, libctest), Float64, (CtSpec,), s)
        r = Ref(s)
        ccall((:ct_spec_advance, libctest), Cvoid, (Ref{CtSpec},), r)
        moved = (Int(r[].xs - pointer(xs)), unsafe_load(r[].xs), r[].n, r[].ys == pointer(ys), unsafe_load(r[].ys, 2))
        t = ccall((:ct_spec_tail, libctest), CtSpec, (CtSpec, Cint), s, Cint(2))
        tail = (Int(t.xs - pointer(xs)), unsafe_load(t.xs), t.n, t.ys == pointer(ys))
        arr = [CtSpec(1, i, pointer(xs, i), n - i + 1, i == 2 ? C_NULL : pointer(ys, i)) for i in 1:3]
        tot = ccall((:ct_specs_sum, libctest), Float64, (Ptr{CtSpec}, Cint), arr, 3)
        arrmoved = [(Int(x.xs - pointer(xs)), unsafe_load(x.xs), x.n) for x in arr]
        b = ccall((:ct_ptrbox_next, libctest), CtPtrBox, (CtPtrBox,), CtPtrBox(pointer(ys, 2)))
        boxed = (Int(b.p - pointer(ys)), unsafe_load(b.p))
    end
    return (a, moved, tail, tot, arrmoved[1], arrmoved[2], arrmoved[3], boxed, vdigest(ys))
end
# ImGui's way: a struct of C's, by a pointer to it, whose fields hold structs by value
function ct_io_struct()
    io = ct_io()
    w = unsafe_load(io)
    m = ccall((:ct_vec2_add, libctest), CtVec2, (CtVec2, CtVec2), w.display, w.mouse[2])
    unsafe_store!(Ptr{CtVec2}(Ptr{UInt8}(io) + 8), m)
    return (m, ct_io_digest())
end

# a Julia exception between the copies and the call, of a call whose structs by value are on
# the C stack and whose frame its pointer into a Julia object opened: both released
function ct_stack_after_error2(n::Int)
    sp = ccall((:emscripten_stack_get_current, libctest), UInt64, ())
    v = Any[1.0]
    ok = try
        GC.@preserve v ccall((:ct_spec_sum, libctest), Float64, (CtSpec,), CtSpec(1, 0, Ptr{Float32}(pointer(v)), 0, C_NULL))
        false
    catch e
        e isa ArgumentError
    end
    return (ok, ccall((:emscripten_stack_get_current, libctest), UInt64, ()) == sp)
end
# a call passing structs by value and no pointer into a Julia object: its space on the C stack,
# no frame
ct_dot_only(x::Float32) = ccall((:ct_vec2_dot, libctest), Float32, (CtVec2, CtVec2), CtVec2(x, 1), CtVec2(2, x))

@testset "C linkage: structs by value" begin
    if HAS_C_TOOLCHAIN
        @ctest ct_structs(1.5f0, -2.25)
        @ctest ct_structs(-0.0f0, 1e300)
        @ctest ct_named(Int32(2))
        @test crun(ct_empty_arg, Cint(4)) === Cint(42)
        @ctest ct_io_struct()
        @ctest ct_io_reset()
        @ctest ct_named_owned(2)
        @ctest ct_specs(6)
        @ctest ct_aligned(3, 32)
        @ctest ct_aligned(600, 32)
        @ctest ct_aligned(600, 40)
        @test crun(ct_stack_after_error2, 1) == (true, true)
        @ctest ct_dot_only(1.5f0)
        # (the space of the calls beyond the stack's share: in a frame, on the C heap)
        for (f, args) in ((ct_structs, (1.5f0, -2.25)), (ct_specs, (6,)))
            c = WasmCodegen.compile(f, map(typeof, args); config=ctest_config(stack_limit=48))
            @test wasm_run(c, string(nameof(f)), args...; rettype=Base.return_types(f, map(typeof, args))[1],
                           cmodule=CTEST_JS[]) == f(args...)
        end
        # (the Wasm types the C ABI gives: ImVec2 by the address of a copy, a result by sret, a
        # struct of one float as a float, an empty struct dropped)
        c = ccompile(ct_structs, (Float32, Float64))
        imp(name) = only(f for f in c.cgm.mod.funcs if f.imported == ("c", name))
        @test (imp("ct_vec2_add").params, imp("ct_vec2_add").results) == (ValType[I64, I64, I64], ValType[])
        @test (imp("ct_vec2_dot").params, imp("ct_vec2_dot").results) == (ValType[I64, I64], ValType[F32])
        @test (imp("ct_one_twice").params, imp("ct_one_twice").results) == (ValType[F32], ValType[F32])
        @test (imp("ct_handle_next").params, imp("ct_handle_next").results) == (ValType[I64], ValType[I64])
        @test isempty(imp("ct_empty_ret").results)
        c = ccompile(ct_dot_only, (Float32,))
        @test !any(f -> occursin("open_frame", f.name), c.cgm.mod.funcs)
        c = ccompile(ct_empty_arg, (Cint,))
        @test only(f for f in c.cgm.mod.funcs if f.imported == ("c", "ct_empty_arg")).params == ValType[I32, I32]
    end
end

## varargs: the variadic arguments in a buffer, at their alignments (D4)

function ct_varargs(a::Cint, b::Float64)
    s0 = @ccall libctest.ct_vsum(0::Cint; )::Cint
    s3 = @ccall libctest.ct_vsum(3::Cint; a::Cint, (a + Cint(1))::Cint, Cint(-7)::Cint)::Cint
    x = Ref{Cint}(5)
    m = @ccall libctest.ct_vmix("idslpi"::Cstring; a::Cint, b::Float64, "four"::Cstring, (Int64(1) << 40)::Int64,
                                x::Ptr{Cint}, Cint(9)::Cint)::Float64
    buf = zeros(UInt8, 80)
    n = @ccall libctest.ct_sprintf(buf::Ptr{UInt8}, 80::Csize_t, "%d|%.2f|%s|%c|%lld"::Cstring;
                                   a::Cint, b::Float64, "str"::Cstring, Cint('Z')::Cint, (Int64(-1) << 35)::Clonglong)::Cint
    return (s0, s3, m, x[], sdigest(String(buf[1:n])))
end

@testset "C linkage: varargs" begin
    if HAS_C_TOOLCHAIN
        @ctest ct_varargs(Cint(12), 2.5)
        @ctest ct_varargs(Cint(-1), -1e10)
        c = ccompile(ct_varargs, (Cint, Float64))
        imp(name) = only(f for f in c.cgm.mod.funcs if f.imported == ("c", name))
        @test imp("ct_vsum").params == ValType[I32, I64] && imp("ct_vmix").params == ValType[I64, I64]
        c = WasmCodegen.compile(ct_varargs, (Cint, Float64); config=ctest_config(stack_limit=48))
        @test wasm_run(c, "ct_varargs", Cint(3), 0.5; rettype=typeof(ct_varargs(Cint(3), 0.5)),
                       cmodule=CTEST_JS[]) == ct_varargs(Cint(3), 0.5)
    end
    # a struct by value as a variadic argument
    f(v::CtVec2) = @ccall libctest.ct_vsum(1::Cint; v::CtVec2)::Cint
    msg = ct_unsupported(f, (CtVec2,))
    @test msg isa String && occursin("the variadic argument of type CtVec2", msg)
end
