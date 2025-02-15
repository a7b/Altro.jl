"""
rollout.jl
"""

show_nice(x) = show(IOContext(stdout), "text/plain", x)

function rollout!(solver::iLQRSolver{IR}, α) where {IR}
    N = solver.N
    X = solver.X
    U = solver.U
    X_tmp = solver.X_tmp
    U_tmp = solver.U_tmp
    δx = solver.X_tmp[N + 1]
    δu = solver.U_tmp[N]
    ts = solver.ts
    K = solver.K
    d = solver.d
    J = 0.

    X_tmp[1] .= X[1]
    for k = 1:N-1
        # handle feedforward
        dt = ts[k + 1] - ts[k]
        state_diff!(δx, solver.model, X_tmp[k], X[k])
	δu .= d[k]
        δu .*= α
	mul!(δu, K[k], δx, 1., 1.)
        U_tmp[k] .= U[k]
        U_tmp[k] .+= δu
        discrete_dynamics!(X_tmp[k + 1], IR, solver.model, X_tmp[k],
                              U_tmp[k], ts[k], dt)
        # compute cost
        J += cost(solver.obj, X_tmp, U_tmp, k)
        max_x = norm(X_tmp[k + 1], Inf)
        if max_x > solver.opts.max_state_value || isnan(max_x)
            solver.stats.status = STATE_LIMIT
            return 0., true
        end
        max_u = norm(U_tmp[k], Inf)
        if max_u > solver.opts.max_control_value || isnan(max_u)
            solver.stats.status = CONTROL_LIMIT 
            return 0., true
        end
    end
    J += cost(solver.obj, X_tmp, U_tmp, N)
    solver.stats.status = UNSOLVED
    return J, false
end
