using Plots
using MeshCat
using GeometryTypes
using CoordinateTransformations
using FileIO
using MeshIO
const TO = TrajectoryOptimization

include("visualization.jl")
include("methods.jl")
include("models.jl")

n_lift = quadrotor_lift.n
m_lift = quadrotor_lift.m

n_load = doubleintegrator3D_load.n
m_load = doubleintegrator3D_load.m

# Robot sizes
r_lift = 0.275
r_load = 0.2

# Control limits for lift robots
u_lim_l = -Inf*ones(m_lift)
u_lim_u = Inf*ones(m_lift)
u_lim_l[1:4] .= 0.
u_lim_u[1:4] .= 12.0/4.0
x_lim_l_lift = -Inf*ones(n_lift)
x_lim_l_lift[3] = 0.

x_lim_l_load = -Inf*ones(n_load)
x_lim_l_load[3] = 0.

bnd1 = BoundConstraint(n_lift,m_lift,u_min=u_lim_l,u_max=u_lim_u)
bnd2 = BoundConstraint(n_lift,m_lift,u_min=u_lim_l,u_max=u_lim_u,x_min=x_lim_l_lift)
bnd3 = BoundConstraint(n_load,m_load,x_min=x_lim_l_load)

# Obstacles
r_cylinder = 0.5

_cyl = []
push!(_cyl,(3.75,1.,r_cylinder))
push!(_cyl,(3.75,-1.,r_cylinder))

function cI_cylinder_lift(c,x,u)
    for i = 1:length(_cyl)
        c[i] = circle_constraint(x[1:3],_cyl[i][1],_cyl[i][2],_cyl[i][3] + 1.25*r_lift)
    end
end
obs_lift = Constraint{Inequality}(cI_cylinder_lift,n_lift,m_lift,length(_cyl),:obs_lift)

function cI_cylinder_load(c,x,u)
    for i = 1:length(_cyl)
        c[i] = circle_constraint(x[1:3],_cyl[i][1],_cyl[i][2],_cyl[i][3] + 1.25*r_load)
    end
end
obs_load = Constraint{Inequality}(cI_cylinder_load,n_load,m_load,length(_cyl),:obs_load)

shift_ = zeros(n_lift)
shift_[1:3] = [0.0;0.0;0.0]
scaling = 1.25
x10 = zeros(n_lift)
x10[4] = 1.
x10[1:3] = scaling*[sqrt(8/9);0.;4/3]
x10 += shift_
x20 = zeros(n_lift)
x20[4] = 1.
x20[1:3] = scaling*[-sqrt(2/9);sqrt(2/3);4/3]
x20 += shift_
x30 = zeros(n_lift)
x30[4] = 1.
x30[1:3] = scaling*[-sqrt(2/9);-sqrt(2/3);4/3]
x30 += shift_
xload0 = zeros(n_load)
xload0[3] = 4/6
xload0[1:3] += shift_[1:3]

xlift0 = [x10,x20,x30]

_shift = zeros(n_lift)
_shift[1:3] = [7.5;0.0;0.0]

# goal state
xloadf = zeros(n_load)
xloadf[1:3] = xload0[1:3] + _shift[1:3]
x1f = copy(x10) + _shift
x2f = copy(x20) + _shift
x3f = copy(x30) + _shift

xliftf = [x1f,x2f,x3f]

# midpoint desired configuration
ℓ1 = norm(x30[1:3]-x10[1:3])
norm(x10[1:3]-x20[1:3])
norm(x20[1:3]-x30[1:3])

ℓ2 = norm(xload0[1:3]-x10[1:3])
norm(xload0[1:3]-x20[1:3])
norm(xload0[1:3]-x30[1:3])

ℓ3 = 0.

_shift_ = zeros(n_lift)
_shift_[1] = 3.75

x1m = copy(x10)
x1m += _shift_
x1m[1] += ℓ3
x3m = copy(x1m)
x3m[1] -= ℓ1
x3m[1] -= ℓ3
x2m = copy(x1m)
x2m[1] = 3.75
x2m[3] = ℓ2 - 0.5*sqrt(4*ℓ2^2 - ℓ1^2 + ℓ3*2) + x20[3]

xliftmid = [x1m,x2m,x3m]


# Discretization
N = 101
Nmid = Int(floor(N/2))
dt = 0.1

# Objectives
q_diag = ones(n_lift)

q_diag1 = copy(q_diag)
q_diag2 = copy(q_diag)
q_diag3 = copy(q_diag)
# q_diag1[1] = 1.0
# q_diag2[1] = 1.5e-2
# q_diag3[1] = 1.0e-3
q_diag1[1] = 1.0e-3
q_diag2[1] = 1.0e-3
q_diag3[1] = 1.0e-3
# q_diag1[3] = 1.0e-3
# q_diag2[3] = 1.0e-3
# q_diag3[3] = 1.0e-3


r_diag = ones(m_lift)
r_diag[1:4] .= 1.0e-6
r_diag[5:7] .= 1.0e-6
Q_lift = [1.0e-1*Diagonal(q_diag1), 1.0e-1*Diagonal(q_diag2), 1.0e-1*Diagonal(q_diag3)]
Qf_lift = [1000.0*Diagonal(q_diag), 1000.0*Diagonal(q_diag), 1000.0*Diagonal(q_diag)]
R_lift = Diagonal(r_diag)
Q_load = 0.0*Diagonal(I,n_load)
Qf_load = 0.0*Diagonal(I,n_load)
R_load = 1.0e-6*Diagonal(I,m_load)

q_mid = zeros(n_lift)
q_mid[1:3] .= 100.0

Q_mid = Diagonal(q_mid)
cost_mid = [LQRCost(Q_mid,R_lift,xliftmid[i]) for i = 1:num_lift]

obj_lift = [LQRObjective(Q_lift[i],R_lift,Qf_lift[i],xliftf[i],N) for i = 1:num_lift]
# update mid cost function
for i = 1:num_lift
    obj_lift[i].cost[Nmid] = cost_mid[i]
end
obj_load = LQRObjective(Q_load,R_load,Qf_load,xloadf,N)

# Constraints
constraints_lift = []
for i = 1:num_lift
    con = Constraints(N)
    con[1] += bnd1
    for k = 2:N-1
        con[k] += bnd2 + obs_lift
    end
    # con[N] += goal_constraint(xliftf[i])
    push!(constraints_lift,copy(con))
end

constraints_load = Constraints(N)
for k = 2:N-1
    constraints_load[k] +=  bnd3 + obs_load
end
constraints_load[N] += goal_constraint(xloadf)

# Initial controls
u_load = [0.;0.;-9.81*0.35/num_lift]

u_lift = zeros(m_lift)
u_lift[1:4] .= 9.81*(quad_params.m)/4.
u_lift[5:7] = u_load
U0_lift = [u_lift for k = 1:N-1]
U0_load = [-1.0*[u_load;u_load;u_load] for k = 1:N-1]

# Create problems
prob_lift = [Problem(quadrotor_lift,
                obj_lift[i],
                U0_lift,
                integration=:midpoint,
                constraints=constraints_lift[i],
                x0=xlift0[i],
                xf=xliftf[i],
                N=N,
                dt=dt)
                for i = 1:num_lift]

prob_load = Problem(doubleintegrator3D_load,
                obj_load,
                U0_load,
                integration=:midpoint,
                constraints=constraints_load,
                x0=xload0,
                xf=xloadf,
                N=N,
                dt=dt)

# Solver options
verbose=true

opts_ilqr = iLQRSolverOptions(verbose=true,
      iterations=500)

opts_al = AugmentedLagrangianSolverOptions{Float64}(verbose=verbose,
    opts_uncon=opts_ilqr,
    cost_tolerance=1.0e-5,
    constraint_tolerance=1.0e-3,
    cost_tolerance_intermediate=1.0e-4,
    iterations=10,
    penalty_scaling=2.0,
    penalty_initial=10.)


# Solve
@time plift_al, pload_al, slift_al, sload_al = solve_admm(prob_lift,prob_load,n_slack,:parallel,opts_al)
# @time plift_al, pload_al, slift_al, sload_al = solve_admm(prob_lift,prob_load,n_slack,:sequential,opts_al)

# Visualize
vis = Visualizer()
open(vis)
visualize_quadrotor_lift_system(vis, [[pload_al]; plift_al],_cyl)

idx = [(1:3)...,(8:10)...]
plot(plift_al[1].U,label="")
plot(plift_al[1].X,8:10)
plot(plift_al[1].X,1:3)



output_traj(plift_al[1],idx,joinpath(pwd(),"examples/ADMM/traj0.txt"))
output_traj(plift_al[2],idx,joinpath(pwd(),"examples/ADMM/traj1.txt"))
output_traj(plift_al[3],idx,joinpath(pwd(),"examples/ADMM/traj2.txt"))