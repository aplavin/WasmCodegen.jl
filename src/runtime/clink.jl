"""
    CLink

The run-time side of the C module a module is linked with (`Config(c_linkage)`,
`clinkage.jl`): its allocator for `Libc`, the errors of pointers into Julia objects where the C
module would see them, and primitives (`ccall`s of the library `LIBRARY`) the code generator
compiles: to the C module's imports, to the memory's instructions, and to helpers over the
module's types; natively they are never called.
"""
module CLink

import ..ptr_owner

"The library of the primitives the code generator compiles (`emit_clink_primitive!`)."
const LIBRARY = "julia_c"

## primitives

"Whether the module is linked with a C module (a constant of the module)."
linked() = ccall((:linked, LIBRARY), Bool, ())
"`n` bytes of the C heap (0 if it has none)."
malloc(n::UInt64) = ccall((:malloc, LIBRARY), UInt64, (UInt64,), n)
"Frees the block `p` of the C heap."
free(p::UInt64) = ccall((:free, LIBRARY), Cvoid, (UInt64,), p)
"`memmove` within the C module's memory (`memory.copy`)."
memmove(dst::UInt64, src::UInt64, n::UInt64) = ccall((:memmove, LIBRARY), Cvoid, (UInt64, UInt64, UInt64), dst, src, n)
"`memset` of the C module's memory (`memory.fill`)."
memset(dst::UInt64, b::UInt8, n::UInt64) = ccall((:memset, LIBRARY), Cvoid, (UInt64, UInt8, UInt64), dst, b, n)
"""
Copy the `n` bytes of `o` (a memory whose elements are stored as natively laid out, a string, a
symbol) from its byte `off` to the C module's memory at `c`, or back (`back`), with one loop over
its elements; false (doing nothing) for an object of another kind, or bytes that are not whole
elements of its array.
"""
copy_elements(@nospecialize(o), off::Int, c::UInt64, n::Int, back::Bool) =
    ccall((:copy_elements, LIBRARY), Bool, (Any, Int, UInt64, Int, Bool), o, off, c, n, back)

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
const OWNED_ARGUMENT = string(
    "a pointer into a Julia object passed to a C function: not supported yet (only addresses in ",
    "the C module's memory are)")
const REALLOC_OWNED = "Libc.realloc of a pointer into a Julia object, not a block of the C module's heap"

@noinline throw_owned_store() = c_error(OWNED_STORE)
@noinline throw_owned_field() = c_error(OWNED_FIELD)
@noinline throw_owned_argument() = c_error(OWNED_ARGUMENT)
@noinline throw_realloc_owned() = c_error(REALLOC_OWNED)

end # CLink
