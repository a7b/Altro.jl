"""
constraints.jl

Notes:
The jacobian! method is meant for Markovian constraints
while the jacobian_copy! method is intended for a direct solver
which accomodates more general constraints
"""

const NULL_MAT = Array{Float64,2}(undef, 0, 0)
const NULL_VEC = Array{Float64,1}(undef, 0)

# general

@enum ConstraintSense begin
    EQUALITY = 1
    INEQUALITY = 2
end

@enum ActionType begin
    STATE = 1
    CONTROL = 2
end

abstract type AbstractConstraint{S} end

@inline sense(con::AbstractConstraint{S}) where {S} = S

"Only a function of states and controls at a single knotpoint"
abstract type StageConstraint{S} <: AbstractConstraint{S} end
"Only a function of states at a single knotpoint"
abstract type StateConstraint{S} <: StageConstraint{S} end
"Only a function of controls at a single knotpoint"
abstract type ControlConstraint{S} <: StageConstraint{S} end
"Only a function of states and controls at two adjacent knotpoints"
abstract type CoupledConstraint{S} <: AbstractConstraint{S} end
"Only a function of states at adjacent knotpoints"
abstract type CoupledStateConstraint{S} <: CoupledConstraint{S} end
"Only a function of controls at adjacent knotpoints"
abstract type CoupledControlConstraint{S} <: CoupledConstraint{S} end

mutable struct ConstraintParams{T}
    # penalty scaling parameter
	ϕ::T
    # initial penalty parameter
	μ0::T
    # max penalty parameter
	μ_max::T
    # max Lagrange multiplier
	λ_max::T
    # active set tolerance
    a_tol::T
end

function ConstraintParams(;ϕ::T=10., μ0::T=1., μ_max::T=1e8, λ_max::T=1e8, a_tol::T=0.) where {T}
    return ConstraintParams{T}(ϕ, μ0, μ_max, λ_max, a_tol)
end

Base.eltype(::ConstraintParams{T}) where {T} = T

"""
	GoalConstraint{P,T}

Constraint of the form ``x_g = a``, where ``x_g`` can be only part of the state
vector.

# Constructors:
```julia
GoalConstraint(xf::AbstractVector)
GoalConstraint(xf::AbstractVector, inds)
```
where `xf` is an n-dimensional goal state. If `inds` is provided,
only `xf[inds]` will be used.
"""
struct GoalConstraint{S,Tx,Ti,Txp,Tup,Tp,Tpx,Tpu,T} <: StateConstraint{S}
    n::Int
    m::Int
    # constraint length
    p::Int
    # goal state vector
    xf::Tx
    # indices into state vector
    inds::Ti
    # tmp for cost_derivatives!
    XP_tmp::Txp
    UP_tmp::Tup
    p_tmp::Vector{Tp}
    # stores for jacobian!
    Cx::Tpx
    Cu::Tpu
    # misc
    const_jac::Bool
    state_expansion::Bool
    control_expansion::Bool
    coupled_expansion::Bool
    direct::Bool
    params::ConstraintParams{T}
end

# constructors
function GoalConstraint(xf::Tx, inds::Ti, n::Int, m::Int, M, V;
                        direct::Bool=false,
                        params::ConstraintParams{T}=ConstraintParams()) where {T,Tx,Ti}
    p = length(inds)
    XP_tmp = M(zeros(n, p))
    UP_tmp = M(zeros(n, p))
    p_tmp = [V(zeros(p)) for i = 1:2]
    Cx = M(zeros(p, n))
    Cu = M(zeros(p, m))
    Txp = typeof(XP_tmp)
    Tup = typeof(UP_tmp)
    Tp = typeof(p_tmp[1])
    Tpx = typeof(Cx)
    Tpu = typeof(Cu)
    const_jac = true
    state_expansion = true
    control_expansion = false
    coupled_expansion = false
    sense = EQUALITY
    con = GoalConstraint{sense,Tx,Ti,Txp,Tup,Tp,Tpx,Tpu,T}(
        n, m, p, xf, inds, XP_tmp, UP_tmp, p_tmp, Cx, Cu, const_jac,
        state_expansion, control_expansion, coupled_expansion, direct, params
    )
    jacobian!(con.Cx, con.Cu, con, NULL_VEC, NULL_VEC, 0)
    return con
end

# evaluation
function evaluate!(c::AbstractVector, con::GoalConstraint,
                   X::AbstractVector, U::AbstractVector, k::Int)
    for (i, j) in enumerate(con.inds)
        c[i] = X[k][j] - con.xf[j] 
    end
    return nothing
end

function jacobian!(Cx::AbstractMatrix, Cu::AbstractMatrix, con::GoalConstraint, X::AbstractVector,
                   U::AbstractVector, k::Int)
    for (i, j) in enumerate(con.inds)
	    Cx[i, j] = 1.
    end
    return nothing
end

function jacobian_copy!(D::AbstractMatrix, con::GoalConstraint,
                        X::AbstractVector, U::AbstractVector, k::Int,
                        c_ginds::AbstractVector, x_ginds::AbstractVector,
                        u_ginds::AbstractVector)
    for (i, j) in enumerate(con.inds)
        D[c_ginds[i], x_ginds[k][j]] = 1.
    end
    return nothing
end

# methods
@inline Base.length(con::GoalConstraint) = con.p

function max_violation_info(con::GoalConstraint, c::AbstractVector, k::Int)
    max_viol = -Inf
    info_str = ""
    for (i, j) in enumerate(con.inds)
        viol = abs(c[i])
        if viol > max_viol
            info_str = "GoalConstraint x[$j] k=$k"
            max_viol = viol
        end
    end
    return max_viol, info_str
end



"""
DynamicsConstraint - constraint for explicit dynamics
"""
struct DynamicsConstraint{S,T,Tir,Tm,Tt,Tix,Tiu,Tx,Txx,Txu,Txz} <: CoupledConstraint{S}
    n::Int
    m::Int
    ir::Tir
    model::Tm
    ts::Tt
    ix::Tix
    iu::Tiu
    # store for evaluate!
    x_tmp::Tx
    # store for jacobian_copy!
    A::Txx
    B::Txu
    AB::Txz
    # misc
    const_jac::Bool
    direct::Bool
    params::ConstraintParams{T}
end

# constructors
function DynamicsConstraint(
    ir::Tir, model::Tm, ts::Tt, ix::Tix, iu::Tiu, n::Int, m::Int, M, V;
    direct::Bool=true, params::ConstraintParams{T}=ConstraintParams()) where {Tir,Tm,Tt,T,Tix,Tiu}
    x_tmp = V(zeros(n))
    A = M(zeros(n, n))
    B = M(zeros(n, m))
    AB = M(zeros(n, n+m))
    Tx = typeof(x_tmp)
    Txx = typeof(A)
    Txu = typeof(B)
    Txz = typeof(AB)
    const_jac = false
    sense = EQUALITY
    con = DynamicsConstraint{sense,T,Tir,Tm,Tt,Tix,Tiu,Tx,Txx,Txu,Txz}(
        n, m, ir, model, ts, ix, iu, x_tmp, A, B, AB, const_jac, direct, params
    )
    return con
end

# evaluation
function evaluate!(c::AbstractVector, con::DynamicsConstraint, X::AbstractVector,
                   U::AbstractVector, k::Int)
    discrete_dynamics!(con.x_tmp, con.ir, con.model, X[k - 1], U[k - 1], con.ts[k - 1],
                          con.ts[k] - con.ts[k - 1])
    for i = 1:con.n
        c[i] = con.x_tmp[i] - X[k][i]
    end
    return nothing
end

function jacobian!(Cx::AbstractMatrix, Cu::AbstractMatrix, con::DynamicsConstraint,
                   X::AbstractVector, U::AbstractVector, k::Int)
    throw("not implemented")
    return nothing
end

function jacobian_copy!(D::AbstractMatrix, con::DynamicsConstraint,
                        X::AbstractVector, U::AbstractVector, k::Int,
                        c_ginds::AbstractVector, x_ginds::AbstractVector,
                        u_ginds::AbstractVector)
    # ASSUMPTION: D[c_ginds, i] .= 0 for i ∉ x_ginds[k - 1] U u_ginds[k - 1] U x_ginds[k]
    discrete_jacobian!(con.A, con.B, con.ir, con.model,
                       X[k - 1], U[k - 1], con.ts[k - 1],
                       con.ts[k] - con.ts[k - 1])
    D[c_ginds, x_ginds[k - 1]] .= con.A
    D[c_ginds, u_ginds[k - 1]] .= con.B
    for (i, j) in enumerate(c_ginds)
        D[j, x_ginds[k][i]] = 1.
    end
end

# methods
@inline Base.length(con::DynamicsConstraint) = con.n

function max_violation_info(con::DynamicsConstraint, c::AbstractVector, k::Int)
    max_viol = -Inf
    info_str = ""
    for i = 1:con.n
        viol = abs(c[i])
        if viol > max_viol
            info_str = "DynamicsConstraint x[$i] k=$k"
            max_viol = viol
        end
    end
    return max_viol, info_str
end


"""
	BoundConstraint{Tz,Tiu,Til,Tinds}

Linear bound constraint on states and controls
# Constructors
```julia
BoundConstraint(n, m; x_min, x_max, u_min, u_max)
```
Any of the bounds can be ±∞. The bound can also be specifed as a single scalar, which applies the bound to all state/controls.
"""
struct BoundConstraint{S,Tx,Tu,Tixu,Tixl,Tiuu,Tiul,Txp,Tup,Tp,Tpx,Tpu,T} <: StageConstraint{S}
    n::Int
    m::Int
    # constraint length
    p::Int
    x_max::Tx
    x_min::Tx
    u_max::Tu
    u_min::Tu
    x_max_inds::Tixu
    x_min_inds::Tixl
    u_max_inds::Tiuu
    u_min_inds::Tiul
    XP_tmp::Txp
    UP_tmp::Tup
    p_tmp::Vector{Tp}
    Cx::Tpx
    Cu::Tpu
    const_jac::Bool
    state_expansion::Bool
    control_expansion::Bool
    coupled_expansion::Bool
    direct::Bool
    params::ConstraintParams{T}
end

# constructor
function BoundConstraint(
    x_max::Tx, x_min::Tx, u_max::Tu, u_min::Tu, n::Int, m::Int, M, V; direct::Bool=false,
    checks=true, params::ConstraintParams{T}=ConstraintParams()
) where {T,Tx<:AbstractVector,Tu<:AbstractVector}
    if checks
        @assert all(x_max .>= x_min)
        @assert all(u_max .>= u_min)
    end
    x_max_finite_inds = findall(isfinite, x_max)
    x_max_c_inds = 1:length(x_max_finite_inds)
    x_max_inds = V([(i, j) for (i, j) in zip(x_max_c_inds, x_max_finite_inds)])
    p = length(x_max_inds)
    x_min_finite_inds = findall(isfinite, x_min)
    x_min_c_inds = p .+ (1:length(x_min_finite_inds))
    x_min_inds = V([(i, j) for (i, j) in zip(x_min_c_inds, x_min_finite_inds)])
    p += length(x_min_inds)
    u_max_finite_inds = findall(isfinite, u_max)
    u_max_c_inds = p .+ (1:length(u_max_finite_inds))
    u_max_inds = V([(i, j) for (i, j) in zip(u_max_c_inds, u_max_finite_inds)])
    p += length(u_max_inds)
    u_min_finite_inds = findall(isfinite, u_min)
    u_min_c_inds = p .+ (1:length(u_min_finite_inds))
    u_min_inds = V([(i, j) for (i, j) in zip(u_min_c_inds, u_min_finite_inds)])
    p += length(u_min_inds)
    state_expansion = (length(x_max_inds) + length(x_min_inds)) > 0
    control_expansion = (length(u_max_inds) + length(u_min_inds)) > 0
    coupled_expansion = state_expansion && control_expansion
    # tmps for jacobian!
    XP_tmp = M(zeros(n, p))
    UP_tmp = M(zeros(m, p))
    p_tmp = [V(zeros(p)), V(zeros(p))]
    Cx = M(zeros(p, n))
    Cu = M(zeros(p, m))
    const_jac = true
    sense = INEQUALITY
    # types
    Tixu = typeof(x_max_inds)
    Tixl = typeof(x_min_inds)
    Tiuu = typeof(u_max_inds)
    Tiul = typeof(u_min_inds)
    Txp = typeof(XP_tmp)
    Tup = typeof(UP_tmp)
    Tp = typeof(p_tmp[1])
    Tpx = typeof(Cx)
    Tpu = typeof(Cu)
    # construct
    con = BoundConstraint{sense,Tx,Tu,Tixu,Tixl,Tiuu,Tiul,Txp,Tup,Tp,Tpx,Tpu,T}(
        n, m, p, x_max, x_min, u_max, u_min, x_max_inds, x_min_inds, u_max_inds,
        u_min_inds, XP_tmp, UP_tmp, p_tmp, Cx, Cu, const_jac, state_expansion,
        control_expansion, coupled_expansion, direct, params
    )
    # initialize
    jacobian!(Cx, Cu, con, x_max, x_max, 0)
    return con
end

# evaluation
function evaluate!(c::AbstractVector, con::BoundConstraint, X::AbstractVector,
                   U::AbstractVector, k::Int; log=false)
    for (i, j) in con.x_max_inds
        c[i] = X[k][j] - con.x_max[j]
    end
    for (i, j) in con.u_max_inds
        c[i] = U[k][j] - con.u_max[j]
    end
    for (i, j) in con.x_min_inds
        c[i] = con.x_min[j] - X[k][j]
    end
    for (i, j) in con.u_min_inds
        c[i] = con.u_min[j] - U[k][j]
    end
    return nothing
end

function jacobian!(Cx::AbstractMatrix, Cu::AbstractMatrix, con::BoundConstraint,
                   X::AbstractVector, U::AbstractVector, k::Int)
    for (i, j) in con.x_max_inds
        Cx[i, j] = 1.
    end
    for (i, j) in con.x_min_inds
        Cx[i, j] = -1.
    end
    for (i, j) in con.u_max_inds
        Cu[i, j] = 1.
    end
    for (i, j) in con.u_min_inds
        Cu[i, j] = -1.
    end
    return nothing
end

function jacobian_copy!(D::AbstractMatrix, con::BoundConstraint,
                        X::AbstractVector, U::AbstractVector, k::Int,
                        c_ginds::AbstractVector, x_ginds::AbstractVector,
                        u_ginds::AbstractVector)
    for (i, j) in con.x_max_inds
        D[c_ginds[i], x_ginds[k][j]] = 1.
    end
    for (i, j) in con.x_min_inds
        D[c_ginds[i], x_ginds[k][j]] = -1.
    end
    for (i, j) in con.u_max_inds
        D[c_ginds[i], u_ginds[k][j]] = 1.
    end
    for (i, j) in con.u_min_inds
        D[c_ginds[i], u_ginds[k][j]] = -1.
    end
    return nothing
end

# methods
@inline Base.length(con::BoundConstraint) = con.p

function max_violation_info(con::BoundConstraint, c::AbstractVector, k::Int)
    max_viol = -Inf
    info_str = ""
    for (i, j) in con.x_max_inds
        viol = c[i]
        if viol > max_viol
            max_viol = viol
            info_str = "BoundConstraint x_max[$j] k=$k"
        end
    end
    for (i, j) in con.u_max_inds
        viol = c[i]
        if viol > max_viol
            max_viol = viol
            info_str = "BoundConstraint u_max[$j] k=$k"
        end
    end
    for (i, j) in con.x_min_inds
        viol = c[i]
        if viol > max_viol
            max_viol = viol
            info_str = "BoundConstraint x_min[$j] k=$k"
        end
    end
    for (i, j) in con.u_min_inds
        viol = c[i]
        if viol > max_viol
            max_viol = viol
            info_str = "BoundConstraint u_min[$j] k=$k"
        end
    end
    return max_viol, info_str
end

"""
NormConstraint
"""
struct NormConstraint{S,A,Ti,Txp,Tup,Tp,Tpx,Tpu,T} <: StageConstraint{S}
    n::Int
    m::Int
    inds::Ti
    n_max::T
    # constraint length
    p::Int
    XP_tmp::Txp
    UP_tmp::Tup
    p_tmp::Vector{Tp}
    Cx::Tpx
    Cu::Tpu
    const_jac::Bool
    state_expansion::Bool
    control_expansion::Bool
    coupled_expansion::Bool
    direct::Bool
    params::ConstraintParams{T}
end

# constructor
function NormConstraint(
    sense::ConstraintSense, action_type::ActionType, inds::Ti, n_max::T, n::Int, m::Int, M, V;
    direct::Bool=false, checks=true, params::ConstraintParams{T}=ConstraintParams()
) where {Ti,T}
    state_expansion = action_type == STATE ? true : false
    control_expansion = action_type == CONTROL ? true : false
    coupled_expansion = false
    if checks
        @assert n_max >= 0
        if action_type == STATE
            @assert all(inds .<= n)
        end
        if action_type == CONTROL
            @assert all(inds .<= m)
        end
    end
    # tmps for jacobian!
    p = 1
    XP_tmp = M(zeros(n, p))
    UP_tmp = M(zeros(m, p))
    p_tmp = [V(zeros(p)), V(zeros(p))]
    Cx = M(zeros(p, n))
    Cu = M(zeros(p, m))
    const_jac = false
    sense = EQUALITY
    # types
    Txp = typeof(XP_tmp)
    Tup = typeof(UP_tmp)
    Tp = typeof(p_tmp[1])
    Tpx = typeof(Cx)
    Tpu = typeof(Cu)
    # construct
    con = NormConstraint{sense, action_type,Ti,Txp,Tup,Tp,Tpx,Tpu,T}(
        n, m, inds, n_max, p, XP_tmp, UP_tmp, p_tmp, Cx, Cu, const_jac, state_expansion,
        control_expansion, coupled_expansion, direct, params
    )
    return con
end

# evaluation
function evaluate!(c::AbstractVector, con::NormConstraint{S,STATE}, X::AbstractVector,
                   U::AbstractVector, k::Int; log=false) where {S}
    c[1] = -con.n_max
    for i in con.inds
        c[1] += X[k][i]^2
    end
    return nothing
end

function evaluate!(c::AbstractVector, con::NormConstraint{S,CONTROL}, X::AbstractVector,
                   U::AbstractVector, k::Int; log=false) where {S}
    c[1] = -con.n_max
    for i in con.inds
        c[1] += U[k][i]^2
    end
    return nothing
end

function jacobian!(Cx::AbstractMatrix, Cu::AbstractMatrix, con::NormConstraint{S,STATE},
                   X::AbstractVector, U::AbstractVector, k::Int) where {S}
    for i in con.inds
        Cx[1, i] = 2 * X[k][i]
    end
    return nothing
end

function jacobian!(Cx::AbstractMatrix, Cu::AbstractMatrix, con::NormConstraint{S,CONTROL},
                   X::AbstractVector, U::AbstractVector, k::Int) where {S}
    for i in con.inds
        Cu[1, i] = 2 * U[k][i]
    end
    return nothing
end

function jacobian_copy!(D::AbstractMatrix, con::NormConstraint{S,STATE},
                        X::AbstractVector, U::AbstractVector, k::Int,
                        c_ginds::AbstractVector, x_ginds::AbstractVector,
                        u_ginds::AbstractVector) where {S}
    for i in con.inds
        D[c_ginds[1], x_ginds[k][i]] = 2 * X[k][i]
    end
    return nothing
end

function jacobian_copy!(D::AbstractMatrix, con::NormConstraint{S,CONTROL},
                        X::AbstractVector, U::AbstractVector, k::Int,
                        c_ginds::AbstractVector, x_ginds::AbstractVector,
                        u_ginds::AbstractVector) where {S}
    for i in con.inds
        D[c_ginds[1], u_ginds[k][i]] = 2 * U[k][i]
    end
    return nothing
end

# methods
@inline Base.length(con::NormConstraint) = con.p

function max_violation_info(con::NormConstraint{S,STATE}, c::AbstractVector, k::Int) where {S}
    max_viol = c[1]
    info_str = "NormConstraint x[$(con.inds)]"
    return max_viol, info_str
end

function max_violation_info(con::NormConstraint{CONTROL}, c::AbstractVector, k::Int)
    max_viol = c[1]
    info_str = "NormConstraint u[$(con.inds)]"
    return max_viol, info_str
end
