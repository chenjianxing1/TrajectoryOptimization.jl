function initialize!(solver::iLQRSolver2)
    set_verbosity!(solver.opts)
    clear_cache!(solver.opts)

    solver.ρ[1] = solver.opts.bp_reg_initial
    solver.dρ[1] = 0.0

    # Initial rollout
    rollout!(solver)
    cost!(solver.obj, solver.Z)
end

"""
Calculates the optimal feedback gains K,d as well as the 2nd Order approximation of the
Cost-to-Go, using a backward Riccati-style recursion. (non-allocating)
"""
function backwardpass!(solver::iLQRSolver2{T,QUAD,L,O,n,n̄,m}) where {T,QUAD<:QuadratureRule,L,O,n,n̄,m}
	N = solver.N

    # Objective
    obj = solver.obj
    model = solver.model

    # Extract variables
    Z = solver.Z; K = solver.K; d = solver.d;
    G = solver.G
    S = solver.S
    Q = solver.E
	Quu_reg = solver.Quu_reg
	Qux_reg = solver.Qux_reg

    # Terminal cost-to-go
    S[N].xx .= solver.Q[N].xx
    S[N].x .= solver.Q[N].x

    # Initialize expecte change in cost-to-go
    ΔV = @SVector zeros(2)

    k = N-1
    while k > 0
        ix = Z[k]._x
        iu = Z[k]._u

		# Get error state expanions
		fdx,fdu = solver.D[k].A, solver.D[k].B
		error_expansion!(Q, solver.Q[k], model, Z[k], solver.G[k])

		# Calculate action-value expansion
		Q = _calc_Q!(Q, S[k+1], S[k], fdx, fdu)

		# Regularization
		# _bp_reg!(Quu_reg, Qux_reg, Q, fdx, fdu,
		# 	solver.ρ[1], solver.opts.bp_reg_type)
        if solver.opts.bp_reg_type == :state
            Quu_reg .= Q.uu #+ solver.ρ[1]*fdu'fdu
			mul!(Quu_reg, Transpose(fdu), fdu, solver.ρ[1], 1.0)
            Qux_reg .= Q.ux #+ solver.ρ[1]*fdu'fdx
			mul!(Qux_reg, fdu', fdx, solver.ρ[1], 1.0)
        elseif solver.opts.bp_reg_type == :control
            Quu_reg .= Q.uu #+ solver.ρ[1]*I
			Quu_reg .+= solver.ρ[1]*Diagonal(@SVector ones(m))
            Qux_reg .= Q.ux
        end

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
		_calc_gains!(K[k], d[k], Quu_reg, Qux_reg, Q.u)

        # Calculate cost-to-go (using unregularized Quu and Qux)
		ΔV += _calc_ctg!(S[k], Q, K[k], d[k])

        k -= 1
    end

    regularization_update!(solver, :decrease)

    return ΔV

end

function static_backwardpass!(solver::iLQRSolver2{T,QUAD,L,O,n,n̄,m}) where {T,QUAD<:QuadratureRule,L,O,n,n̄,m}
	N = solver.N

    # Objective
    obj = solver.obj
    model = solver.model

    # Extract variables
    Z = solver.Z; K = solver.K; d = solver.d;
    G = solver.G
    S = solver.S
    E = solver.E
	Quu_reg = SMatrix(solver.Quu_reg)
	Qux_reg = SMatrix(solver.Qux_reg)

    # Terminal cost-to-go
	Sxx = SMatrix(solver.Q[N].xx)
	Sx = SVector(solver.Q[N].x)

    # Initialize expected change in cost-to-go
    ΔV = @SVector zeros(2)

    k = N-1
    while k > 0
        ix = Z[k]._x
        iu = Z[k]._u

		# Get error state expanions
		fdx,fdu = SMatrix(solver.D[k].A), SMatrix(solver.D[k].B)
		# error_expansion!(E, solver.Q[k], model, Z[k], solver.G[k])

		# Q = StaticExpansion(E)
		Q = StaticExpansion(solver.Q[k])
		# S1 = StaticExpansion(S[k+1])

		# Calculate action-value expansion
		Q = _calc_Q!(Q, Sxx, Sx, fdx, fdu)

		# Regularization
		Quu_reg, Qux_reg = _bp_reg!(Q, fdx, fdu,
			solver.ρ[1], solver.opts.bp_reg_type)

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
		ΔV += ΔV_
        k -= 1
    end

    regularization_update!(solver, :decrease)

    return ΔV

end

function _bp_reg!(Quu_reg::SizedMatrix{m,m}, Qux_reg, Q, fdx, fdu, ρ, ver=:control) where {m}
    if ver == :state
        Quu_reg .= Q.uu #+ solver.ρ[1]*fdu'fdu
		mul!(Quu_reg, Transpose(fdu), fdu, ρ, 1.0)
        Qux_reg .= Q.ux #+ solver.ρ[1]*fdu'fdx
		mul!(Qux_reg, fdu', fdx, ρ, 1.0)
    elseif ver == :control
        Quu_reg .= Q.uu #+ solver.ρ[1]*I
		Quu_reg .+= ρ*Diagonal(@SVector ones(m))
        Qux_reg .= Q.ux
    end
end

function _bp_reg!(Q, fdx, fdu, ρ, ver=:control)
    if ver == :state
		Quu_reg = Q.uu + ρ * fdu'fdu
		Qux_reg = Q.ux + ρ * fdu'fdx
    elseif ver == :control
		Quu_reg = Q.uu + ρ * I
        Qux_reg = Q.ux
    end

	Quu_reg, Qux_reg
end

function _calc_Q!(Q, S1, S, fdx, fdu)
	# Compute the cost-to-go, stashing temporary variables in S[k]
    # Qx =  Q.x[k] + fdx'S.x[k+1]
	mul!(Q.x, Transpose(fdx), S1.x, 1.0, 1.0)

    # Qu =  Q.u[k] + fdu'S.x[k+1]
	mul!(Q.u, Transpose(fdu), S1.x, 1.0, 1.0)

    # Qxx = Q.xx[k] + fdx'S.xx[k+1]*fdx
	mul!(S.xx, Transpose(fdx), S1.xx)
	mul!(Q.xx, S.xx, fdx, 1.0, 1.0)

    # Quu = Q.uu[k] + fdu'S.xx[k+1]*fdu
	mul!(S.ux, Transpose(fdu), S1.xx)
	mul!(Q.uu, S.ux, fdu, 1.0, 1.0)

    # Qux = Q.ux[k] + fdu'S.xx[k+1]*fdx
	mul!(S.ux, Transpose(fdu), S1.xx)
	mul!(Q.ux, S.ux, fdx, 1.0, 1.0)

	return Q
end

function _calc_Q!(Q::StaticExpansion, Sxx, Sx, fdx::SMatrix, fdu::SMatrix)
	Qx = Q.x + fdx'Sx
	Qu = Q.u + fdu'Sx
	Qxx = Q.xx + fdx'Sxx*fdx
	Quu = Q.uu + fdu'Sxx*fdu
	Qux = Q.ux + fdu'Sxx*fdx
	StaticExpansion(Qx,Qxx,Qu,Quu,Qux)
end


function _calc_gains!(K::SizedArray, d::SizedArray, Quu::SizedArray, Qux::SizedArray, Qu)
	LAPACK.potrf!('U',Quu.data)
	K .= Qux
	d .= Qu
	LAPACK.potrs!('U', Quu.data, K.data)
	LAPACK.potrs!('U', Quu.data, d.data)
	K .*= -1
	d .*= -1
	# return K,d
end

function _calc_gains!(K, d, Quu::SMatrix, Qux::SMatrix, Qu::SVector)
	K_ = -Quu\Qux
	d_ = -Quu\Qu
	K .= K_
	d .= d_
	return K_,d_
end

function _calc_ctg!(S, Q, K, d)
	# S.x[k]  =  Qx + K[k]'*Quu*d[k] + K[k]'* Qu + Qux'd[k]
	tmp1 = S.u
	S.x .= Q.x
	mul!(tmp1, Q.uu, d)
	mul!(S.x, Transpose(K), tmp1, 1.0, 1.0)
	mul!(S.x, Transpose(K), Q.u, 1.0, 1.0)
	mul!(S.x, Transpose(Q.ux), d, 1.0, 1.0)

	# S.xx[k] = Qxx + K[k]'*Quu*K[k] + K[k]'*Qux + Qux'K[k]
	tmp2 = S.ux
	S.xx .= Q.xx
	mul!(tmp2, Q.uu, K)
	mul!(S.xx, Transpose(K), tmp2, 1.0, 1.0)
	mul!(S.xx, Transpose(K), Q.ux, 1.0, 1.0)
	mul!(S.xx, Transpose(Q.ux), K, 1.0, 1.0)
	transpose!(Q.xx, S.xx)
	S.xx .+= Q.xx
	S.xx .*= 0.5

    # calculated change is cost-to-go over entire trajectory
	t1 = d'Q.u
	mul!(Q.u, Q.uu, d)
	t2 = 0.5*d'Q.u
    return @SVector [t1, t2]
end

function _calc_ctg!(Q::StaticExpansion, K::SMatrix, d::SVector)
	Sx = Q.x + K'Q.uu*d + K'Q.u + Q.ux'd
	Sxx = Q.xx + K'Q.uu*K + K'Q.ux + Q.ux'K
	Sxx = 0.5*(Sxx + Sxx')
	# S.x .= Sx
	# S.xx .= Sxx
	t1 = d'Q.u
	t2 = 0.5*d'Q.uu*d
	return Sxx, Sx, @SVector [t1, t2]
end

function rollout!(solver::iLQRSolver2{T,Q,n}, α) where {T,Q,n}
    Z = solver.Z; Z̄ = solver.Z̄
    K = solver.K; d = solver.d;

    Z̄[1].z = [solver.x0; control(Z[1])]

    temp = 0.0
	δx = solver.E.x
	δu = solver.E.u

    for k = 1:solver.N-1
        δx .= state_diff(solver.model, state(Z̄[k]), state(Z[k]))
		δu .= d[k]
		mul!(δu, K[k], δx, 1.0, α)
        ū = control(Z[k]) + δu
        set_control!(Z̄[k], ū)

        # Z̄[k].z = [state(Z̄[k]); control(Z[k]) + δu]
        Z̄[k+1].z = [discrete_dynamics(Q, solver.model, Z̄[k]);
            control(Z[k+1])]

        temp = norm(Z̄[k+1].z)
        if temp > solver.opts.max_state_value
            return false
        end
    end
    return true
end

function gradient_todorov!(solver::iLQRSolver2)
	tmp = solver.E.u
    for k in eachindex(solver.d)
		tmp .= abs.(solver.d[k])
		u = abs.(control(solver.Z[k])) .+ 1
		tmp ./= u
		solver.grad[k] = maximum(tmp)
    end
end

function step!(solver::iLQRSolver2, J)
    Z = solver.Z
    state_diff_jacobian!(solver.G, solver.model, Z)
    # discrete_jacobian!(solver.∇F, solver.model, Z)
	dynamics_expansion!(solver.D, solver.G, solver.model, solver.Z)
    cost_expansion!(solver.Q, solver.G, solver.obj, solver.model, solver.Z)
	if solver.opts.static_bp
    	ΔV = static_backwardpass!(solver)
	else
		ΔV = backwardpass!(solver)
	end
    forwardpass!(solver, ΔV, J)
end