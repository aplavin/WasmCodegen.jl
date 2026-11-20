# Linking with a C module (`Config(c_linkage)`, `CLinkage`): a C library compiled to Wasm
# separately, for wasm64 (emscripten's `-m64`), owns the only linear memory. The module
# imports that memory and the C functions its `ccall`s name; a pointer without owner is an
# address in that memory (`pointers.jl`: loads and stores through it are the memory's), and a
# call passes its arguments as the C ABI of wasm64 does (clang's `WebAssemblyABIInfo`):
#
# - integers of up to 32 bits and `Bool` are `i32`s (small ones extended as their type's
#   signedness says: an enum's by its integer type), 64-bit integers `i64`s, `Float32` and
#   `Float64` `f32` and `f64`, pointers (`Ptr`, `Ref`, `Cstring`, `Cwstring`) `i64` addresses;
# - an isbits struct or tuple by value: none if empty, its scalar if it holds one (through
#   structs of one field), else the address of a copy the caller makes; a result of such a
#   struct is written by the callee at an address the caller gives as a first parameter (sret);
# - a variadic call (`nreq > 0`) passes the variadic arguments in a buffer, each at its
#   alignment (as the declared types say: no default promotion, as Julia's `ccall`), as one more
#   `i64` parameter.
#
# A pointer into a Julia object (with an owner) is passed as the address of a copy of its
# owner, made for the call (`Runtime.CLink`), and copied back after it into a mutable owner.
# The space a call needs (copies, structs by value, results, variadic arguments) is the C
# stack's (`CLinkage(stack_save, stack_alloc, stack_restore)`), or the C heap's past
# `stack_limit` bytes, released when the call returns or throws.

"The library of the primitives `Runtime.CLink` calls (`emit_clink_primitive!`)."
const CLINK_LIBRARY = Runtime.CLink.LIBRARY

"The C library's functions `Libc` calls (by name, without a library): the C module's allocator's."
const C_ALLOCATOR_FUNCTIONS = (:malloc, :calloc, :realloc, :free)

"Check `Config(c_linkage)`: a 64-bit C module, a host interface without a memory of its own."
function check_c_linkage(config)
    cl = config.c_linkage
    cl === nothing && return
    cl.memory64 || throw(ArgumentError(string(
        "Config(c_linkage): only C modules with a 64-bit memory (memory64: emscripten's -m64, ",
        "clang's wasm64) are supported, whose pointers and size_t are 8 bytes as Julia's")))
    config.host === :js || throw(ArgumentError(string(
        "Config(c_linkage) with host = :$(config.host): WASI's calls pass data through a memory of ",
        "the module's own, and the C module's memory is the module's only one; use host = :js")))
    isempty(cl.libraries) && throw(ArgumentError("Config(c_linkage): no libraries"))
    cl.stack_limit >= 0 || throw(ArgumentError("Config(c_linkage): a negative stack_limit"))
    for lib in cl.libraries
        s = String(lib)
        isempty(s) && throw(ArgumentError("Config(c_linkage): an empty library name"))
        reserved_import_library(s) &&
            throw(ArgumentError("Config(c_linkage): \"$s\" is a name of WasmCodegen's own imports"))
        lib in config.import_libraries &&
            throw(ArgumentError("Config(c_linkage): \"$s\" is also a library of host imports (import_libraries)"))
        any(((_, l),) -> l == lib, first.(config.foreign_functions)) &&
            throw(ArgumentError("Config(c_linkage): \"$s\" is also a library of foreign_functions"))
    end
    reserved_import_library(cl.import_module) &&
        throw(ArgumentError("Config(c_linkage): \"$(cl.import_module)\" is a module of WasmCodegen's own imports"))
end

"Whether a module compiled with `cgm` is linked with a C module (`Config(c_linkage)`)."
c_linked(cgm::CGModule) = cgm.config.c_linkage !== nothing
c_linked(fc::FnCtx) = c_linked(fc.cgm)

"""
Whether `ccall((name, lib), ...)` (`lib` a `String`, a `Symbol` or `nothing`) is a call of the
C module: of one of its libraries, or of `Libc`'s allocator.
"""
function is_c_function(cgm::CGModule, @nospecialize(lib), name::Symbol)
    cl = cgm.config.c_linkage
    cl === nothing && return false
    lib === nothing && return name in C_ALLOCATOR_FUNCTIONS
    return lib in cl.libraries
end

## the C ABI of wasm64

"""
    CAbi(kind, type)

How a value of a type of a C signature is passed: `:none` (nothing: `Cvoid`, an empty
struct), `:scalar` (one Wasm value, of the primitive or pointer type `type` the value is or
holds), `:pointer` (a declared pointer, to values of type `type`: an address, a copy of its
owner for a pointer into a Julia object), `:indirect` (the address of a copy; for a result, of
the space the callee writes it to).
"""
struct CAbi
    kind::Symbol
    type::Any
end

# the type of the values of a declared pointer type
c_pointee(@nospecialize(T)) = is_ref_type(T) ? T.parameters[1] : T === Cstring ? UInt8 :
                              T === Cwstring ? Cwchar_t : eltype(T)

# the primitive or pointer type of the one scalar an isbits struct holds (through structs
# and tuples of one field), or nothing
function single_scalar(@nospecialize(T))
    while !(isprimitivetype(T) || is_ptr_type(T))
        (isstructtype(T) && fieldcount(T) == 1 && sizeof(fieldtype(T, 1)) == sizeof(T)) || return nothing
        T = fieldtype(T, 1)
    end
    return T
end

# whether the primitive type `P` is passed as a scalar, an integer or a float of 1 to 8 bytes
c_scalar_ok(@nospecialize(P)) =
    is_ptr_type(P) || P === Float32 || P === Float64 ||
    (!(P <: AbstractFloat) && sizeof(P) in (1, 2, 4, 8))

"The Wasm type of the scalar `P` in the C ABI."
c_scalar_wtype(@nospecialize(P)) =
    is_ptr_type(P) ? I64 : P === Float32 ? F32 : P === Float64 ? F64 : sizeof(P) == 8 ? I64 : I32

"Whether the integer (or enum) `P` is signed: its small values are sign-extended to an `i32`."
c_signed(@nospecialize(P)) = P <: Signed || (P <: Enum && Base.Enums.basetype(P) <: Signed)

"""
    c_abi(T, result) -> CAbi

How a value of the declared type `T` is passed (an argument, or with `result` the result), or
an error (`Unsupported`) naming what cannot be.
"""
function c_abi(@nospecialize(T), result::Bool)
    result && (T === Cvoid || T === Nothing) && return CAbi(:none, Nothing)
    T isa DataType || unsupported("the type ", T, ", which is not a concrete type")
    if is_ptr_type(T) || (!result && is_ref_type(T))
        return CAbi(:pointer, c_pointee(T))
    end
    if isprimitivetype(T)
        c_scalar_ok(T) || unsupported("the type ", T, ", which no scalar of the C ABI of wasm64 is")
        return CAbi(:scalar, T)
    end
    (isbitstype(T) && !ismutabletype(T)) ||
        unsupported("the type ", T, " by value, which is not an isbits struct or tuple")
    sizeof(T) == 0 && return CAbi(:none, T)
    S = single_scalar(T)
    if S !== nothing
        c_scalar_ok(S) || unsupported("the type ", T, ", holding a ", S, ", which no scalar of the C ABI of wasm64 is")
        return CAbi(:scalar, S)
    end
    return CAbi(:indirect, T)
end

## calls

"""
    emit_c_call!(fc, name, ex, args, typ) -> CGVal

`ccall((name, lib), RT, (AT...), args...)` of a library of the C module: a call of its export
`name`, imported (`import_module.name`) with the Wasm type the C ABI gives the declared
signature (one import per name: calls declaring other signatures are an error). See the
beginning of this file.
"""
function emit_c_call!(fc::FnCtx, name::Symbol, ex::Expr, args::Vector{Any}, @nospecialize(typ))
    lib = foreigncall_library(ex.args[1], fc.cgm.world.world)
    lib === nothing && return emit_c_allocator!(fc, name, args, typ)
    cgm = fc.cgm
    cl = cgm.config.c_linkage::CLinkage
    RT = ex.args[2]
    ATs = collect(Any, ex.args[3]::Core.SimpleVector)
    nreq = ex.args[4]::Int
    vals = CGVal[a::CGVal for a in args]
    what = ("the C function ", name, " (", lib, ")")
    # (the signature, all of it first: a type that cannot be passed is reported before any code)
    local rabi, aabis
    try
        rabi = c_abi(RT, true)
        aabis = CAbi[c_abi(T, false) for T in ATs]
        for k in (nreq > 0 ? (nreq+1:length(ATs)) : (1:0))
            (aabis[k].kind === :pointer || (aabis[k].kind === :scalar && isprimitivetype(ATs[k]))) ||
                unsupported("the variadic argument of type ", ATs[k], " (variadic arguments are scalars or pointers)")
        end
    catch err
        err isa Unsupported || rethrow()
        push!(err.parts, " of a ccall of "); append!(err.parts, what)
        rethrow()
    end
    for (k, (v, T, a)) in enumerate(zip(vals, ATs, aabis))
        a.kind === :pointer && !is_ptr_type(v.typ) &&
            unsupported("a ", v.typ, " as the argument ", k, " (declared ", T, ") of a ccall of ", what...)
    end
    variadic = nreq > 0
    fixed = variadic ? (1:nreq) : eachindex(ATs)
    # pointers that may point into Julia objects: copied for the call, and back after it
    owned = [k for k in eachindex(ATs) if aabis[k].kind === :pointer && !ownerless(vals[k])]
    space = rabi.kind === :indirect || variadic || !isempty(owned) || any(a -> a.kind === :indirect, aabis)
    guarded = space && cgm.exceptions !== :none
    frame = space ? call_runtime!(fc, Runtime.CLink.enter, CGVal[]) : nothing
    if guarded
        # (the space is released when the call throws too: the exception thrown on after)
        block!(fc.b); open_label!(fc)
        block!(fc.b, RefType(:exn, false)); open_label!(fc)
        try_table!(fc.b, :empty, [(3, nothing, 0)]); open_label!(fc)
    end
    params, pushes = ValType[], LeafVal[]
    if rabi.kind === :indirect
        sret = c_scratch!(fc, sizeof(RT), Base.datatype_alignment(RT))
        push!(params, I64); push!(pushes, sret)
    end
    addrs = Dict{Int,Int}()
    for k in owned
        addrs[k] = c_pointer_address!(fc, vals[k])
    end
    for k in fixed
        a, v, T = aabis[k], vals[k], ATs[k]
        if a.kind === :scalar
            t = c_scalar_wtype(a.type)
            push_c_scalar!(fc, v, T, a.type)
            l = new_local!(fc, t); emit!(fc.b, :local_set, l)
            push!(params, t); push!(pushes, l)
        elseif a.kind === :pointer
            push!(params, I64); push!(pushes, get(addrs, k, v.leaves[1]))
        elseif a.kind === :indirect
            c = c_scratch!(fc, sizeof(T), Base.datatype_alignment(T))
            c_store!(fc, c_pointer(fc, c, T), convert_repr(fc, v, T), const_value(fc, 1);
                     err=Runtime.CLink.throw_owned_field)
            push!(params, I64); push!(pushes, c)
        end
    end
    if variadic
        push!(params, I64); push!(pushes, c_varargs!(fc, vals, ATs, aabis, nreq, addrs))
    end
    results = rabi.kind === :scalar ? ValType[c_scalar_wtype(rabi.type)] :
              rabi.kind === :pointer ? ValType[I64] : ValType[]
    foreach(l -> push_leaf!(fc, l), pushes)
    call!(fc.b, c_import!(cgm, name, params, results))
    res = if rabi.kind === :scalar
        pop_c_scalar!(fc, RT, rabi.type)
    elseif rabi.kind === :pointer
        a = new_local!(fc, I64); emit!(fc.b, :local_set, a)
        CGVal(RT, Inline, LeafVal[a, Inst(:ref_null, cgm.types.jlvalue)])
    elseif rabi.kind === :indirect
        c_load!(fc, c_pointer(fc, pushes[1]::Int, RT), const_value(fc, 1), RT)
    else
        RT === Cvoid || RT === Nothing ? ghost(Nothing, nothing) : ghost(RT, something(ghost_value(RT)))
    end
    for k in owned
        call_runtime!(fc, Runtime.CLink.from_c!, CGVal[void_ptr(vals[k])])
    end
    if space
        call_runtime!(fc, Runtime.CLink.leave, CGVal[frame])
    end
    if guarded
        br!(fc.b, 2)
        end!(fc.b); close_label!(fc)
        unreachable!(fc.b)
        end!(fc.b); close_label!(fc)
        exn = new_local!(fc, RefType(:exn, false))
        emit!(fc.b, :local_set, exn)
        call_runtime!(fc, Runtime.CLink.leave, CGVal[frame])
        emit!(fc.b, :local_get, exn)
        throw_ref!(fc.b)
        end!(fc.b); close_label!(fc)
    end
    return convert_repr(fc, res, typ)
end

# the pointer `p` as a `Ptr{Cvoid}` (its leaves)
void_ptr(p::CGVal) = CGVal(Ptr{Cvoid}, Inline, p.leaves)

"The owner-less pointer of type `Ptr{T}` at the C address in the local `a`."
c_pointer(fc::FnCtx, a::Int, @nospecialize(T)) =
    CGVal(Ptr{T}, Inline, LeafVal[a, Inst(:ref_null, fc.cgm.types.jlvalue)])

"`n` bytes of space for the call, aligned to `align`: a local holding their address."
function c_scratch!(fc::FnCtx, n::Integer, align::Integer)
    r = call_runtime!(fc, Runtime.CLink.scratch, CGVal[const_value(fc, Int(n)), const_value(fc, Int(align))])
    return materialize!(fc, r)
end

"""
The address standing for the pointer argument `p` in the C module's memory: its own without an
owner, else that of the copy of its owner made for the call (`Runtime.CLink.to_c`). A local.
"""
function c_pointer_address!(fc::FnCtx, p::CGVal)
    a = new_local!(fc, I64)
    push_leaf!(fc, ptr_owner(p)); emit!(fc.b, :ref_is_null)
    if!(fc.b, I64)
    push_leaf!(fc, p.leaves[1])
    else!(fc.b)
    push_val!(fc, call_runtime!(fc, Runtime.CLink.to_c, CGVal[void_ptr(p)]))
    end!(fc.b)
    emit!(fc.b, :local_set, a)
    return a
end

# push the scalar `P` the argument `v` of the declared type `T` is or holds, as the C ABI
# passes it: a small integer extended by its signedness; a pointer (in a struct by value) by
# its address, which may not be into a Julia object
function push_c_scalar!(fc::FnCtx, v::CGVal, @nospecialize(T), @nospecialize(P))
    x = convert_repr(fc, v, T)
    if is_ptr_type(P)
        check_ownerless!(fc, ptr_owner(x), Runtime.CLink.throw_owned_field)
        push_leaf!(fc, x.leaves[1])
        return
    end
    push_leaf!(fc, only(x.leaves))
    if sizeof(P) < 4 && c_signed(P)
        emit!(fc.b, sizeof(P) == 1 ? :i32_extend8_s : :i32_extend16_s)
    end
end

# the result of type `RT`, the scalar `P` on the stack: a small integer as Julia keeps it
# (zero-extended), a pointer without owner
function pop_c_scalar!(fc::FnCtx, @nospecialize(RT), @nospecialize(P))
    t = c_scalar_wtype(P)
    if is_ptr_type(P)
        a = new_local!(fc, I64); emit!(fc.b, :local_set, a)
        leaves = LeafVal[a, Inst(:ref_null, fc.cgm.types.jlvalue)]
    else
        sizeof(P) < 4 && (emit!(fc.b, :i32_const, (1 << 8sizeof(P)) - 1); emit!(fc.b, :i32_and))
        r = new_local!(fc, t); emit!(fc.b, :local_set, r)
        leaves = LeafVal[r]
    end
    l = layout(fc, RT)
    (l.kind === Inline && length(l.leaves) == length(leaves)) || unsupported("a C result of type ", RT)
    return CGVal(RT, Inline, leaves)
end

# the error `err` (a runtime function, which writes its message to stderr too: see
# `Runtime.CLink.c_error`) unless the owner leaf `owner` is null; called whatever the module's
# exceptions, so that its message is written where nothing catches it
function check_ownerless!(fc::FnCtx, owner::LeafVal, @nospecialize(err))
    owner isa Inst && owner.op === :ref_null && return
    push_leaf!(fc, owner); emit!(fc.b, :ref_is_null); emit!(fc.b, :i32_eqz)
    if!(fc.b)
    call_runtime!(fc, err, CGVal[])
    is_unreachable(fc.b) || unreachable!(fc.b)
    end!(fc.b)
    return
end

"""
The buffer of the variadic arguments (from `nreq + 1`) of a call: each at its alignment, as
its declared type says (a pointer as its address: `addrs`, else its own). A local.
"""
function c_varargs!(fc::FnCtx, vals::Vector{CGVal}, ATs::Vector{Any}, abis::Vector{CAbi}, nreq::Int,
                    addrs::Dict{Int,Int})
    offs = Int[]
    off = 0
    for k in nreq+1:length(ATs)
        s = abis[k].kind === :pointer ? 8 : sizeof(abis[k].type)
        off = cld(off, s) * s
        push!(offs, off)
        off += s
    end
    c_memory!(fc.cgm)
    buf = c_scratch!(fc, off, 16)
    for (j, k) in enumerate(nreq+1:length(ATs))
        a = abis[k]
        emit!(fc.b, :local_get, buf)
        if a.kind === :pointer
            push_leaf!(fc, get(addrs, k, vals[k].leaves[1]))
            emit!(fc.b, :i64_store, 3, offs[j])
        else
            P = a.type
            push_c_scalar!(fc, vals[k], ATs[k], P)
            n = is_ptr_type(P) ? 8 : sizeof(P)
            emit!(fc.b, c_access_op(c_scalar_wtype(P), n, true), trailing_zeros(n), offs[j])
        end
    end
    return buf
end

"""
    c_import!(cgm, name, params, results) -> Func

The import of the C module's function `name`, of the Wasm type `params -> results`: one per
name, so all calls of it must declare signatures of one Wasm type (as natively one function
has one type).
"""
function c_import!(cgm::CGModule, name::Symbol, params::Vector{ValType}, results::Vector{ValType})
    cl = cgm.config.c_linkage::CLinkage
    sigs = get!(() -> Dict{Symbol,Any}(), cgm.helpers, :c_imports)
    sig = get!(sigs, name, (params, results))
    sig == (params, results) ||
        unsupported("calls of the C function ", name, " with two Wasm types: (", join(sig[1], ", "), ") -> (",
                    join(sig[2], ", "), ") and (", join(params, ", "), ") -> (", join(results, ", "), ")")
    return add_import!(cgm.mod, cl.import_module, String(name), params, results)
end

## Libc's allocator, and the primitives of `Runtime.CLink`

"""
`Libc.malloc`, `calloc`, `realloc` and `free` (a `ccall` of the C library's without a
library): the C module's allocator. `free` of a pointer into a Julia object does nothing (its
object is the garbage collector's, as without a C module); `realloc` of one is an error.
"""
function emit_c_allocator!(fc::FnCtx, name::Symbol, args::Vector{Any}, @nospecialize(typ))
    f = name === :malloc ? Runtime.CLink.c_malloc : name === :calloc ? Runtime.CLink.c_calloc :
        name === :realloc ? Runtime.CLink.c_realloc : Runtime.CLink.c_free
    ts = name === :malloc ? (UInt,) : name === :calloc ? (UInt, UInt) :
         name === :realloc ? (Ptr{Cvoid}, UInt) : (Ptr{Cvoid},)
    length(args) == length(ts) || unsupported("a ccall of ", name, " with ", length(args), " arguments")
    vals = CGVal[convert_repr(fc, a::CGVal, T) for (a, T) in zip(args, ts)]
    res = call_runtime!(fc, f, vals)
    return res.kind === Ghost ? ghost(Nothing, nothing) : convert_repr(fc, res, typ)
end

"""
    emit_clink_primitive!(fc, name, args, typ) -> CGVal

A primitive of `Runtime.CLink` (a `ccall` of its library): `linked` and `stack_limit` (constants
of the module), the C module's `stack_save`, `stack_alloc`, `stack_restore`, `malloc`, `free`,
`calloc`, `realloc` (imports, named by `Config(c_linkage)`), `memmove` and `memset` of its memory
(`memory.copy`, `memory.fill`), and the helpers `owner_nbytes` and `copy_elements`, generated
with the module's types (`finish_clinkage!`). In a module without a C module, which never
calls them (`linked()` is false), a trap.
"""
function emit_clink_primitive!(fc::FnCtx, @nospecialize(name), args::Vector{Any}, @nospecialize(typ))
    cgm = fc.cgm
    cl = cgm.config.c_linkage
    name === :linked && return const_value(fc, cl !== nothing)
    name === :stack_limit && return const_value(fc, cl === nothing ? 0 : cl.stack_limit)
    if cl === nothing
        unreachable!(fc.b)
        return bottom()
    end
    vals = CGVal[a::CGVal for a in args]
    imports = (stack_save=(cl.stack_save, ValType[], ValType[I64]),
               stack_alloc=(cl.stack_alloc, ValType[I64], ValType[I64]),
               stack_restore=(cl.stack_restore, ValType[I64], ValType[]),
               malloc=(cl.malloc, ValType[I64], ValType[I64]), free=(cl.free, ValType[I64], ValType[]),
               calloc=("calloc", ValType[I64, I64], ValType[I64]),
               realloc=("realloc", ValType[I64, I64], ValType[I64]))
    if name in keys(imports)
        n, params, results = imports[name]
        foreach(v -> push_val!(fc, v), vals)
        call!(fc.b, c_import!(cgm, Symbol(n), params, results))
        return isempty(results) ? ghost(Nothing, nothing) : pop_val!(fc, typ)
    elseif name === :memmove || name === :memset
        c_memory!(cgm)
        foreach(v -> push_val!(fc, v), vals)
        emit!(fc.b, name === :memmove ? :memory_copy : :memory_fill, (name === :memmove ? (0, 0) : (0,))...)
        return ghost(Nothing, nothing)
    elseif name === :owner_nbytes || name === :copy_elements
        foreach(v -> push_val!(fc, v), vals)
        call!(fc.b, c_helper!(cgm, name))
        return pop_val!(fc, typ)
    end
    unsupported("the primitive ", name, " of Runtime.CLink")
end

"The function of the helper `name` (`:owner_nbytes`, `:copy_elements`), whose body `finish_clinkage!` makes."
function c_helper!(cgm::CGModule, name::Symbol)
    get!(cgm.helpers, (:clink, name)) do
        jl = jlvalue_ref(cgm.types)
        name === :owner_nbytes ? add_func!(cgm.mod, "jl_c_owner_nbytes", ValType[jl], ValType[I64]) :
            add_func!(cgm.mod, "jl_c_copy_elements", ValType[jl, I64, I64, I64, I32], ValType[I32])
    end
end

"""
    finish_clinkage!(cgm)

The bodies of the helpers of `Runtime.CLink` over the module's types, by the type id of the
object: `jl_c_owner_nbytes(o)`, the bytes of `o` as natively laid out (of a string or symbol,
of a memory whose bytes the pointer helpers address, of a mutable object whose fields they
address), else -1; `jl_c_copy_elements(o, off, c, n, back)`, for a memory whose elements are
stored as natively laid out (and a string or symbol), the `n` bytes of its array from its byte
`off` copied to the C module's memory at `c` (or back), one element at a time (of whole elements
only: else 0).
"""
function finish_clinkage!(cgm::CGModule)
    f = get(cgm.helpers, (:clink, :owner_nbytes), nothing)
    f === nothing || finish_owner_nbytes!(cgm, f::Func)
    f = get(cgm.helpers, (:clink, :copy_elements), nothing)
    f === nothing || finish_copy_elements!(cgm, f::Func)
end

# push whether the type id in the local `tid` is one of `ids`
function push_tid_in!(b::Builder, tid::Int, ids)
    for (k, id) in enumerate(ids)
        emit!(b, :local_get, tid); emit!(b, :i32_const, id); emit!(b, :i32_eq)
        k > 1 && emit!(b, :i32_or)
    end
end

function finish_owner_nbytes!(cgm::CGModule, f::Func)
    ts = cgm.types
    b = Builder(cgm.mod, f)
    tid = add_local!(f, I32)
    emit!(b, :local_get, 0); emit!(b, :struct_get, ts.jlvalue, 0); emit!(b, :local_set, tid)
    for ((st, at, stg), ids) in byte_owners(cgm)
        push_tid_in!(b, tid, ids)
        if!(b)
        emit!(b, :local_get, 0); emit!(b, :ref_cast, st); emit!(b, :struct_get, st, DATA_FIELD)
        emit!(b, :array_len); emit!(b, :i64_extend_i32_u)
        s = storage_bytes(stg)
        s != 1 && (emit!(b, :i64_const, s); emit!(b, :i64_mul))
        return!(b)
        end!(b)
    end
    for (id, st, at, stg, esz, stride, _) in leaf_memory_owners(cgm)
        push_tid_in!(b, tid, (id,))
        if!(b)
        emit!(b, :local_get, 0); emit!(b, :ref_cast, st); emit!(b, :struct_get, st, DATA_FIELD)
        emit!(b, :array_len); emit!(b, :i64_extend_i32_u)
        emit!(b, :i64_const, stride); emit!(b, :i64_div_u)
        emit!(b, :i64_const, esz); emit!(b, :i64_mul)
        return!(b)
        end!(b)
    end
    for (id, _, _) in object_owners(cgm)
        push_tid_in!(b, tid, (id,))
        if!(b)
        emit!(b, :i64_const, sizeof(cgm.types.typelist[id])); return!(b)
        end!(b)
    end
    emit!(b, :i64_const, -1)
    finish!(b)
end

function finish_copy_elements!(cgm::CGModule, f::Func)
    ts = cgm.types
    c_memory!(cgm)
    b = Builder(cgm.mod, f)
    tid, i, n, addr = add_local!(f, I32), add_local!(f, I32), add_local!(f, I32), add_local!(f, I64)
    arrays = Dict{TypeRef,Int}()
    emit!(b, :local_get, 0); emit!(b, :struct_get, ts.jlvalue, 0); emit!(b, :local_set, tid)
    for ((st, at, stg), ids) in byte_owners(cgm)
        s = storage_bytes(stg)
        t = stg isa PackedType ? I32 : stg
        a = get!(() -> add_local!(f, RefType(at, true)), arrays, at)
        push_tid_in!(b, tid, ids)
        if!(b)
        emit!(b, :local_get, 0); emit!(b, :ref_cast, st); emit!(b, :struct_get, st, DATA_FIELD)
        emit!(b, :local_set, a)
        if s > 1
            # (whole elements of the array only: else the caller copies by bytes)
            emit!(b, :local_get, 1); emit!(b, :local_get, 3); emit!(b, :i64_or)
            emit!(b, :i64_const, s - 1); emit!(b, :i64_and); emit!(b, :i64_const, 0); emit!(b, :i64_ne)
            if!(b); emit!(b, :i32_const, 0); return!(b); end!(b)
        end
        # (within the array: else, as past a string's end, the caller copies by bytes)
        emit!(b, :local_get, 1); emit!(b, :local_get, 3); emit!(b, :i64_add)
        emit!(b, :local_get, a); emit!(b, :array_len); emit!(b, :i64_extend_i32_u)
        s != 1 && (emit!(b, :i64_const, s); emit!(b, :i64_mul))
        emit!(b, :i64_gt_u)
        if!(b); emit!(b, :i32_const, 0); return!(b); end!(b)
        # (the elements from the one at byte `off`, `n` bytes of them)
        emit!(b, :local_get, 1); emit!(b, :i64_const, s); emit!(b, :i64_div_u); emit!(b, :i32_wrap_i64)
        emit!(b, :local_set, i)
        emit!(b, :local_get, 1); emit!(b, :local_get, 3); emit!(b, :i64_add)
        emit!(b, :i64_const, s); emit!(b, :i64_div_u); emit!(b, :i32_wrap_i64)
        emit!(b, :local_set, n)
        emit!(b, :local_get, 2); emit!(b, :local_set, addr)
        block!(b); loop!(b)
        emit!(b, :local_get, i); emit!(b, :local_get, n); emit!(b, :i32_ge_u); br_if!(b, 1)
        emit!(b, :local_get, 4)
        if!(b)
        # back: the array's element from the memory
        emit!(b, :local_get, a); emit!(b, :local_get, i)
        emit!(b, :local_get, addr); emit!(b, c_access_op(t, s, false), trailing_zeros(s), 0)
        emit!(b, :array_set, at)
        else!(b)
        emit!(b, :local_get, addr)
        emit!(b, :local_get, a); emit!(b, :local_get, i)
        emit!(b, stg isa PackedType ? :array_get_u : :array_get, at)
        emit!(b, c_access_op(t, s, true), trailing_zeros(s), 0)
        end!(b)
        emit!(b, :local_get, i); emit!(b, :i32_const, 1); emit!(b, :i32_add); emit!(b, :local_set, i)
        emit!(b, :local_get, addr); emit!(b, :i64_const, s); emit!(b, :i64_add); emit!(b, :local_set, addr)
        br!(b, 0)
        end!(b); end!(b)
        emit!(b, :i32_const, 1); return!(b)
        end!(b)
    end
    emit!(b, :i32_const, 0)
    finish!(b)
end
