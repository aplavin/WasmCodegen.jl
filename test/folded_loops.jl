# `trim/wasm-folded-loops.jl`: `in(::Integer, ::LinearIndices{1})` with its ends, not by
# iterating (what `append!(::Vector, ::Tuple)` checks bounds with), against native.

fl_in(n::Int, x::Int) = (x in LinearIndices(collect(1:n)), x ∉ LinearIndices(view(collect(1:n), 2:n)),
                         Int32(x) in LinearIndices(1:n), true in LinearIndices(1:n))

# a vector built by appending tuples, as `flatmap` to tuples builds it
function fl_append(n::Int)
    v = Tuple{Int,Float64}[]
    for i in 1:n
        append!(v, ((i, 0.5i), (-i, 1.0)))
    end
    return (length(v), sum(first, v), sum(last, v), v[end - 2])
end

@testset "folded loops: in(::Integer, ::LinearIndices{1})" begin
    for (n, x) in ((0, 0), (0, 1), (3, 0), (3, 1), (3, 3), (3, 4), (5, -1), (5, 2))
        @wtest fl_in(n, x)
    end
    @wtest fl_append(1)
    @wtest fl_append(1000)
    # the patch's method, not the generic `in` (this file runs in a session of the patches)
    @test endswith(string(which(in, (Int, LinearIndices{1,Tuple{Base.OneTo{Int}}})).file), "wasm-folded-loops.jl")
end
