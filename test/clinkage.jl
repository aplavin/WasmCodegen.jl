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

