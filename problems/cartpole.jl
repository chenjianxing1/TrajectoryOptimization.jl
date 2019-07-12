# Cartpole
T = Float64
model = TrajectoryOptimization.Dynamics.cartpole_model
model_d = rk3(model)
n = model.n; m = model.m

# costs
Q = 1.0e-1*Diagonal(I,n)
Qf = 1000.0*Diagonal(I,n)
R = 1.0e-2*Diagonal(I,m)
x0 = [0; 0.; 0.; 0.]
xf = [0.; pi; 0.; 0.] # (ie, swing up)

N = 101
tf = 5.
dt = tf/(N-1)
U0 = [zeros(m) for k = 1:N-1]
obj = TrajectoryOptimization.LQRObjective(Q,R,Qf,xf,N)
bnd = BoundConstraint(n,m,u_min=-10.,u_max=10.,trim=true)
constraints = Constraints([bnd],N)
goal = goal_constraint(xf)

cartpole_problem = TrajectoryOptimization.Problem(model_d, obj, constraints=constraints,x0=x0, xf=xf, N=N, dt=dt)
cartpole_problem.constraints[N] += goal
initial_controls!(cartpole_problem, U0)
