# Base methods whose cost is right natively only because LLVM folds a loop away, which
# Binaryen does not: with the same results, done without the loop.
# - `in(x::Integer, ::LinearIndices{1})`: no method of its own, so the generic `in` iterates
#   the indices up to `x`. The bounds check of `copyto!(dest, dstart, src, sstart, n)` for
#   a non-array `src`, which `append!(::Vector, ::Tuple)` calls, is `dstart ∉
#   LinearIndices(dest)`: appending a tuple costs the length of the vector, and building a
#   vector by appending tuples (`flatmap` to tuples) is quadratic. The values of a
#   one-dimensional `LinearIndices` are its axis, a unit range, whose `in` compares with
#   its ends.
#   TODO: belongs in Base (natively it is a loop that LLVM removes, not a guarantee); drop
#   this patch once Base has the method.

@eval Base begin
    in(x::Integer, inds::LinearIndices{1}) = in(x, inds.indices[1])
end
