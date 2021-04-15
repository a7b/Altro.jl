"""
backwardpass.jl
"""

"""
Calculates the optimal feedback gains K,d as well as the 2nd Order approximation of the
Cost-to-Go, using a backward Riccati-style recursion. (non-allocating)
"""
function backwardpass!(solver::iLQRSolver{IR}) where {IR}
    # initialize
    model = solver.model
    ix = solver.ix
    iu = solver.iu
    X = solver.X
    U = solver.U
    ts = solver.ts
    m = solver.m
    N = solver.N
    K = solver.K
    K_dense = solver.K_dense
    d = solver.d
    D = solver.D
    A = solver.A
    B = solver.B
    G = solver.G
    E = solver.E
    Qxx = solver.Qxx
    Qxx_tmp = solver.Qxx_tmp
    Quu = solver.Quu
    Quu_dense = solver.Quu_dense
    Quu_reg = solver.Quu_reg
    Qux = solver.Qux
    Qux_tmp = solver.Qux_tmp
    Qux_reg = solver.Qux_reg
    Qx = solver.Qx
    Qu = solver.Qu
    P = solver.P
    P_tmp = solver.P_tmp
    p = solver.p
    p_tmp = solver.p_tmp
    ΔV = solver.ΔV

    # terminal (cost and action-value) expansions
    ΔV .= 0
    TO.cost_derivatives!(E, solver.obj, N, X[N])
    P .= E.Q
    p .= E.q

    k = N-1
    while k > 0
	    # dynamics and cost expansions
        dt = ts[k + 1] - ts[k]
	    RD.discrete_jacobian!(D, A, B, IR, model, X[k], U[k], ts[k], dt, ix, iu)
        TO.cost_derivatives!(E, solver.obj, k, X[k], U[k])

	    # action-value expansion
        _calc_Q!(Qxx, Qxx_tmp, Quu, Qux, Qux_tmp, Qx, Qu, E, A, B, P, p)

	    # regularization
        reg_flag = _bp_reg!(Quu, Quu_reg, Qux, Qux_reg, A, B, solver.ρ[1], solver.opts.bp_reg_type)
        if solver.opts.bp_reg && reg_flag
            @warn "Backward pass regularized"
            regularization_update!(solver, :increase)
            k = N-1
            ΔV .= 0
            TO.gradient!(E, solver.obj, N, X[N])
            TO.hessian!(E, solver.obj, N, X[N])
            P .= E.Q
            p .= E.q
            continue
        end

        # gains
        _calc_gains!(K[k], K_dense, d[k], Quu_reg, Quu_dense, Qux_reg, Qu)
        
	    # cost-to-go (using unregularized Quu and Qux)
	    _calc_ctg!(ΔV, P, P_tmp, p, p_tmp, K[k], d[k], Qxx, Quu, Qux, Qx, Qu)

        k -= 1
    end

    regularization_update!(solver, :decrease)
    
    return nothing
end


function static_backwardpass!(solver::iLQRSolver{T,QUAD,L,O,n,n̄,m}) where {
    T,QUAD<:QuadratureRule,L,O,n,n̄,m}
    N = solver.N

    # Objective
    obj = solver.obj
    model = solver.model

    # Extract variables
    Z = solver.Z; K = solver.K; d = solver.d;
    G = solver.G
    S = solver.S
    Quu_reg = SMatrix(solver.Quu_reg)
    Qux_reg = SMatrix(solver.Qux_reg)

    # Terminal cost-to-go
	# Q = error_expansion(solver.Q[N], model)
	Q = solver.Q[N]
	Sxx = SMatrix(Q.Q)
	Sx = SVector(Q.q)

    # Initialize expected change in cost-to-go
    ΔV = @SVector zeros(2)

    k = N-1
    while k > 0
        ix = Z[k]._x
        iu = Z[k]._u

		# Get error state expanions
		fdx,fdu = TO.error_expansion(solver.D[k], model)
		fdx,fdu = SMatrix(fdx), SMatrix(fdu)
		Q = TO.static_expansion(solver.Q[k])
		# Q = error_expansion(solver.Q[k], model)
		# Q = solver.Q[k]

		# Calculate action-value expansion
		Q = _calc_Q!(Q, Sxx, Sx, fdx, fdu)

		# Regularization
		Quu_reg, Qux_reg = _bp_reg!(Q, fdx, fdu, solver.ρ[1], solver.opts.bp_reg_type)

	    if solver.opts.bp_reg
	        vals = eigvals(Hermitian(Quu_reg))
	        if minimum(vals) <= 0
	            @warn "Backward pass regularized"
	            regularization_update!(solver, :increase)
	            k = N-1
	            ΔV = @SVector zeros(2)
	            continue
	        end
	    end

        # Compute gains
		K_, d_ = _calc_gains!(K[k], d[k], Quu_reg, Qux_reg, Q.u)

		# Calculate cost-to-go (using unregularized Quu and Qux)
		Sxx, Sx, ΔV_ = _calc_ctg!(Q, K_, d_)
		# k >= N-2 && println(diag(Sxx))
		if solver.opts.save_S
			S[k].xx .= Sxx
			S[k].x .= Sx
			S[k].c .= ΔV_
		end
		ΔV += ΔV_
        k -= 1
    end

    regularization_update!(solver, :decrease)

    return ΔV
end

# function _bp_reg!(Quu_reg::SizedMatrix{m,m}, Qux_reg, Q, fdx, fdu, ρ, ver=:control) where {m}
#     if ver == :state
#         Quu_reg .= Q.uu #+ solver.ρ[1]*fdu'fdu
# 		mul!(Quu_reg, Transpose(fdu), fdu, ρ, 1.0)
#         Qux_reg .= Q.ux #+ solver.ρ[1]*fdu'fdx
# 		mul!(Qux_reg, fdu', fdx, ρ, 1.0)
#     elseif ver == :control
#         Quu_reg .= Q.uu #+ solver.ρ[1]*I
# 		Quu_reg .+= ρ*Diagonal(@SVector ones(m))
#         Qux_reg .= Q.ux
#     end
# end

function _bp_reg!(Quu, Quu_reg, Qux, Qux_reg, A, B, ρ, type_)
    reg_flag = false
    if type_ == :state
        # perform regularization
        mul!(Quu_reg, Transpose(B), B)
        for i in eachindex(Quu_reg)
            Quu_reg[i] = Quu[i] + ρ * Quu_reg[i]
        end
        mul!(Qux_reg, Transpose(B), A)
        for i in eachindex(Qux_reg)
            Qux_reg[i] = Qux[i] + ρ * Qux_reg[i]
        end
    elseif type_ == :control
        # perform regularization
		Quu_reg .= Quu
        for i = 1:size(Quu_reg, 1)
            Quu_reg[i, i] += ρ
        end
        Qux_reg .= Qux
        # check for ill-conditioning
        vals = eigvals(Hermitian(Quu_reg))
        if minimum(vals) <= 0
            reg_flag = true
        end
    end
    return reg_flag
end

function _calc_Q!(Qxx, Qxx_tmp, Quu, Qux, Qux_tmp, Qx, Qu, E, A, B, P, p)
    # Qxx
    mul!(Qxx_tmp, Transpose(A), P)
    mul!(Qxx, Qxx_tmp, A)
    Qxx .+= E.Q
    # Quu
    mul!(Qux_tmp, Transpose(B), P)
    mul!(Quu, Qux_tmp, B)
    Quu .+= E.R
    # Qux
    mul!(Qux_tmp, Transpose(B), P)
    mul!(Qux, Qux_tmp, A)
    # Qx
    mul!(Qx, Transpose(A), p)
    Qx .+= E.q
    # Qu
    mul!(Qu, Transpose(B), p)
    Qu .+= E.r
    return nothing
end

# function _calc_Q!(Q::TO.StaticExpansion, Sxx, Sx, fdx::SMatrix, fdu::SMatrix)
# 	Qx = Q.x + fdx'Sx
# 	Qu = Q.u + fdu'Sx
# 	Qxx = Q.xx + fdx'Sxx*fdx
# 	Quu = Q.uu + fdu'Sxx*fdu
# 	Qux = Q.ux + fdu'Sxx*fdx
# 	TO.StaticExpansion(Qx,Qxx,Qu,Quu,Qux)
# end


function _calc_gains!(K::AbstractMatrix, K_dense::AbstractMatrix,
                      d::AbstractVector, Quu::AbstractMatrix,
                      Quu_dense::AbstractMatrix,
                      Qux::AbstractMatrix, Qu::AbstractVector)
    Quu_dense .= Quu
    LAPACK.potrf!('U', Quu_dense)
    K_dense .= Qux
    d .= Qu
    LAPACK.potrs!('U', Quu_dense, K_dense)
    LAPACK.potrs!('U', Quu_dense, d)
    Quu .= Quu_dense
    for i in eachindex(K_dense)
        K[i] = -1 * K_dense[i]
    end
    d .*= -1
    return nothing
end


# function _calc_gains!(K, d, Quu::SMatrix, Qux::SMatrix, Qu::SVector)
# 	K_ = -Quu\Qux
# 	d_ = -Quu\Qu
# 	K .= K_
# 	d .= d_
# 	return K_,d_
# end


function _calc_ctg!(ΔV, P, P_, p, p_, K, d, Qxx, Quu, Qux, Qx, Qu)
    # p = Qx + K' * Quu * d +K' * Qu + Qxu * d
    p .= Qx
    mul!(p_, Quu, d)
    mul!(p, Transpose(K), p_, 1.0, 1.0)
    mul!(p, Transpose(K), Qu, 1.0, 1.0)
    mul!(p, Transpose(Qux), d, 1.0, 1.0)

    # P = Qxx + K' * Quu * K + K' * Qux + Qxu * K
    P .= Qxx
    mul!(P_, Quu, K)
    mul!(P, Transpose(K), P_, 1.0, 1.0)
    mul!(P, Transpose(K), Qux, 1.0, 1.0)
    mul!(P, Transpose(Qux), K, 1.0, 1.0)
    transpose!(Qxx, P)
    P .+= Qxx
    P .*= 0.5

    # calculated change is cost-to-go over entire trajectory
    t1 = dot(d, Qu)
    mul!(Qu, Quu, d)
    t2 = 0.5 * dot(d, Qu)
    ΔV[1] += t1
    ΔV[2] += t2
    return nothing
end


# function _calc_ctg!(Q::TO.StaticExpansion, K::SMatrix, d::SVector)
# 	Sx = Q.x + K'Q.uu*d + K'Q.u + Q.ux'd
# 	Sxx = Q.xx + K'Q.uu*K + K'Q.ux + Q.ux'K
# 	Sxx = 0.5*(Sxx + Sxx')
# 	# S.x .= Sx
# 	# S.xx .= Sxx
# 	t1 = d'Q.u
# 	t2 = 0.5*d'Q.uu*d
# 	return Sxx, Sx, @SVector [t1, t2]
# end
