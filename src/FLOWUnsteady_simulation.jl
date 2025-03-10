#=##############################################################################
# DESCRIPTION
    Simulation driver.

# AUTHORSHIP
  * Author    : Eduardo J. Alvarez
  * Email     : Edo.AlvarezR@gmail.com
  * Created   : Oct 2019
  * License   : MIT
=###############################################################################



function run_simulation(sim::Simulation, nsteps::Int;
                             # SIMULATION OPTIONS
                             rand_RPM=false,            # Randomize RPM fluctuations
                             Vinf=(X,t)->zeros(3),      # Freestream velocity
                             sound_spd=343,             # (m/s) speed of sound
                             rho=1.225,                 # (kg/m^3) air density
                             mu=1.81e-5,                # Air dynamic viscosity
                             tquit=Inf,                 # (s) time at which to quit the simulation
                             # SOLVERS OPTIONS
                             max_particles=Int(1e5),    # Maximum number of particles
                             max_static_particles=nothing, # Maximum number of static particles (nothing to automatically estimate it)
                             p_per_step=1,              # Particle sheds per time step
                             vpm_formulation=vpm.formulation_rVPM, # VPM formulation
                             vpm_kernel=vpm.gaussianerf,# VPM kernel
                             vpm_UJ=vpm.UJ_fmm,         # VPM particle-to-particle interaction calculation
                             vpm_SFS=vpm.SFS_none,      # VPM LES subfilter-scale model
                             vpm_integration=vpm.rungekutta3, # VPM time integration scheme
                             vpm_transposed=true,       # VPM transposed stretching scheme
                             vpm_viscous=vpm.Inviscid(),# VPM viscous diffusion scheme
                             vpm_fmm=vpm.FMM(; p=4, ncrit=50, theta=0.4, phi=0.5), # VPM's FMM options
                             vpm_relaxation=vpm.pedrizzetti, # VPM relaxation scheme
                             vpm_surface=true,          # Whether to include surfaces in the VPM
                             vlm_vortexsheet=false,     # Whether to spread the surface circulation of the VLM as a vortex sheet in the VPM
                             vlm_vortexsheet_overlap=2.125, # Overlap of particles that make the vortex sheet
                             vlm_vortexsheet_distribution=g_uniform, # Circulation distribution of vortex sheet
                             vlm_vortexsheet_sigma_tbv=nothing, # Size of particles in trailing bound vortices (defaults to sigma_vlm_surf if not given)
                             vlm_rlx=-1,                # VLM relaxation
                             vlm_init=false,            # Initialize the first step with the VLM semi-infinite wake solution
                             hubtiploss_correction=vlm.hubtiploss_nocorrection, # Hub and tip loss correction of rotors (ignored by quasi-steady solver)
                             wake_coupled=true,         # Couple VPM wake on VLM solution
                             shed_unsteady=true,        # Whether to shed unsteady-loading wake
                             unsteady_shedcrit=0.01,    # Criterion for unsteady-loading shedding
                             shed_starting=false,       # Whether to shed starting vortex (only with shed_unsteady==true)
                             shed_boundarylayer=false,  # Whether to shed vorticity from boundary layer of surfaces
                             boundarylayer_prescribedCd=0.1, # Prescribed Cd for boundary layer shedding used for wings
                             boundarylayer_d=0.0,       # Dipole width for boundary layer shedding
                             omit_shedding=[],          # Indices of elements in `sim.vehicle.wake_system` on which omit shedding VPM particles
                             extra_runtime_function=(sim, PFIELD,T,DT)->false,
                             # REGULARIZATION OPTIONS
                             sigma_vlm_solver=-1,       # Regularization of VLM solver (internal)
                             sigma_vlm_surf=-1,         # Size of embedded particles representing VLM surfaces (for VLM-on-VPM and VLM-on-Rotor)
                             sigma_rotor_surf=-1,       # Size of embedded particles representing rotor blade surfaces (for Rotor-on-VPM, Rotor-on-VLM, and Rotor-on-Rotor)
                             sigmafactor_vpm=1.0,       # Core overlap of wake particles
                             sigmafactor_vpmonvlm=1,    # Shrinks the particles by this factor when calculating VPM-on-VLM/Rotor induced velocities
                             sigma_vpm_overwrite=nothing,   # Overwrite cores of wake to this value (ignoring sigmafactor_vpm)
                             # RESTART OPTIONS
                             restart_vpmfile=nothing,   # VPM particle field restart file
                             # OUTPUT OPTIONS
                             save_path="temps/flowunsteadysimulation00",
                             run_name="FLOWUnsteady-sim",
                             create_savepath=true,      # Whether to create save_path
                             prompt=true,
                             verbose=true, v_lvl=0, verbose_nsteps=10,
                             debug=false,               # Output extra states for debugging
                             nsteps_save=1,             # Save vtks every this many steps
                             nsteps_restart=-1,         # Save jlds every this many steps
                             save_code="",              # Saves the source code in this path
                             save_horseshoes=false,     # Save VLM horseshoes
                             save_static_particles=true,# Whether to save particles to represent the VLM
                             save_wopwopin=true,        # Generate inputs for PSU-WOPWOP
                             )


    if wake_coupled==false
        @warn("Running wake-decoupled simulation")
    end

    if shed_unsteady==false
        @warn("Unsteady wake shedding is disabled!")
    end

    if sigma_vlm_surf<=0
        error("Received invalid vehicle surface regularization"*
                " (sigma_vlm_surf=$sigma_vlm_surf).")
    end

    if sigma_rotor_surf<=0
        error("Received invalid rotor surface regularization"*
                " (sigma_rotor_surf=$sigma_rotor_surf).")
    end

    if sigmafactor_vpmonvlm <= 0
        error("Invalid `sigmafactor_vpmonvlm` value (`sigmafactor_vpmonvlm=$(sigmafactor_vpmonvlm)`).")
    end

    ############################################################################
    # SOLVERS SETUP
    ############################################################################
    dt = sim.ttot/nsteps            # (s) time step

    if sigma_vlm_solver<=0
        vlm.VLMSolver._blobify(false)
    else
        vlm.VLMSolver._blobify(true)
        vlm.VLMSolver._smoothing_rad(sigma_vlm_solver)
    end


    # ---------------- SCHEMES -------------------------------------------------
    # Set up viscous scheme
    if vpm.isinviscid(vpm_viscous) == false
        vpm_viscous.nu = mu/rho
        if vpm.iscorespreading(vpm_viscous) && sigma_vpm_overwrite!=nothing
            vpm_viscous.sgm0 = sigma_vpm_overwrite
        end
    end

    # Initiate particle field
    vpm_solver = [
                    (:formulation, vpm_formulation),
                    (:viscous, vpm_viscous),
                    (:kernel, vpm_kernel),
                    (:UJ, vpm_UJ),
                    (:SFS, vpm_SFS),
                    (:integration, vpm_integration),
                    (:transposed, vpm_transposed),
                    (:relaxation, vpm_relaxation),
                    (:fmm, vpm_fmm),
                 ]
    Xdummy = zeros(3)
    pfield = vpm.ParticleField(max_particles; Uinf=t->Vinf(Xdummy, t),
                                                                  vpm_solver...)

    max_staticp = max_static_particles==nothing ? 3*_get_m_static(sim.vehicle) : max_static_particles
    staticpfield = vpm.ParticleField(max_staticp; Uinf=t->Vinf(Xdummy, t),
                                                                  vpm_solver...)

    if vpm_surface && max_static_particles==nothing && vlm_vortexsheet
        @warn("Vortex sheet representation of VLM has been requested, but "*
              "no `max_static_particles` has been provided. It will be set to "*
              "$(max_staticp) which may lead to particle overflow. Please "*
              "provide a higher `max_static_particles` in order to avoid "*
              "overflow.")
    end

    if restart_vpmfile!=nothing
        vpm.read!(pfield, restart_vpmfile; overwrite=true, load_time=false)
    end


    ############################################################################
    # SIMULATION RUNTIME FUNCTION
    ############################################################################

    """
        This function gets called by `vpm.run_vpm!` at every time step.
    """
    function runtime_function(PFIELD, T, DT; vprintln=(args...)->nothing)

        # Move tilting systems, and translate and rotate vehicle
        nextstep_kinematic(sim, dt)

        # Solver-specific pre-calculations
        precalculations(sim, Vinf, PFIELD, T, DT)

        # Shed semi-infinite wake
        shed_wake(sim.vehicle, Vinf, PFIELD, DT, sim.nt; t=T,
                            unsteady_shedcrit=-1,
                            p_per_step=p_per_step, sigmafactor=sigmafactor_vpm,
                            overwrite_sigma=sigma_vpm_overwrite,
                            omit_shedding=omit_shedding)

        # Solve aerodynamics of the vehicle
        solve(sim, Vinf, PFIELD, wake_coupled, DT, vlm_rlx,
                sigma_vlm_surf, sigma_rotor_surf, rho, sound_spd,
                staticpfield, hubtiploss_correction;
                init_sol=vlm_init, sigmafactor_vpmonvlm=sigmafactor_vpmonvlm,
                debug=debug)

        # Shed unsteady-loading wake with new solution
        if shed_unsteady
            shed_wake(sim.vehicle, Vinf, PFIELD, DT, sim.nt; t=T,
                        unsteady_shedcrit=unsteady_shedcrit,
                        shed_starting=shed_starting,
                        p_per_step=p_per_step, sigmafactor=sigmafactor_vpm,
                        overwrite_sigma=sigma_vpm_overwrite,
                        omit_shedding=omit_shedding)
        end

        if shed_boundarylayer
            shed_wake(sim.vehicle, Vinf, PFIELD, DT, sim.nt; t=T,
                        unsteady_shedcrit=-1,
                        p_per_step=p_per_step, sigmafactor=sigmafactor_vpm,
                        overwrite_sigma=sigma_vpm_overwrite,
                        omit_shedding=omit_shedding,
                        shed_boundarylayer=true,
                        prescribed_Cd=boundarylayer_prescribedCd,
                        dipole_d=boundarylayer_d)
        end

        # Simulation-specific postprocessing
        breakflag = extra_runtime_function(sim, PFIELD, T, DT; vprintln=vprintln)

        # Output vtks
        if save_path!=nothing && PFIELD.nt%nsteps_save==0
            strn = save_vtk(sim, run_name; path=save_path,
                            save_horseshoes=save_horseshoes,
                            save_wopwopin=save_wopwopin)
        end

        breakflag2 = sim.t >= tquit

        if breakflag2
            vprintln("Quitting time $(tquit) (s) has been reached. Simulation will now end.")
        end

        return breakflag || breakflag2
    end

    if vpm_surface
        static_particles_function = generate_static_particle_fun(pfield, staticpfield,
                                    sim.vehicle, sigma_vlm_surf, sigma_rotor_surf;
                                    vlm_vortexsheet=vlm_vortexsheet,
                                    vlm_vortexsheet_overlap=vlm_vortexsheet_overlap,
                                    vlm_vortexsheet_distribution=vlm_vortexsheet_distribution,
                                    vlm_vortexsheet_sigma_tbv=vlm_vortexsheet_sigma_tbv,
                                    save_path=save_static_particles ? save_path : nothing,
                                    run_name=run_name, nsteps_save=nsteps_save)
    else
        static_particles_function = (pfield, t, dt)->nothing
    end

    ############################################################################
    # RUN SIMULATION
    ############################################################################
    # Here it uses the VPM-time-stepping to run the simulation
    vpm.run_vpm!(pfield, dt, nsteps;
                      save_path=save_path, run_name=run_name*"_pfield",
                      verbose=verbose, verbose_nsteps=verbose_nsteps,
                      v_lvl=v_lvl,
                      create_savepath=create_savepath,
                      runtime_function=runtime_function,
                      nsteps_save=nsteps_save,
                      save_code=save_code,
                      prompt=prompt,
                      static_particles_function=static_particles_function,
                      save_time=false
                      )

    return pfield
end





function add_particle(pfield::vpm.ParticleField, X::Array{Float64, 1},
                        gamma::Float64, dt::Float64,
                        V::Float64, infD::Array{Float64, 1},
                        sigma::Float64, vol::Float64,
                        l::Array{T1, 1}, p_per_step::Int64;
                        overwrite_sigma=nothing) where {T1<:Real}

    Gamma = gamma*(V*dt)*infD       # Vectorial circulation

    # Avoid adding empty particles to the computational domain, or ExaFMM will
    # blow up
    if sqrt(Gamma[1]^2 + Gamma[2]^2 + Gamma[3]^2) <= 5*eps(vpm.RealFMM)
        Gamma = 5*eps(vpm.RealFMM)*ones(3)
    end

    circulation = max(abs(gamma), 5*eps(vpm.RealFMM))

    # Decreases p_per_step for slowly moving parts of blade
    # aux = min((sigma/p_per_step)/overwrite_sigma, 1)
    # pps = max(1, min(p_per_step, floor(Int, 1/(1-(aux-1e-14))) ))
    pps = p_per_step

    if overwrite_sigma==nothing
        sigmap = sigma/pps
    else
        sigmap = overwrite_sigma
    end

    # Adds p_per_step particles along line l
    dX = l/pps
    for i in 1:pps
        vpm.add_particle(pfield, X + i*dX - dX/2, Gamma/pps, sigmap;
                            vol=vol/pps, circulation=circulation)
    end
end

"""
Returns the velocity induced by particle field on every position `Xs`
"""
function Vvpm_on_Xs(pfield::vpm.ParticleField, Xs::Array{T, 1}; static_particles_fun=(args...)->nothing, dt=0, fsgm=1) where {T}

    if length(Xs)!=0 && vpm.get_np(pfield)!=0
        # Omit freestream
        Uinf = pfield.Uinf
        pfield.Uinf = (t)->zeros(3)

        org_np = vpm.get_np(pfield)             # Original particles

        # Singularize particles to correct tip loss
        # NOTE: This doesn't include static particles, but there shouldn't be
        #       any in the field at this point anyways
        if abs(fsgm) != 1
            for P in vpm.iterator(pfield)
                P.sigma .*= fsgm
            end
        end

        # Add static particles
        static_particles_fun(pfield, pfield.t, dt)

        sta_np = vpm.get_np(pfield)             # Original + static particles

        # Add probes
        for X in Xs
            add_probe(pfield, X)
        end

        # Evaluate velocity field
        pfield.UJ(pfield)

        # Retrieve velocity at probes
        Vvpm = [Array(P.U) for P in vpm.iterator(pfield; start_i=sta_np+1)]

        # Remove static particles and probes
        for pi in vpm.get_np(pfield):-1:(org_np+1)
            vpm.remove_particle(pfield, pi)
        end

        # De-singularize particles
        if abs(fsgm) != 1
            for P in vpm.iterator(pfield)
                P.sigma ./= fsgm
            end
        end

        # Restore freestream
        pfield.Uinf = Uinf
    else
        Vvpm = [zeros(3) for i in 1:length(Xs)]
    end

    return Vvpm
end

add_probe(pfield::vpm.ParticleField, X) = vpm.add_particle(pfield, X, zeros(3), 1e-6; vol=0)
