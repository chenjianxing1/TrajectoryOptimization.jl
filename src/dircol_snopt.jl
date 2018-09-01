using Base.Test
using Snopt
using ForwardDiff
using Interpolations

"""
$(SIGNATURES)
Generate the custom function to be passed into SNOPT, as well as `eval_f` and
`eval_g` used to calculate the objective and constraint functions.

# Arguments
* model: TrajectoryOptimization.Model for the dynamics
* obj: TrajectoryOptimization.ConstrainedObjective to describe the cost function
* dt: time step
* pack: tuple of important sizes (n,m,N) -> (num states, num controls, num knot points)
* method: Collocation method. Either :trapezoid or :hermite_simpson_separated
* grads: Specifies the gradient information provided to SNOPT.
    :none - returns no gradient information to SNOPT
    :auto - uses ForwardDiff to calculate gradients
    :quadratic - uses functions exploiting quadratic cost functions
"""
function gen_usrfun(solver::Solver, method::Symbol; grads=:none)::Function
    n,m,N = solver.model.n, solver.model.m, solver.N
    pack = (n,m,N)
    dt = solver.dt
    obj = copy(solver.obj)

    # Weights
    weights = get_weights(method,N)*dt

    if obj isa UnconstrainedObjective
        obj = ConstrainedObjective(obj)
    end

    # Count constraints
    pI = 0
    pE = (N-1)*n # Collocation constraints
    p_colloc = pE

    pI_obj, pE_obj = count_constraints(obj)
    pI_c,   pE_c   = pI_obj[2], pE_obj[2]
    pI_N_c, pE_N_c = pI_obj[4], pE_obj[4]

    pI += pI_c*(N-1) + pI_N_c  # Add custom inequality constraints
    pE += pE_c*(N-1) + pE_N_c  # Add custom equality constraints

    # Evaluate the Cost (objective) function)
    function eval_f(Z)
        X,U = unpackZ(Z,pack)
        if method == :hermite_simpson_modified
            return cost(obj,solver.model.f,X,U)
        else
            cost(X,U,weights,obj)
        end
    end

    # Evaluate the equality constraint function
    function eval_ceq(Z)
        X,U = unpackZ(Z,pack)
        gE = zeros(eltype(Z),pE)
        g_colloc = collocation_constraints(X,U,method,dt,solver.model.f)
        gE[1:p_colloc] = g_colloc

        # Custom constraints
        if pE_c > 0
            gE_c = zeros(eltype(Z),pE_c,N-1)
            for k = 1:N-1
                gE_c[:,k] = obj.cE(X[:,k],U[:,k])
            end
            gE[p_colloc+1 : end-pE_N_c] = vec(gE_c)
        end
        if pE_N_c > 0
            gE[end-pE_N_c+1:end] = obj.cE(X[:,N])
        end
        return g_colloc
    end

    # Evaluate the inequality constraint function
    function eval_c(Z)
        X,U = unpackZ(Z,pack)
        gI = zeros(eltype(Z),pI)

        # Custom constraints
        if pI_c > 0
            gI_c = zeros(eltype(Z),pI_c,N-1)
            for k = 1:N-1
                gI[k] = obj.cI(X[:,k],U[:,k])
            end
            gI[p_colloc+1 : end-pI_N_c] = vec(gI_c)
        end
        if pI_N_c > 0
            gI[end-pI_N_c+1:end] = obj.cI(X[:,N])
        end
        return gI
    end

    """
    Stack constraints as follows:
    [ general stage inequality,
      general terminal inequality,
      general stage equality,
      general terminal equality,
      collocation constraints ]
    """
    function eval_g(Z)
        g = zeros(eltype(Z),pI+pE)
        g[1:pI] = eval_c(Z)
        g[pI+1:end] = eval_ceq(Z)
        return g
    end

    # User defined function passed to SNOPT (via Snopt.jl)
    function usrfun(Z)
        # Objective Function (Cost)
        J = eval_f(Z)

        # Constraints (dynamics only for now)
        c = Float64[] # No inequality constraints for now
        ceq = eval_ceq(Z)

        fail = false

        if grads == :none
            return J, c, ceq, fail
        else
            X,U = unpackZ(Z,pack)

            # Gradient of Objective
            if grads == :auto
                grad_f = ForwardDiff.gradient(eval_f,Z)
            else
                grad_f = cost_gradient(X,U,weights,obj)
            end

            # Constraint Jacobian
            jacob_c = Float64[]
            if grads == :auto
                jacob_ceq = ForwardDiff.jacobian(eval_g,Z)
            else
                jacob_ceq = constraint_jacobian(X,U,dt,method,solver.Fc)
            end

            return J, c, ceq, grad_f, jacob_c, jacob_ceq, fail
        end
    end

    return usrfun
end

function dircol(model::Model,obj::Objective,dt::Float64;
        method::Symbol=:hermite_simpson_separated, grads::Symbol=:quadratic, start=start)

        # Constants
        nSeg = Int(floor(obj.tf/dt)); # Number of segments
        dt = obj.tf/nSeg
        if method == :hermite_simpson_separated
            N = 2*nSeg + 1
        else
            N = nSeg + 1
        end

        X0, U0 = get_initial_state(obj,N)
        dircol(model, obj, dt, X0, U0, method=method, grads=grads, start=start)
end


"""
$(SIGNATURES)
Solve a trajectory optimization problem with direct collocation

# Arguments
* model: TrajectoryOptimization.Model for the dynamics
* obj: TrajectoryOptimization.ConstrainedObjective to describe the cost function
* dt: time step. Used to determine the number of knot points. May be modified
    by the solver in order to achieve an integer number of knot points.
* method: Collocation method.
    :trapezoidal - First order interpolation on states and zero order on control.
    :hermite_simpson_separated - Hermite Simpson collocation with the midpoints
        included as additional decision variables with constraints
    :hermite_simpson_modified -
* grads: Specifies the gradient information provided to SNOPT.
    :none - returns no gradient information to SNOPT
    :auto - uses ForwardDiff to calculate gradients
    :quadratic - uses functions exploiting quadratic cost functions
"""
function solve_dircol(solver::Solver,X0::Matrix,U0::Matrix;
        method::Symbol=:auto, grads::Symbol=:quadratic, start=:cold)

        X0 = copy(X0)
        U0 = copy(U0)

        if method == :auto
            if solver.integration == :rk3_foh
                method = :hermite_simpson_modified
            elseif solver.integration == :midpoint
                method = :midpoint
            else
                method = :hermite_simpson_modified
            end
        end

        if method == :hermite_simpson_modified || method == :midpoint
            grads = :none
        end

        # Constants
        N,dt = solver.N, solver.dt
        if method == :hermite_simpson_separated
            nSeg = (N-1)/2
        else
            nSeg = N-1
        end
        pack = (solver.model.n, solver.model.m, N)

        # Generate the objective/constraint function and its gradients
        usrfun = gen_usrfun(solver, method, grads=grads)

        # Set up the problem
        Z0 = packZ(X0,U0)
        lb,ub = get_bounds(obj,N)

        # Set options
        options = Dict{String, Any}()
        options["Derivative option"] = 0
        options["Verify level"] = 1
        options["Minor feasibility tol"] = solver.opts.eps_constraint
        # options["Minor optimality  tol"] = solver.opts.eps_intermediate
        options["Major optimality  tol"] = solver.opts.eps

        # Solve the problem
        if solver.opts.verbose
            println("DIRCOL with $method")
            println("Passing Problem to SNOPT...")
        end
        z_opt, fopt, info = snopt(usrfun, Z0, lb, ub, options, start=start)
        stats = parse_snopt_summary()
        # @time snopt(usrfun, Z0, lb, ub, options, start=start)
        # xopt, fopt, info = Z0, Inf, "Nothing"
        x_opt,u_opt = unpackZ(z_opt,pack)

        if solver.opts.verbose
            println(info)
        end
        return x_opt, u_opt, fopt, stats
end

function solve_dircol(solver::Solver, X0::Matrix, U0::Matrix, mesh::Vector;
        method::Symbol=:auto, grads::Symbol=:quadratic, start=:cold)
    x_opt, u_opt = X0, U0
    stats = Dict{String,Any}("iterations"=>0, "major iterations"=>0, "objective calls"=>0)
    tic()
    for dt in mesh
        solver.opts.verbose ? println("Refining mesh at dt=$dt") : nothing
        solver_mod = Solver(solver,dt=dt)
        x_int, u_int = interp_traj(solver_mod.N, solver.obj.tf, x_opt, u_opt)
        x_opt, u_opt, f_opt, stats_run = solve_dircol(solver_mod, x_int, u_int, method=method, grads=grads, start=start)
        for key in keys(stats)
            stats[key] += stats_run[key]
        end
        start = :warm  # Use warm starts after the first one
    end
    stats["runtime"] = toq()
    # Run the original time step
    x_int, u_int = interp_traj(solver.N, solver.obj.tf, x_opt, u_opt)
    x_opt, u_opt, f_opt = solve_dircol(solver, x_int, u_int, method=method, grads=grads, start=:warm)
    return x_opt, u_opt, f_opt, stats
end


function interp_traj(N::Int,tf::Float64,X::Matrix,U::Matrix)::Tuple{Matrix,Matrix}
    X2 = interp_rows(N,tf,X)
    U2 = interp_rows(N,tf,U)
    return X2, U2
end

function interp_rows(N::Int,tf::Float64,X::Matrix)::Matrix
    n,N1 = size(X)
    t1 = linspace(0,obj.tf,N1)
    t2 = linspace(0,obj.tf,N)
    X2 = zeros(n,N)
    for i = 1:n
        interp_cubic = CubicSplineInterpolation(t1, X[i,:])
        X2[i,:] = interp_cubic(t2)
    end
    return X2
end

function parse_snopt_summary(file="snopt-summary.out")
    props = Dict()

    function stash_prop(ln::String,prop::String,prop_name::String=prop)
        if contains(ln, prop)
            loc = search(ln,prop)
            val = Int(float(split(ln[loc[end]+1:end])[1]))
            props[prop_name] = val
        end
    end

    open(file) do f
        for ln in eachline(f)
            stash_prop(ln,"No. of iterations","iterations")
            stash_prop(ln,"No. of major iterations","major iterations")
            stash_prop(ln,"No. of calls to funobj","objective calls")
        end
    end
    return props
end