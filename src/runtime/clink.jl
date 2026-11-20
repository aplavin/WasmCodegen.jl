"""
    CLink

The run-time side of calls into the C module a module is linked with (`Config(c_linkage)`,
`clinkage.jl`). The C module owns the only linear memory; a Julia object is not in it, so a
pointer into one (a pointer with an owner) is passed to C as the address of a copy of its
owner, made for the call in the space the call allocates (`scratch`: the C stack, or the C
heap past `stack_limit()` bytes), and copied back into the owner after the call when the owner
is mutable (`to_c`, `back!`). Every pointer of a call into the same owner shares one copy,
as natively they point into the same object, and an address C gives back into a copy is a
pointer into its object again (`from_c`).

The primitives (`ccall`s of the library `LIBRARY`) are compiled by the code generator: to the C
module's imports (its stack and allocator), to the memory's instructions, and to helpers over
the module's types; natively they are never called.
"""
module CLink

import ..ptr_owner, ..ptr_offset
import ..Runtime

"The library of the primitives the code generator compiles (`emit_clink_primitive!`)."
const LIBRARY = "julia_c"

## primitives

"Whether the module is linked with a C module (a constant of the module)."
linked() = ccall((:linked, LIBRARY), Bool, ())
"The bytes of the C stack one call may use (`CLinkage(stack_limit)`)."
stack_limit() = ccall((:stack_limit, LIBRARY), Int, ())
"The C stack pointer."
stack_save() = ccall((:stack_save, LIBRARY), UInt64, ())
"`n` bytes on the C stack, aligned to 16."
stack_alloc(n::UInt64) = ccall((:stack_alloc, LIBRARY), UInt64, (UInt64,), n)
"The C stack pointer back to `sp`."
stack_restore(sp::UInt64) = ccall((:stack_restore, LIBRARY), Cvoid, (UInt64,), sp)
"`n` bytes of the C heap (0 if it has none)."
malloc(n::UInt64) = ccall((:malloc, LIBRARY), UInt64, (UInt64,), n)
"Frees the block `p` of the C heap."
free(p::UInt64) = ccall((:free, LIBRARY), Cvoid, (UInt64,), p)
"`memmove` within the C module's memory (`memory.copy`)."
memmove(dst::UInt64, src::UInt64, n::UInt64) = ccall((:memmove, LIBRARY), Cvoid, (UInt64, UInt64, UInt64), dst, src, n)
"`memset` of the C module's memory (`memory.fill`)."
memset(dst::UInt64, b::UInt8, n::UInt64) = ccall((:memset, LIBRARY), Cvoid, (UInt64, UInt8, UInt64), dst, b, n)
"""
The bytes of the object `o` as Julia lays them out natively: of a memory, its elements' (of a
string or symbol, its bytes, without the NUL after them); of a mutable object, its fields'; -1
for an object whose bytes are not addressable (a memory of references or of elements stored
otherwise than natively).
"""
owner_nbytes(@nospecialize(o)) = ccall((:owner_nbytes, LIBRARY), Int, (Any,), o)
"""
Copy the `n` bytes of `o` (a memory whose elements are stored as natively laid out, a string, a
symbol) from its byte `off` to the C module's memory at `c`, or back (`back`), with one loop over
its elements; false (doing nothing) for an object of another kind, or bytes that are not whole
elements of its array.
"""
copy_elements(@nospecialize(o), off::Int, c::UInt64, n::Int, back::Bool) =
    ccall((:copy_elements, LIBRARY), Bool, (Any, Int, UInt64, Int, Bool), o, off, c, n, back)

"""
    store_fields(c, o)

The isbits fields of the mutable object `o` at `c` in the C module's memory, as C lays them
out, each pointer in them as the address `to_c` gives it.
"""
store_fields(c::UInt64, @nospecialize(o)) = ccall((:store_fields, LIBRARY), Cvoid, (UInt64, Any), c, o)
"""
    load_fields(c, o)

The fields of the mutable object `o` set from the C module's memory at `c` (`store_fields`), each
pointer in them as `back_pointer` gives it: as it was, owner included, if C did not change it.
"""
load_fields(c::UInt64, @nospecialize(o)) = ccall((:load_fields, LIBRARY), Cvoid, (UInt64, Any), c, o)

## Libc's allocator: the C module's

"`Libc.malloc(n)`: `n` bytes of the C heap, a pointer without owner."
c_malloc(n::UInt) = Ptr{Cvoid}(malloc(UInt64(n)))
"`Libc.calloc(n, size)`: `n * size` zeroed bytes of the C heap."
c_calloc(n::UInt, size::UInt) = Ptr{Cvoid}(ccall((:calloc, LIBRARY), UInt64, (UInt64, UInt64), n, size))
"`Libc.realloc(p, n)`: the block `p` of the C heap resized; an error for a pointer into a Julia object."
function c_realloc(p::Ptr{Cvoid}, n::UInt)
    ptr_owner(p) === nothing || throw_realloc_owned()
    return Ptr{Cvoid}(ccall((:realloc, LIBRARY), UInt64, (UInt64, UInt64), UInt64(UInt(p)), n))
end
"""
`Libc.free(p)`: the block `p` of the C heap freed. A pointer into a Julia object is the garbage
collector's (as without a C module): nothing is done.
"""
c_free(p::Ptr{Cvoid}) = (ptr_owner(p) === nothing && free(UInt64(UInt(p))); nothing)

## errors

# Errors where natively nothing is thrown (a store through a pointer, a `ccall`): inference may
# have removed the handlers around them, so the message is also written to `Core.stderr`
# before the error is thrown.
@noinline function c_error(msg::String)
    Core.println(Core.stderr, msg)
    throw(ArgumentError(msg))
end

const OWNED_STORE = string(
    "a pointer into a Julia object stored in the C module's memory: the C module cannot address ",
    "Julia objects (pass the pointer as an argument of a ccall, which passes a copy of the object, ",
    "or keep the data in C memory, Libc.malloc)")
const OWNED_FIELD = string(
    "a pointer into a Julia object in a struct passed by value to a C function: such a pointer ",
    "cannot be passed (a pointer argument is passed as the address of a copy of its object, but a ",
    "field says nothing of the object's size or lifetime; keep its data in C memory, Libc.malloc)")
const NOT_ADDRESSABLE = string(
    "a pointer into a Julia object whose bytes are not laid out as natively (a memory of ",
    "references or of elements holding references, a mutable object with fields that are not ",
    "isbits: references, unions) passed to a C function: C cannot be given a copy of it")
const REALLOC_OWNED = "Libc.realloc of a pointer into a Julia object, not a block of the C module's heap"

@noinline throw_owned_store() = c_error(OWNED_STORE)
@noinline throw_owned_field() = c_error(OWNED_FIELD)
@noinline throw_not_addressable() = c_error(NOT_ADDRESSABLE)
@noinline throw_realloc_owned() = c_error(REALLOC_OWNED)
@noinline function throw_c_oom(n::UInt64)
    Core.println(Core.stderr, string("the C module's heap has no ", n, " bytes for the call"))
    throw(OutOfMemoryError())
end

## the space of a call

"""
    Copy

The copy of the object `owner` at `c` in the C module's memory, `n` bytes, for the call being
made; `base` is the pointer to the owner's first byte (its address and the owner), from which
an address in the copy is mapped back to a pointer into the owner (`from_c`). `kind`: `:bytes`
(its bytes), `:pointers` (a memory or `Ref` of pointers: the address standing for each pointer),
`:values` (a memory or `Ref` of isbits values holding pointers, stored as C stores them) or
`:fields` (a mutable object of isbits fields holding pointers: its fields, each pointer as a
pointer argument is passed). Written back after the call if `writeback` (a mutable owner).
"""
mutable struct Copy
    owner::Any
    base::Ptr{Cvoid}
    c::UInt64
    n::Int
    kind::Symbol
    writeback::Bool
end

# the copies of the calls being made (a call made by a C function's callback nests), and the
# blocks of the C heap their space took, freed when their call returns
const COPIES = Copy[]
const BLOCKS = UInt64[]
# the bytes of the C stack the calls being made took
const STACK_USED = Ref(0)

"""
    enter() -> frame

The beginning of a call that needs space: the C stack pointer and what `leave` releases.
"""
@inline enter() = (stack_save(), length(COPIES), length(BLOCKS), STACK_USED[])

"""
    back!(frame)

After the call `frame` began returned: each copy it made of a mutable object written back into
the object, whichever pointer of the call (an argument, an element of a memory of pointers, or
none any longer: C may have moved it) points into it. The pointers among the copied values that C
changed are mapped back (`from_c`), all copies being alive until `leave`.
"""
@inline function back!(frame::Tuple{UInt64,Int,Int,Int})
    for k in frame[2]+1:length(COPIES)
        r = @inbounds COPIES[k]
        r.writeback || continue
        if r.kind === :pointers
            Runtime.by_type(pointers_from_c, r.owner, r)
        elseif r.kind === :values
            Runtime.by_type(values_from_c, r.owner, r)
        elseif r.kind === :fields
            Runtime.by_type(fields_from_c, r.owner, r)
        else
            copy_bytes!(r.owner, r.c, Ptr{UInt8}(r.base), r.n, true)
        end
    end
    return nothing
end

"""
    leave(frame)

The end of the call `frame` began (it returned or threw): its copies dropped, its blocks of
the C heap freed, the C stack pointer restored.
"""
@inline function leave(frame::Tuple{UInt64,Int,Int,Int})
    sp, ncopies, nblocks, used = frame
    for k in nblocks+1:length(BLOCKS)
        free(@inbounds BLOCKS[k])
    end
    resize!(BLOCKS, nblocks)
    resize!(COPIES, ncopies)
    STACK_USED[] = used
    stack_restore(sp)
    return nothing
end

"""
    scratch(n, align) -> address

`n` bytes of the C module's memory for the call being made, aligned to `align` (at most 16):
on the C stack while the call has used less than `stack_limit()` bytes of it, else a block of
the C heap.
"""
function scratch(n::Int, align::Int)
    used = STACK_USED[] + n + 16
    if used <= stack_limit()
        STACK_USED[] = used
        return stack_alloc(UInt64(n))
    end
    # (malloc's blocks are aligned to 16 or more)
    c = malloc(UInt64(max(n, 1)))
    c == 0 && throw_c_oom(UInt64(n))
    push!(BLOCKS, c)
    return c
end

## pointers into Julia objects, passed to C

is_pointer_type(@nospecialize(T)) = T <: Ptr || T === Cstring || T === Cwstring

# whether values of the isbits type `T` hold pointers
has_pointers(@nospecialize(T)) =
    is_pointer_type(T) || (isstructtype(T) && any(has_pointers, fieldtypes(T)))

"""
Whether the objects of type `T` hold elements of type `E` (the memories of `E`, the `Ref`s of
it) for which `holds(E)`: the owners whose elements are copied one by one, as the values they
are (`pointers_to_c`, `values_to_c`: the cases of `by_type` for them).
"""
holds(holds::F, @nospecialize(T)) where {F} =
    T isa DataType && (T <: Memory || T <: Base.RefValue) && isconcretetype(T) && holds(eltype(T))
holds_pointers(@nospecialize(T)) = holds(is_pointer_type, T)
holds_values(@nospecialize(T)) = holds(E -> isbitstype(E) && has_pointers(E) && !is_pointer_type(E), T)
"""
Whether the objects of type `T` are mutable objects (not memories or `Ref`s) whose fields are
isbits values, some holding pointers: copied field by field (`fields_to_c`).
"""
holds_fields(@nospecialize(T)) =
    T isa DataType && isconcretetype(T) && ismutabletype(T) && !(T <: Memory) && !(T <: Base.RefValue) &&
    fieldcount(T) > 0 && all(isbitstype, fieldtypes(T)) && any(has_pointers, fieldtypes(T))

# the copy of the call whose owner is `o`, or 0
function find_copy(@nospecialize(o))
    for k in length(COPIES):-1:1
        (@inbounds COPIES[k]).owner === o && return k
    end
    return 0
end

"""
    to_c(p) -> address

The address the pointer `p` stands for in the C module's memory: its address, without an
owner; else the address in the copy of its owner made for the call (the first pointer of the
call into the owner makes it).
"""
function to_c(p::Ptr{Cvoid})
    a = UInt64(UInt(p))
    o = ptr_owner(p)
    o === nothing && return a
    k = find_copy(o)
    k == 0 && (k = copy_owner!(o, p - ptr_offset(p)))
    r = @inbounds COPIES[k]
    return r.c + (a - UInt64(UInt(r.base)))
end

"""
    c_address(p) -> address

The address `to_c(p)` gave the pointer `p` for the call being made (its own without an owner or
a copy of it), without making a copy.
"""
function c_address(p::Ptr{Cvoid})
    a = UInt64(UInt(p))
    o = ptr_owner(p)
    o === nothing && return a
    k = find_copy(o)
    k == 0 && return a
    r = @inbounds COPIES[k]
    return r.c + (a - UInt64(UInt(r.base)))
end

"""
    from_c(a) -> pointer

The pointer an address `a` C gave back (a result, a pointer it wrote) stands for: into the
object whose copy for the call being made holds it (at the same offset, or one past its end, as
natively a pointer may be), else the C address `a` without an owner. Called before the copies
are dropped.
"""
function from_c(a::UInt64)
    a == 0 && return Ptr{Cvoid}(a)
    for k in length(COPIES):-1:1
        r = @inbounds COPIES[k]
        a - r.c < UInt64(r.n) && return r.base + (a - r.c)
    end
    # (past the end: of the object whose copy ends there, an empty one included)
    for k in length(COPIES):-1:1
        r = @inbounds COPIES[k]
        a == r.c + UInt64(r.n) && return r.base + (a - r.c)
    end
    return Ptr{Cvoid}(a)
end

"""
    back_pointer(a, old) -> pointer

The pointer that a pointer `old` passed to C (an element or field of a copy) is after the call,
C having left the address `a` there: `old` itself, owner included, if C did not change it, else
`from_c(a)`.
"""
back_pointer(a::UInt64, old::Ptr{Cvoid}) = a == c_address(old) ? old : from_c(a)

# the copy of the owner `o` of a pointer whose base pointer is `base`: pushed to `COPIES`, its
# index. Of a memory or `Ref` of pointers (`Vector{String}` as `Ptr{Cstring}`, a `Ref{Ptr{T}}`),
# each passed as a pointer argument is; of a memory or `Ref` of values holding pointers, each
# stored as in the C module's memory (a pointer into an object among them an error); of others,
# the bytes (of a string or symbol, and the NUL after them)
function copy_owner!(@nospecialize(o), base::Ptr{Cvoid})
    # (the copy is pushed first, those of the objects its pointers point into after it)
    k = length(COPIES) + 1
    (Runtime.by_type(pointers_to_c, o, base) || Runtime.by_type(values_to_c, o, base) ||
     Runtime.by_type(fields_to_c, o, base)) && return k
    n = owner_nbytes(o)
    n < 0 && throw_not_addressable()
    immutable = o isa String || o isa Symbol
    c = scratch(n + immutable, 16)
    copy_bytes!(o, c, Ptr{UInt8}(base), n, false)
    immutable && unsafe_store!(Ptr{UInt8}(c + n), 0x00)
    push!(COPIES, Copy(o, base, c, n, :bytes, !immutable))
    return length(COPIES)
end

# the elements of `o`, a memory or a `Ref`
nelements(o) = o isa Memory ? length(o) : 1
element(o, i::Int) = o isa Memory ? (@inbounds o[i]) : o[]
set_element!(o, i::Int, v) = o isa Memory ? (@inbounds o[i] = v) : (o[] = v)

"The copy of `o`, of the type `T` holding pointers, whose base address is `b` (`copy_owner!`)."
function pointers_to_c(@nospecialize(o), @nospecialize(b), ::Type{T}) where {T}
    o = o::T
    n = nelements(o)
    c = scratch(8n, 8)
    # (the copy first: a pointer among them to the object itself is to the copy)
    push!(COPIES, Copy(o, b::Ptr{Cvoid}, c, 8n, :pointers, true))
    for i in 1:n
        unsafe_store!(Ptr{UInt64}(c), to_c(Core.bitcast(Ptr{Cvoid}, element(o, i))), i)
    end
    return nothing
end

"The copy of `o`, of the type `T` holding values with pointers, whose base address is `b` (`copy_owner!`)."
function values_to_c(@nospecialize(o), @nospecialize(b), ::Type{T}) where {T}
    o = o::T
    E = eltype(T)
    n = nelements(o)
    c = scratch(n * Base.aligned_sizeof(E), Base.datatype_alignment(E))
    for i in 1:n
        unsafe_store!(Ptr{E}(c), element(o, i), i)
    end
    push!(COPIES, Copy(o, b::Ptr{Cvoid}, c, n * Base.aligned_sizeof(E), :values, true))
    return nothing
end

"""
The copy of `o`, a mutable object of type `T` whose fields are isbits values holding pointers
(`c_fields_owner`), whose base pointer is `b` (`copy_owner!`): its fields as C holds them, each
pointer in them as a pointer argument is passed (`store_fields`).
"""
function fields_to_c(@nospecialize(o), @nospecialize(b), ::Type{T}) where {T}
    o = o::T
    c = scratch(sizeof(T), Base.datatype_alignment(T))
    # (the copy first: a pointer among them to the object itself is to the copy)
    push!(COPIES, Copy(o, b::Ptr{Cvoid}, c, sizeof(T), :fields, true))
    store_fields(c, o)
    return nothing
end

"The copy `r` of `o`, of the type `T` (`fields_to_c`), written back (`back!`, `load_fields`)."
fields_from_c(@nospecialize(o), @nospecialize(r), ::Type{T}) where {T} = load_fields((r::Copy).c, o::T)

# copy the `n` bytes of the owner `o` from its base pointer `p` to the C module's memory at `c`,
# or back (`back`)
function copy_bytes!(@nospecialize(o), c::UInt64, p::Ptr{UInt8}, n::Int, back::Bool)
    copy_elements(o, 0, c, n, back) && return nothing
    # (the bytes of the fields of a mutable object, of the elements of a memory stored otherwise
    # than natively: through the owner, 8 bytes at a time where they are aligned)
    i = 0
    while i + 8 <= n
        if back
            unsafe_store!(Ptr{UInt64}(p + i), unsafe_load(Ptr{UInt64}(c + i)))
        else
            unsafe_store!(Ptr{UInt64}(c + i), unsafe_load(Ptr{UInt64}(p + i)))
        end
        i += 8
    end
    while i < n
        if back
            unsafe_store!(p + i, unsafe_load(Ptr{UInt8}(c + i)))
        else
            unsafe_store!(Ptr{UInt8}(c + i), unsafe_load(p + i))
        end
        i += 1
    end
    return nothing
end

"""
The copy `r` of `o`, of the type `T` holding pointers, written back (`back!`): a pointer C left
as it was stays the pointer it was, owner included; one it changed is the pointer its new
address stands for (`from_c`).
"""
function pointers_from_c(@nospecialize(o), @nospecialize(r), ::Type{T}) where {T}
    o, r = o::T, r::Copy
    for i in 1:nelements(o)
        q = Core.bitcast(Ptr{Cvoid}, element(o, i))
        a = unsafe_load(Ptr{UInt64}(r.c), i)
        a == c_address(q) || set_element!(o, i, Core.bitcast(eltype(T), from_c(a)))
    end
    return nothing
end

"The copy `r` of `o`, of the type `T` holding values with pointers, written back (`back!`)."
function values_from_c(@nospecialize(o), @nospecialize(r), ::Type{T}) where {T}
    o, r = o::T, r::Copy
    for i in 1:nelements(o)
        set_element!(o, i, unsafe_load(Ptr{eltype(T)}(r.c), i))
    end
    return nothing
end

end # CLink
