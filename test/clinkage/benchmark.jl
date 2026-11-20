# Micro-benchmarks of the C linkage (`Config(c_linkage)`), not part of the tests: the same
# Julia functions natively (calling test/clinkage/ctest.c as a shared library) and compiled to
# Wasm, linked with the library built by emscripten (-m64), in Node.js. In the toolchains of
# test/clinkage/shell.nix:
#
#     nix-shell test/clinkage/shell.nix --run 'julia --project=test test/clinkage/benchmark.jl'
#
# - a scalar C call in a loop;
# - a call passing a Vector{Float64} of 10^5 elements (copied to C memory and back);
# - loads and stores through a pointer into C memory (Libc.malloc), vs the same natively;
# - a call taking two small structs by value (ImVec2-like) in a loop;
# - a call whose pointer argument may point into a Julia object (its owner is not known where
#   the call is compiled) but is a C address when it runs;
# - a call passing a small string (a Julia object: copied for each call).

using WasmCodegen
import NodeJS_24_jll

global libctest::String = ""

function build(dir)
    src = joinpath(@__DIR__, "ctest.c")
    native = joinpath(dir, "libctest." * Base.Libc.Libdl.dlext)
    run(`clang -shared -fPIC -O2 -o $native $src`)
    js = joinpath(dir, "ctest.mjs")
    exports = "_malloc,_free,_emscripten_stack_get_current,__emscripten_stack_alloc,__emscripten_stack_restore"
    run(`emcc -m64 -O2 $src -o $js -sMODULARIZE -sEXPORT_ES6 -sENVIRONMENT=node -sALLOW_MEMORY_GROWTH -sEXPORTED_FUNCTIONS=$exports`)
    return native, js
end

function bench_scalar(n::Int)
    s = Int32(0)
    for i in 1:n
        s += ccall((:ct_mul32, libctest), Int32, (Int32, Int32), i % Int32, Int32(3))
    end
    return s
end

const BENCH_N = 100_000
function bench_array(reps::Int)
    v = [i * 0.5 for i in 1:BENCH_N]
    s = 0.0
    for _ in 1:reps
        s += ccall((:ct_sum_f64, libctest), Float64, (Ptr{Float64}, Csize_t), v, BENCH_N)
    end
    return s
end

function bench_memory(reps::Int)
    p = Ptr{Float64}(Libc.malloc(8 * BENCH_N))
    s = 0.0
    for r in 1:reps
        for i in 1:BENCH_N
            unsafe_store!(p, i * 0.25 + r, i)
        end
        for i in 1:BENCH_N
            s += unsafe_load(p, i)
        end
    end
    Libc.free(p)
    return s
end

struct Vec2
    x::Float32
    y::Float32
end
function bench_vec2(n::Int)
    s = 0.0f0
    for i in 1:n
        s += ccall((:ct_vec2_dot, libctest), Float32, (Vec2, Vec2), Vec2(i, 1), Vec2(0.5f0, s))
    end
    return s
end

@noinline sum_at(p::Ptr{Float64}, n::Int) = ccall((:ct_sum_f64, libctest), Float64, (Ptr{Float64}, Csize_t), p, n)
function bench_cptr(n::Int)
    p = Ptr{Float64}(Libc.malloc(32))
    for i in 1:4
        unsafe_store!(p, i * 0.5, i)
    end
    s = 0.0
    for _ in 1:n
        s += sum_at(p, 4)
    end
    Libc.free(p)
    return s
end

function bench_string(n::Int)
    s = UInt(0)
    for _ in 1:n
        s += ccall((:ct_count_char, libctest), Csize_t, (Cstring, Cchar), "hello, world", Cchar('o'))
    end
    return s
end

# the native time per call of `f(arg)` (the best of 5, after a warm-up)
function native_time(f, arg)
    f(arg)
    return minimum(@elapsed(f(arg)) for _ in 1:5)
end

function main()
    dir = mktempdir()
    native, js = build(dir)
    global libctest = native
    entries = [(bench_scalar, (Int,)), (bench_array, (Int,)), (bench_memory, (Int,)), (bench_vec2, (Int,)),
               (bench_cptr, (Int,)), (bench_string, (Int,))]
    c = WasmCodegen.compile(entries; config=WasmCodegen.Config(c_linkage=CLinkage(libraries=[libctest])))
    write(joinpath(dir, "m.wasm"), c.bytes)
    args = [("bench_scalar", 1_000_000), ("bench_array", 100), ("bench_memory", 100), ("bench_vec2", 1_000_000),
            ("bench_cptr", 1_000_000), ("bench_string", 1_000_000)]
    write(joinpath(dir, "run.mjs"), """
    import fs from 'node:fs';
    import create from $(repr(js));
    import { createHost } from $(repr(WasmCodegen.JS_HOST));
    let raw;
    await create({ instantiateWasm(imports, done) {
      WebAssembly.instantiate(fs.readFileSync($(repr(replace(js, ".mjs" => ".wasm")))), imports)
        .then(({ instance }) => { raw = instance.exports; done(instance); });
      return {};
    } });
    const host = createHost();
    const { instance } = await WebAssembly.instantiate(fs.readFileSync($(repr(joinpath(dir, "m.wasm")))),
                                                       { julia: host.imports.julia, c: raw });
    const out = {};
    for (const [fn, n] of $(sprint(print, "[" * join(["[\"$f\", $n]" for (f, n) in args], ", ") * "]"))) {
      const f = instance.exports[fn];
      f(BigInt(n));
      let best = Infinity, r;
      for (let k = 0; k < 5; k++) { const t = performance.now(); r = f(BigInt(n)); best = Math.min(best, performance.now() - t); }
      out[fn] = [best / 1000, String(r)];
    }
    process.stdout.write(JSON.stringify(out));
    """)
    res = read(`$(NodeJS_24_jll.node()) $(joinpath(dir, "run.mjs"))`, String)
    wasm = Dict(m[1] => (parse(Float64, m[2]), m[3]) for m in eachmatch(r"\"(\w+)\":\[([0-9.e+-]+),\"([^\"]*)\"\]", res))
    println(rpad("benchmark", 34), rpad("native", 14), rpad("wasm", 14), "ratio")
    for ((f, _), (name, n)) in zip(entries, args)
        t = native_time(f, n)
        w, r = wasm[name]
        x = f(n)
        x == parse(typeof(x), r) || @warn "results differ" name native = x wasm = r
        what = name == "bench_scalar" ? "$n scalar calls" : name == "bench_array" ? "$n calls, $BENCH_N Float64 each" :
               name == "bench_memory" ? "$n x $BENCH_N stores + loads" : name == "bench_vec2" ? "$n calls, 2 Vec2 by value" :
               name == "bench_cptr" ? "$n calls, a C address (maybe owned)" : "$n calls, a 12-byte String"
        println(rpad(what, 34), rpad(string(round(t * 1e3; digits=3), " ms"), 14),
                rpad(string(round(w * 1e3; digits=3), " ms"), 14), round(w / t; digits=1), "x")
    end
end

main()
