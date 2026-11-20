"""
    CLink

The run-time side of calls into the C module a module is linked with (`Config(c_linkage)`,
`clinkage.jl`). The C module owns the only linear memory; a Julia object is not in it, so a
pointer into one (a pointer with an owner) is passed to C as the address of a copy of its
owner, made for the call in the space the call allocates (`scratch`: the C stack, or the C
heap past `stack_limit()` bytes), and copied back into the owner after the call when the owner
is mutable (`to_c`, `close_frame`). Every pointer of a call into the same owner shares one copy,
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
    store_value(c, v)

The isbits value `v` at `c` in the C module's memory, as C lays it out, each pointer in it as the
address `to_c` gives it.
"""
store_value(c::UInt64, v) = ccall((:store_value, LIBRARY), Cvoid, (UInt64, Any), c, v)
"""
    load_value(c, old) -> value

The isbits value of `old`'s type at `c` in the C module's memory (`store_value`), each pointer in
it as `back_pointer` gives it: as it was in `old`, owner included, if C did not change it.
"""
@generated load_value(c::UInt64, old) = :(ccall((:load_value, LIBRARY), $old, (UInt64, Any), c, old))
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
const NOT_ADDRESSABLE = string(
    "a pointer into a Julia object whose bytes are not laid out as natively (a memory of ",
    "references or of elements holding references, a mutable object with fields that are not ",
    "isbits: references, unions) passed to a C function: C cannot be given a copy of it")
const REALLOC_OWNED = "Libc.realloc of a pointer into a Julia object, not a block of the C module's heap"

@noinline throw_owned_store() = c_error(OWNED_STORE)
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
(its bytes), `:elements` (a memory of isbits values holding pointers: its elements as C holds
them, each pointer in them as a pointer argument is passed) or `:fields` (a mutable object of
isbits fields holding pointers, a `Ref` of such values among them: its fields so). Written back
after the call if `writeback` (a mutable owner).
"""
mutable struct Copy
    owner::Any
    base::Ptr{Cvoid}
    c::UInt64
    n::Int
    kind::Symbol
    writeback::Bool
end

# the copies of the calls being made, and the blocks of the C heap their space took, freed
# when their call returns
const COPIES = Copy[]
const BLOCKS = UInt64[]
# the bytes of the C stack the calls being made took
const STACK_USED = Ref(0)

"What a call's frame releases: the C stack pointer, the copies, blocks and stack bytes before it."
struct Frame
    sp::UInt64
    ncopies::Int
    nblocks::Int
    used::Int
end
# the frames of the calls being made
const FRAMES = Frame[]

"""
    open_frame() -> frame

The beginning of a call that makes copies (or needs space): its frame, which `close_frame` (when
the call returns) or `release_frame` (when a Julia exception leaves it) ends.

No Julia code runs while a call into C is being made (C does not call back into Julia), so a
frame open now was left by a call that trapped: a trap (a Julia exception where nothing
catches, or any trap) unwinds through the module without running its handlers, to the host,
which may call the module again. Its state is discarded (`discard!`) before the frame opens, so
that no copy of it is reused or written back.
"""
@noinline function open_frame()
    isempty(FRAMES) || discard!()
    push!(FRAMES, Frame(stack_save(), length(COPIES), length(BLOCKS), STACK_USED[]))
    return length(FRAMES)
end

"""
    discard!()

The state the calls that trapped left: their copies dropped, their blocks of the C heap freed,
their bytes of the C stack no longer counted. The C stack pointer is left where they moved it:
the module cannot know where the host's own C frames, if any, end (it may have called the
module from a C function's import), and restoring it is the host's (it may read it before
calling the module, `stack_save`, and restore it after a trap). Their space on the stack is
lost until then, the space of one call: at most its arguments by value and `stack_limit()`.
"""
@noinline function discard!()
    for b in BLOCKS
        free(b)
    end
    empty!(BLOCKS)
    empty!(COPIES)
    empty!(FRAMES)
    STACK_USED[] = 0
    return nothing
end

"""
    close_frame(frame)

After the call `frame` began returned: each copy it made of a mutable object written back into
the object, whichever pointer of the call (an argument, an element of a memory of pointers, or
none any longer: C may have moved it) points into it, the pointers among the copied values that C
changed mapped back (`from_c`) while all copies are alive; then the frame released.
"""
function close_frame(frame::Int)
    for k in (@inbounds FRAMES[frame]).ncopies+1:length(COPIES)
        r = @inbounds COPIES[k]
        r.writeback || continue
        if r.kind === :elements
            Runtime.by_type(elements_from_c, r.owner, r)
        elseif r.kind === :fields
            Runtime.by_type(fields_from_c, r.owner, r)
        else
            copy_bytes!(r.owner, r.c, Ptr{UInt8}(r.base), r.n, true)
        end
    end
    release_frame(frame)
    return nothing
end

"""
    release_frame(frame)

The end of the call `frame` began (it returned or threw): its copies dropped, its blocks of
the C heap freed, the C stack pointer restored.
"""
function release_frame(frame::Int)
    f = @inbounds FRAMES[frame]
    for k in f.nblocks+1:length(BLOCKS)
        free(@inbounds BLOCKS[k])
    end
    resize!(BLOCKS, f.nblocks)
    resize!(COPIES, f.ncopies)
    STACK_USED[] = f.used
    stack_restore(f.sp)
    resize!(FRAMES, frame - 1)
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
# index. Of a memory of values holding pointers (`Vector{String}` as `Ptr{Cstring}`, which Base
# makes a vector of pointers, an array of structs with pointer fields) and of a mutable object
# whose fields hold pointers (a `Ref{Ptr{T}}` out-parameter, a `Ref` of such a struct), their
# values with each pointer passed as a pointer argument is (`elements_to_c`, `fields_to_c`); of
# others, the bytes (of a string or symbol, and the NUL after them)
function copy_owner!(@nospecialize(o), base::Ptr{Cvoid})
    # (the copy is pushed first, those of the objects its pointers point into after it)
    k = length(COPIES) + 1
    (Runtime.by_type(elements_to_c, o, base) || Runtime.by_type(fields_to_c, o, base)) && return k
    n = owner_nbytes(o)
    n < 0 && throw_not_addressable()
    immutable = o isa String || o isa Symbol
    c = scratch(n + immutable, 16)
    copy_bytes!(o, c, Ptr{UInt8}(base), n, false)
    immutable && unsafe_store!(Ptr{UInt8}(c + n), 0x00)
    push!(COPIES, Copy(o, base, c, n, :bytes, !immutable))
    return length(COPIES)
end

"""
The copy of `o`, a memory of type `T` whose elements are isbits values holding pointers
(`c_elements_owner`), whose base pointer is `b` (`copy_owner!`): its elements as C holds them,
each pointer in them as a pointer argument is passed (`store_value`).
"""
function elements_to_c(@nospecialize(o), @nospecialize(b), ::Type{T}) where {T}
    o = o::T
    s = Base.aligned_sizeof(eltype(T))
    n = length(o)
    c = scratch(n * s, Base.datatype_alignment(eltype(T)))
    # (the copy first: a pointer among them to the object itself is to the copy)
    push!(COPIES, Copy(o, b::Ptr{Cvoid}, c, n * s, :elements, true))
    for i in 1:n
        store_value(c + UInt64((i - 1) * s), @inbounds o[i])
    end
    return nothing
end

"The copy `r` of `o`, of the type `T` (`elements_to_c`), written back (`close_frame`, `load_value`)."
function elements_from_c(@nospecialize(o), @nospecialize(r), ::Type{T}) where {T}
    o, r = o::T, r::Copy
    s = Base.aligned_sizeof(eltype(T))
    for i in 1:length(o)
        @inbounds o[i] = load_value(r.c + UInt64((i - 1) * s), @inbounds o[i])
    end
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

"The copy `r` of `o`, of the type `T` (`fields_to_c`), written back (`close_frame`, `load_fields`)."
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

end # CLink
