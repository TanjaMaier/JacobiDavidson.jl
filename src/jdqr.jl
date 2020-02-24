export jdqr

import LinearAlgebra.GeneralizedSchur

function jdqr(
    A,                       # Some square matrix
    solver::Alg;             # Solver for the correction equation
    pairs::Int = 5,          # Number of eigenpairs wanted
    min_dimension::Int = 10, # Minimal search space size
    max_dimension::Int = 20, # Maximal search space size
    max_iter::Int = 200,
    target::Target = Near(0.0 + 0im), # Search target
    ɛ::Float64 = 1e-7,       # Maximum residual norm
    T::Type = ComplexF64,
    verbose::Bool = false
) where {Alg <: CorrectionSolver}

    solver_reltol = one(real(T))
    residuals::Vector{real(T)} = []

    n = size(A, 1)

    # V's vectors span the search space
    # AV will store (A - tI) * V, without any orthogonalization
    # W will hold AV, but with its columns orthogonal: AV = W * MA
    V = SubSpace(zeros(T, n, max_dimension))
    AV = SubSpace(zeros(T, n, max_dimension))
    W = SubSpace(zeros(T, n, max_dimension))

    # Temporaries (trying to reduces #allocations here)
    temporary = zeros(T, n, max_dimension)

    # Projected matrices
    MA = ProjectedMatrix(zeros(T, max_dimension, max_dimension))
    M = ProjectedMatrix(zeros(T, max_dimension, max_dimension))

    # k is the number of converged eigenpairs
    k = 0

    # m is the current dimension of the search subspace
    m = 0

    pschur = PartialSchur(zeros(T, n, pairs), T)

    # Current eigenvalue
    λ = zero(T)

    # Current residual vector
    r = Vector{T}(undef, n)

    iter = 1

    harmonic_ritz_values::Vector{Vector{T}} = []
    converged_ritz_values::Vector{Vector{T}} = []

    local F::GeneralizedSchur

    while k ≤ pairs && iter ≤ max_iter
        solver_reltol /= 2

        m += 1

        ### Expand
        resize!(V, m)
        resize!(AV, m)
        resize!(W, m)
        resize!(M, m)
        resize!(MA, m)

        if iter == 1
            rand!(V.curr)
        else
            solve_deflated_correction!(solver, A, V.curr, pschur.all, λ, r, solver_reltol)
        end

        # Search space is orthonormalized
        orthogonalize_and_normalize!(V.prev, V.curr, zeros(T, m - 1), DGKS)

        # AV is just the product (A - τI)V
        mul!(AV.curr, A, V.curr)
        axpy!(-target.τ, V.curr, AV.curr)

        # Expand W with (A - τI)V, and then orthogonalize
        copyto!(W.curr, AV.curr)

        # Orthogonalize w.r.t. the converged Schur vectors
        just_orthogonalize!(pschur.locked, W.curr, DGKS)

        # Orthonormalize W[:, m] w.r.t. previous columns of W
        MA.matrix[m, m] = orthogonalize_and_normalize!(W.prev, W.curr, view(MA.matrix, 1 : m - 1, m), DGKS)

        # Update the right-most column and last row of M = W' * V
        M.matrix[m, m] = dot(W.curr, V.curr)
        @inbounds for i = 1 : m - 1
            M.matrix[i, m] = dot(view(W.basis, :, i), V.curr)
            M.matrix[m, i] = dot(W.curr, view(V.basis, :, i))
        end

        # Assert orthogonality of V and W
        # Assert W * MA = (I - QQ') * (A - τI) * V
        # Assert that M = W' * V
        # @assert norm(W.all'W.all - I) < 1e-12
        # @assert norm(V.all'V.all - I) < 1e-12
        # @assert norm(M.curr - W.all'V.all) < 1e-12
        # @assert norm(W.all * MA.curr - AV.all + (pschur.locked * (pschur.locked'AV.all))) < pairs * ɛ

        search = true

        ### Extract
        while search

            F = schur(MA.curr, M.curr)
            λ = extract_harmonic!(F, V, AV, r, pschur, target.τ)
            resnorm = norm(r)

            # Convergence history of the harmonic Ritz values
            push!(harmonic_ritz_values, F.alpha ./ F.beta)
            push!(converged_ritz_values, copy(pschur.values))
            push!(residuals, resnorm)

            verbose && println("Residual = ", resnorm)

            # A Ritz vector is converged
            if resnorm ≤ ɛ
                verbose && println("Found an eigenvalue ", λ)
                push!(converged_ritz_values[iter], λ)

                push!(pschur.values, λ)
                lock!(pschur)

                k += 1

                # Are we done yet?
                k == pairs && return pschur, harmonic_ritz_values, converged_ritz_values, residuals

                # Now remove this Schur vector from the search space.
                keep = 2 : m
                shrink!(temporary, V, view(F.right, :, keep), m - 1)
                shrink!(temporary, AV, view(F.right, :, keep), m - 1)
                shrink!(temporary, W, view(F.left, :, keep), m - 1)
                shrink!(M, view(F.T, keep, keep), m - 1)
                shrink!(MA, view(F.S, keep, keep), m - 1)

                m -= 1

                # TODO: Can the search space become empty? Probably, but not likely.
                m == 0 && throw(ErrorException("Search space became empty: TODO."))

                solver_reltol = one(real(T))
            else
                search = false
            end
        end

        ### Restart
        if m == max_dimension
            verbose && println("Shrinking the search space.")

            # Move min_dimension of the smallest harmonic Ritz values up front
            keep = 1 : min_dimension
            schur_sort!(SM(0.0+0im), F, keep)

            shrink!(temporary, V, view(F.right, :, keep), min_dimension)
            shrink!(temporary, AV, view(F.right, :, keep), min_dimension)
            shrink!(temporary, W, view(F.left, :, keep), min_dimension)
            shrink!(M, view(F.T, keep, keep), min_dimension)
            shrink!(MA, view(F.S, keep, keep), min_dimension)
            m = min_dimension
        end

        iter += 1
    end

    pschur, harmonic_ritz_values, converged_ritz_values, residuals
end

function extract_harmonic!(F::GeneralizedSchur, V::SubSpace, AV::SubSpace, r, pschur, τ)
    # Compute the Schur decomp to find the harmonic Ritz values

    # Move the smallest harmonic Ritz value up front
    schur_sort!(SM(0.0 + 0im), F, 1)

    # Pre-ritz vector
    y = view(F.Z, :, 1)

    # Ritz vector
    mul!(pschur.active, V.all, y)

    # Rayleigh quotient λ = approx eigenvalue s.t. if r = (A-τI)u - λ * u, then r ⟂ u
    λ = conj(F.beta[1]) * F.alpha[1]

    # Residual r = (A - τI)u - λ * u = AV*y - λ * u
    mul!(r, AV.all, y)
    axpy!(-λ, pschur.active, r)

    # Orthogonalize w.r.t. Q
    just_orthogonalize!(pschur.locked, r, DGKS)

    # Assert that the residual is perpendicular to the Ritz vector
    # @assert abs(dot(r, pschur.active)) < 1e-5

    λ + τ
end

