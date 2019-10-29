# Follows the implementation of the Gurobi MOI Wrapper
# https://github.com/JuliaOpt/Gurobi.jl/blob/master/src/MOI_wrapper.jl

import MathOptInterface

const MOI = MathOptInterface
const CleverDicts = MOI.Utilities.CleverDicts

@enum(VariableType, CONTINUOUS, BINARY, INTEGER, SEMIINTEGER, SEMICONTINUOUS)
@enum(BoundType, NONE, LESS_THAN, GREATER_THAN, LESS_AND_GREATER_THAN, INTERVAL, EQUAL_TO)
@enum(ObjectiveType, SINGLE_VARIABLE, SCALAR_AFFINE, SCALAR_QUADRATIC)

const SCALAR_SETS = Union{
    MOI.GreaterThan{Float64}, MOI.LessThan{Float64},
    MOI.EqualTo{Float64}, MOI.Interval{Float64}
}

mutable struct VariableInfo
    index::MOI.VariableIndex
    column::Int
    bound::BoundType
    type::VariableType
    start::Union{Float64, Nothing}
    name::String
    # Storage for constraint names associated with variables because Gurobi
    # can only store names for variables and proper constraints.
    # We can perform an optimization and only store three strings for the
    # constraint names because, at most, there can be three SingleVariable
    # constraints, e.g., LessThan, GreaterThan, and Integer.
    lessthan_name::String
    greaterthan_interval_or_equalto_name::String
    type_constraint_name::String
    function VariableInfo(index::MOI.VariableIndex, column::Int)
        return new(index, column, NONE, CONTINUOUS, nothing, "", "", "", "", nothing)
    end
end

mutable struct ConstraintInfo
    row::Int
    set::MOI.AbstractSet
    # Storage for constraint names. Where possible, these are also stored in the
    # Xpress model.
    name::String
    ConstraintInfo(row::Int, set) = new(row, set, "")
end

mutable struct Optimizer <: MOI.AbstractOptimizer
    # The low-level Xpress model.
    inner::Model
    # The Xpress environment. If `nothing`, a new environment will be created
    # on `MOI.empty!`.
    # env::Union{Nothing, Env}
    # The current user-provided parameters for the model.
    params::Dict{String, Any}

    # The next field is used to cleverly manage calls to `update_model!`.
    # `needs_update` is used to record whether an update should be called before
    # accessing a model attribute (such as the value of a RHS term).
    #needs_update::Bool

    # A flag to keep track of MOI.Silent, which over-rides the OutputFlag
    # parameter.
    silent::Bool

    # An enum to remember what objective is currently stored in the model.
    objective_type::ObjectiveType

    # Pending to check for Xpress.
    # A flag to keep track of MOI.FEASIBILITY_SENSE, since Gurobi only stores
    # MIN_SENSE or MAX_SENSE. This allows us to differentiate between MIN_SENSE
    # and FEASIBILITY_SENSE.
    is_feasibility::Bool

    # A mapping from the MOI.VariableIndex to the Xpress column. VariableInfo
    # also stores some additional fields like what bounds have been added, the
    # variable type, and the names of SingleVariable-in-Set constraints.
    variable_info::CleverDicts.CleverDict{MOI.VariableIndex, VariableInfo}

    # An index that is incremented for each new constraint (regardless of type).
    # We can check if a constraint is valid by checking if it is in the correct
    # xxx_constraint_info. We should _not_ reset this to zero, since then new
    # constraints cannot be distinguished from previously created ones.
    last_constraint_index::Int
    # ScalarAffineFunction{Float64}-in-Set storage.
    affine_constraint_info::Dict{Int, ConstraintInfo}
    # ScalarQuadraticFunction{Float64}-in-Set storage.
    quadratic_constraint_info::Dict{Int, ConstraintInfo}
    # VectorOfVariables-in-Set storage.
    sos_constraint_info::Dict{Int, ConstraintInfo}
    # Note: we do not have a singlevariable_constraint_info dictionary. Instead,
    # data associated with these constraints are stored in the VariableInfo
    # objects.

    # Mappings from variable and constraint names to their indices. These are
    # lazily built on-demand, so most of the time, they are `nothing`.
    name_to_variable::Union{Nothing, Dict{String, MOI.VariableIndex}}
    name_to_constraint_index::Union{Nothing, Dict{String, MOI.ConstraintIndex}}

    # These two flags allow us to distinguish between FEASIBLE_POINT and
    # INFEASIBILITY_CERTIFICATE when querying VariablePrimal and ConstraintDual.
    has_unbounded_ray::Bool
    has_infeasibility_cert::Bool

    # A helper cache for calling CallbackVariablePrimal.
    callback_variable_primal::Vector{Float64}

    variable_primal_solution::Vector{Float64}
    variable_dual_solution::Vector{}
    # constraint_primal_solution::Vector

    conflict::Union{Nothing, IISData}
    """
        Optimizer(env = nothing; kwargs...)

    Create a new Optimizer object.

    You can share Expr `Env`s between models by passing an model of `Env`
    as the first argument. By default, a new environment is created for every
    model.

    Note that we set the parameter `InfUnbdInfo` to `1` rather than the default
    of `0` so that we can query infeasibility certificates. Users are, however,
    free to over-ride this as follows `Optimizer(InfUndbInfo=0)`. In addition,
    we also set `QCPDual` to `1` to enable duals in QCPs. Users can override
    this by passing `Optimizer(QCPDual=0)`.
    """

    function Optimizer(; kwargs...)
        model = new()
        # model.env = env
        model.silent = false
        model.params = Dict{String, Any}()
        model.variable_info = CleverDicts.CleverDict{MOI.VariableIndex, VariableInfo}()
        model.affine_constraint_info = Dict{Int, ConstraintInfo}()
        model.quadratic_constraint_info = Dict{Int, ConstraintInfo}()
        model.sos_constraint_info = Dict{Int, ConstraintInfo}()
        model.last_constraint_index = 0
        model.callback_variable_primal = Float64[]
        MOI.empty!(model)  # MOI.empty!(model) re-sets the `.inner` field.
        #= TODO: These parameters are specific to Gurobi, needs update relevant to Xpress
        for (name, value) in kwargs
            model.params[string(name)] = value
            setparam!(model.inner, XPRS_CONTROLS_DICT[name], value)
        end
        if !haskey(model.params, "InfUnbdInfo")
            MOI.set(model, MOI.RawParameter("InfUnbdInfo"), 1)
        end
        if !haskey(model.params, "QCPDual")
            MOI.set(model, MOI.RawParameter("QCPDual"), 1)
        end
        =#
        return model
    end

end

setparam!(model::Optimizer, name, val) = setparam!(model.inner, XPRS_CONTROLS_DICT[name], val)

setlogfile!(model::Optimizer, path) = setlogfile(model.inner, path::String)

cintvec(v::Vector) = convert(Vector{Int32}, v)

Base.show(io::IO, model::Optimizer) = show(io, model.inner)

function MOI.empty!(model::Optimizer)
    model.inner = XPR.Model()
    # if model.env === nothing
        # model.inner = Model(Env(), finalize_env = true)
    # else
        # model.inner = Model(model.env, finalize_env = false)
    # end
    for (name, value) in model.params
        setparam!(model.inner, name, value)
    end
    if model.silent
        # Set the parameter on the internal model, but don't modify the entry in
        # model.params so that if Silent() is set to `true`, the user-provided
        # value will be restored.
        setparam!(model.inner, XPRS_OUTPUTLOG, 0)
    end
    model.objective_type = SCALAR_AFFINE
    model.is_feasibility = true
    empty!(model.variable_info)
    empty!(model.affine_constraint_info)
    empty!(model.quadratic_constraint_info)
    empty!(model.sos_constraint_info)
    model.name_to_variable = nothing
    model.name_to_constraint_index = nothing
    model.has_unbounded_ray = false
    model.has_infeasibility_cert = false
    empty!(model.callback_variable_primal)
    for (name,value) in model.params
        setparam!(model.inner, XPRS_CONTROLS_DICT[name], value)
    end
    model.conflict = nothing
    return
end

function MOI.is_empty(model::Optimizer)
    model.objective_type != SCALAR_AFFINE && return false
    model.is_feasibility == false && return false
    !isempty(model.variable_info) && return false
    length(model.affine_constraint_info) != 0 && return false
    length(model.quadratic_constraint_info) != 0 && return false
    length(model.sos_constraint_info) != 0 && return false
    model.name_to_variable !== nothing && return false
    model.name_to_constraint_index !== nothing && return false
    model.has_unbounded_ray && return false
    model.has_infeasibility_cert && return false
    length(model.callback_variable_primal) != 0 && return false
    return true
end

MOI.get(::Optimizer, ::MOI.SolverName) = "Xpress"

function MOI.supports(
    ::Optimizer,
    ::MOI.ObjectiveFunction{F}
) where {F <: Union{
    MOI.SingleVariable,
    MOI.ScalarAffineFunction{Float64},
    MOI.ScalarQuadraticFunction{Float64}
}}
    return true
end

#=
    (LQOI.SinVar, LQOI.EQ),
    (LQOI.SinVar, LQOI.LE),
    (LQOI.SinVar, LQOI.GE),
    (LQOI.SinVar, LQOI.IV),
    (LQOI.SinVar, MOI.ZeroOne),
    (LQOI.SinVar, MOI.Integer),
    # Not Supported (LQOI.SinVar, MOI.Semicontinuous{Float64}),
    # Not Supported (LQOI.SinVar, MOI.Semiinteger{Float64}),
=#
function MOI.supports_constraint(
    ::Optimizer, ::Type{MOI.SingleVariable}, ::Type{F}
) where {F <: Union{
    MOI.EqualTo{Float64}, MOI.LessThan{Float64}, MOI.GreaterThan{Float64},
    MOI.Interval{Float64}, MOI.ZeroOne, MOI.Integer
}}
    return true
end

#=
(LQOI.VecVar, LQOI.SOS1)
(LQOI.VecVar, LQOI.SOS2),
=#
function MOI.supports_constraint(
    ::Optimizer, ::Type{MOI.VectorOfVariables}, ::Type{F}
) where {F <: Union{MOI.SOS1{Float64}, MOI.SOS2{Float64},
            #MOI.SecondOrderCone. Added Later
            }}
    return true
end

#=
    (LQOI.Linear, LQOI.EQ),
    (LQOI.Linear, LQOI.LE),
    (LQOI.Linear, LQOI.GE),
    (LQOI.Linear, LQOI.IV),
=#
function MOI.supports_constraint(
    ::Optimizer, ::Type{MOI.ScalarAffineFunction{Float64}}, ::Type{F}
) where {F <: Union{
    MOI.EqualTo{Float64}, MOI.LessThan{Float64}, MOI.GreaterThan{Float64}, MOI.Interval{Float64}
}}
    return true
end

#=
    (LQOI.Quad, LQOI.EQ),
    (LQOI.Quad, LQOI.LE),
    (LQOI.Quad, LQOI.GE),
=#
function MOI.supports_constraint(
    ::Optimizer, ::Type{MOI.ScalarQuadraticFunction{Float64}}, ::Type{F}
) where {F <: Union{
    MOI.EqualTo{Float64}, MOI.LessThan{Float64}, MOI.GreaterThan{Float64}
}}
    return true
end

# Check that this what Xpress is actually going to support
function MOI.supports(
     ::Xpress.Optimizer, ::MOI.VariablePrimalStart, ::Type{MOI.VariableIndex})
    return true
end

function MOI.set(model::Optimizer, param::MOI.RawParameter, value)
    model.params[param.name] = value
    setparam!(model.inner, Symbol(param.name), value)
    return
end

function MOI.get(model::Optimizer, param::MOI.RawParameter)
    return getparam(model.inner, param.name)
end

function MOI.set(model::Optimizer, ::MOI.TimeLimitSec, limit::Real)
    MOI.set(model, MOI.RawParameter("TimeLimit"), limit)
    return
end

function MOI.get(model::Optimizer, ::MOI.TimeLimitSec)
    return MOI.get(model, MOI.RawParameter("TimeLimit"))
end

MOI.Utilities.supports_default_copy_to(::Optimizer, ::Bool) = true

function MOI.copy_to(dest::Optimizer, src::MOI.ModelLike; kwargs...)
    return MOI.Utilities.automatic_copy_to(dest, src; kwargs...)
end

function MOI.get(model::Optimizer, ::MOI.ListOfVariableAttributesSet)
    return MOI.AbstractVariableAttribute[MOI.VariableName()]
end

function MOI.get(model::Optimizer, ::MOI.ListOfModelAttributesSet)
    attributes = [
        MOI.ObjectiveSense(),
        MOI.ObjectiveFunction{MOI.ScalarAffineFunction{Float64}}()
    ]
    if MOI.get(model, MOI.Name()) != ""
        push!(attributes, MOI.Name())
    end
    return attributes
end

function MOI.get(model::Optimizer, ::MOI.ListOfConstraintAttributesSet)
    return MOI.AbstractConstraintAttribute[MOI.ConstraintName()]
end

function _indices_and_coefficients(
    indices::AbstractVector{Int}, coefficients::AbstractVector{Float64},
    model::Optimizer, f::MOI.ScalarAffineFunction{Float64}
)

    for (i, term) in enumerate(f.terms)
        indices[i] = _info(model, term.variable_index).column
        coefficients[i] = term.coefficient
    end
    return indices, coefficients
end

function _indices_and_coefficients(
    model::Optimizer, f::MOI.ScalarAffineFunction{Float64}
)
    f_canon = MOI.Utilities.canonical(f)
    nnz = length(f_canon.terms)
    indices = Vector{Int}(undef, nnz)
    coefficients = Vector{Float64}(undef, nnz)
    _indices_and_coefficients(indices, coefficients, model, f_canon)
    return indices, coefficients
end

function _indices_and_coefficients(
    I::AbstractVector{Int}, J::AbstractVector{Int}, V::AbstractVector{Float64},
    indices::AbstractVector{Int}, coefficients::AbstractVector{Float64},
    model::Optimizer, f::MOI.ScalarQuadraticFunction
)
    for (i, term) in enumerate(f.quadratic_terms)
        I[i] = _info(model, term.variable_index_1).column
        J[i] = _info(model, term.variable_index_2).column
        V[i] =  term.coefficient
        # Xpress does this according to page 14 of the reference Manual.
        # Xpress returns a list of terms. MOI requires 0.5 x' Q x. So, to get
        # from
        #   Xpress -> MOI => multiply diagonals by 2.0
        #   MOI -> Xpress => multiply diagonals by 0.5
        # Example: 2x^2 + x*y + y^2
        #   |x y| * |a b| * |x| = |ax+by bx+cy| * |x| = 0.5ax^2 + bxy + 0.5cy^2
        #           |b c|   |y|                   |y|
        #   Xpress needs: (I, J, V) = ([0, 0, 1], [0, 1, 1], [2, 1, 1])
        #   MOI needs:
        #     [SQT(4.0, x, x), SQT(1.0, x, y), SQT(2.0, y, y)]
        if I[i] == J[i]
            V[i] *= 0.5
        end
    end
    for (i, term) in enumerate(f.affine_terms)
        indices[i] = _info(model, term.variable_index).column
        coefficients[i] = term.coefficient
    end
    return
end

function _indices_and_coefficients(
    model::Optimizer, f::MOI.ScalarQuadraticFunction
)
    f_canon = MOI.Utilities.canonical(f)
    nnz_quadratic = length(f_canon.quadratic_terms)
    nnz_affine = length(f_canon.affine_terms)
    I = Vector{Int}(undef, nnz_quadratic)
    J = Vector{Int}(undef, nnz_quadratic)
    V = Vector{Float64}(undef, nnz_quadratic)
    indices = Vector{Int}(undef, nnz_affine)
    coefficients = Vector{Float64}(undef, nnz_affine)
    _indices_and_coefficients(I, J, V, indices, coefficients, model, f_canon)
    return indices, coefficients, I, J, V
end

_sense_and_rhs(s::MOI.LessThan{Float64}) = (XPRS_LEQ, s.upper)
_sense_and_rhs(s::MOI.GreaterThan{Float64}) = (XPRS_GEQ, s.lower)
_sense_and_rhs(s::MOI.EqualTo{Float64}) = (XPRS_EQ, s.value)

###
### Variables
###

# Short-cuts to return the VariableInfo associated with an index.
function _info(model::Optimizer, key::MOI.VariableIndex)
    if haskey(model.variable_info, key)
        return model.variable_info[key]
    end
    throw(MOI.InvalidIndex(key))
end

function MOI.add_variable(model::Optimizer)
    # Initialize `VariableInfo` with a dummy `VariableIndex` and a column,
    # because we need `add_item` to tell us what the `VariableIndex` is.
    index = CleverDicts.add_item(
        model.variable_info, VariableInfo(MOI.VariableIndex(0), 0)
    )
    info = _info(model, index)
    # Now, set `.index` and `.column`.
    info.index = index
    info.column = length(model.variable_info)
    Xpress.addcols(model.inner, [0.0], [-Inf], [Inf])
    return index
end

function MOI.add_variables(model::Optimizer, N::Int)
    Xpress.addcols(model.inner, fill(0.0, N), fill(-Inf, N), fill(Inf, N))
    indices = Vector{MOI.VariableIndex}(undef, N)
    num_variables = length(model.variable_info)
    for i in 1:N
        # Initialize `VariableInfo` with a dummy `VariableIndex` and a column,
        # because we need `add_item` to tell us what the `VariableIndex` is.
        index = CleverDicts.add_item(
            model.variable_info, VariableInfo(MOI.VariableIndex(0), 0)
        )
        info = _info(model, index)
        # Now, set `.index` and `.column`.
        info.index = index
        info.column = num_variables + i
        indices[i] = index
    end
    return indices
end

function MOI.is_valid(model::Optimizer, v::MOI.VariableIndex)
    return haskey(model.variable_info, v)
end

function MOI.delete(model::Optimizer, v::MOI.VariableIndex)
    info = _info(model, v)
    Xpress.del_vars!(model.inner, Cint[info.column])
    delete!(model.variable_info, v)
    for other_info in values(model.variable_info)
        if other_info.column > info.column
            other_info.column -= 1
        end
    end
    model.name_to_variable = nothing
    return
end

function MOI.get(model::Optimizer, ::Type{MOI.VariableIndex}, name::String)
    if model.name_to_variable === nothing
        _rebuild_name_to_variable(model)
    end
    return get(model.name_to_variable, name, nothing)
end

function _rebuild_name_to_variable(model::Optimizer)
    model.name_to_variable = Dict{String, MOI.VariableIndex}()
    for (index, info) in model.variable_info
        if info.name == ""
            continue
        end
        if haskey(model.name_to_variable, info.name)
            model.name_to_variable = nothing
            error("Duplicate variable name detected: $(info.name)")
        end
        model.name_to_variable[info.name] = index
    end
    return
end

function MOI.get(model::Optimizer, ::MOI.VariableName, v::MOI.VariableIndex)
    return _info(model, v).name
end

function MOI.set(
    model::Optimizer, ::MOI.VariableName, v::MOI.VariableIndex, name::String
)
    info = _info(model, v)
    if !isempty(info.name) && model.name_to_variable !== nothing
        delete!(model.name_to_variable, info.name)
    end
    info.name = name
    if isempty(name)
        return
    end
    Xpress.addcolname(model.inner, name)

    if model.name_to_variable === nothing
        return
    end
    if haskey(model.name_to_variable, name)
        model.name_to_variable = nothing
    else
        model.name_to_variable[name] = v
    end
    return
end

###
### Objectives
###

function MOI.set(
    model::Optimizer, ::MOI.ObjectiveSense, sense::MOI.OptimizationSense
)
    if sense == MOI.MIN_SENSE
        Xpress.set_sense!(model.inner, :minimize)
        model.is_feasibility = false
    elseif sense == MOI.MAX_SENSE
        Xpress.set_sense!(model.inner, :maximize)
        model.is_feasibility = false
    elseif sense == MOI.FEASIBILITY_SENSE
        Xpress.set_sense!(model.inner, :minimize)
        model.is_feasibility = true
    else
        error("Invalid objective sense: $(sense)")
    end

    return
end

function MOI.get(model::Optimizer, ::MOI.ObjectiveSense)
    sense = model_sense(model.inner)
    if model.is_feasibility
        return MOI.FEASIBILITY_SENSE
    elseif sense == :maximize
        return MOI.MAX_SENSE
    elseif sense == :minimize
        return MOI.MIN_SENSE
    end
    error("Invalid objective sense: $(sense)")
end

function MOI.set(
    model::Optimizer, ::MOI.ObjectiveFunction{F}, f::F
) where {F <: MOI.SingleVariable}
    MOI.set(
        model, MOI.ObjectiveFunction{MOI.ScalarAffineFunction{Float64}}(),
        convert(MOI.ScalarAffineFunction{Float64}, f)
    )
    model.objective_type = SINGLE_VARIABLE
    return
end

function MOI.get(model::Optimizer, ::MOI.ObjectiveFunction{MOI.SingleVariable})
    obj = MOI.get(model, MOI.ObjectiveFunction{MOI.ScalarAffineFunction{Float64}}())
    return convert(MOI.SingleVariable, obj)
end

function MOI.set(
    model::Optimizer, ::MOI.ObjectiveFunction{F}, f::F
) where {F <: MOI.ScalarAffineFunction{Float64}}
    if model.objective_type == SCALAR_QUADRATIC
        # We need to zero out the existing quadratic objective.
        Xpress.delq!(model.inner)
    end
    num_vars = length(model.variable_info)
    obj = zeros(Float64, num_vars)
    for term in f.terms
        column = _info(model, term.variable_index).column
        obj[column] += term.coefficient
    end
    set_obj!(model.inner, obj)
    model.objective_type = SCALAR_AFFINE
end

function MOI.get(
    model::Optimizer, ::MOI.ObjectiveFunction{MOI.ScalarAffineFunction{Float64}}
)
    if model.objective_type == SCALAR_QUADRATIC
        error("Unable to get objective function. Currently: $(model.objective_type).")
    end

    dest = zeros(length(model.variable_info))
    get_obj!(model.inner, dest)

    terms = MOI.ScalarAffineTerm{Float64}[]
    for (index, info) in model.variable_info
        coefficient = dest[info.column]
        iszero(coefficient) && continue
        push!(terms, MOI.ScalarAffineTerm(coefficient, index))
    end

    constant = get_dblattr(model.inner, XPRS_OBJRHS)
    return MOI.ScalarAffineFunction(terms, constant)
end

function MOI.set(
    model::Optimizer, ::MOI.ObjectiveFunction{F}, f::F
) where {F <: MOI.ScalarQuadraticFunction{Float64}}
    affine_indices, affine_coefficients, I, J, V = _indices_and_coefficients(model, f)
    # We need to zero out any existing linear objective.
    obj = zeros(length(model.variable_info))
    for (i, c) in zip(affine_indices, affine_coefficients)
        obj[i] = c
    end
    set_obj!(model.inner, obj)
    # We need to zero out the existing quadratic objective.
    delq!(model.inner)
    add_qpterms!(model.inner, I, J, V)
    model.objective_type = SCALAR_QUADRATIC
    return
end

function MOI.get(
    model::Optimizer,
    ::MOI.ObjectiveFunction{MOI.ScalarQuadraticFunction{Float64}}
)
    dest = zeros(length(model.variable_info))
    get_obj!(model.inner, dest)
    terms = MOI.ScalarAffineTerm{Float64}[]
    for (index, info) in model.variable_info
        coefficient = dest[info.column]
        iszero(coefficient) && continue
        push!(terms, MOI.ScalarAffineTerm(coefficient, index))
    end
    q_terms = MOI.ScalarQuadraticTerm{Float64}[]
    I, J, V = getq_upper(model.inner)
    for (i, j, v) in zip(I, J, V)
        iszero(v) && continue
        # See note in `_indices_and_coefficients`.
        new_v = i == j ? 2v : v
        push!(
            q_terms,
            MOI.ScalarQuadraticTerm(
                new_v,
                model.variable_info[CleverDicts.LinearIndex(i + 1)].index,
                model.variable_info[CleverDicts.LinearIndex(j + 1)].index
            )
        )
    end
    constant = get_dblattr(model.inner, XPRS_OBJRHS)
    return MOI.ScalarQuadraticFunction(terms, q_terms, constant)
end

function MOI.modify(
    model::Optimizer,
    ::MOI.ObjectiveFunction{MOI.ScalarAffineFunction{Float64}},
    chg::MOI.ScalarConstantChange{Float64}
)
    set_objcoeffs!(model.inner, 0, chg.new_constant)

    return
end

##
##  SingleVariable-in-Set constraints.
##

function _info(
    model::Optimizer, c::MOI.ConstraintIndex{MOI.SingleVariable, <:Any}
)
    var_index = MOI.VariableIndex(c.value)
    if haskey(model.variable_info, var_index)
        return _info(model, var_index)
    end
    return throw(MOI.InvalidIndex(c))
end

function MOI.is_valid(
    model::Optimizer,
    c::MOI.ConstraintIndex{MOI.SingleVariable, MOI.LessThan{Float64}}
)
    if haskey(model.variable_info, MOI.VariableIndex(c.value))
        info = _info(model, c)
        return info.bound == LESS_THAN || info.bound == LESS_AND_GREATER_THAN
    end
    return false
end

function MOI.is_valid(
    model::Optimizer,
    c::MOI.ConstraintIndex{MOI.SingleVariable, MOI.GreaterThan{Float64}}
)
    if haskey(model.variable_info, MOI.VariableIndex(c.value))
        info = _info(model, c)
        return info.bound == GREATER_THAN || info.bound == LESS_AND_GREATER_THAN
    end
    return false
end

function MOI.is_valid(
    model::Optimizer,
    c::MOI.ConstraintIndex{MOI.SingleVariable, MOI.Interval{Float64}}
)
    return haskey(model.variable_info, MOI.VariableIndex(c.value)) &&
        _info(model, c).bound == INTERVAL
end

function MOI.is_valid(
    model::Optimizer,
    c::MOI.ConstraintIndex{MOI.SingleVariable, MOI.EqualTo{Float64}}
)
    return haskey(model.variable_info, MOI.VariableIndex(c.value)) &&
        _info(model, c).bound == EQUAL_TO
end

function MOI.is_valid(
    model::Optimizer,
    c::MOI.ConstraintIndex{MOI.SingleVariable, MOI.ZeroOne}
)
    return haskey(model.variable_info, MOI.VariableIndex(c.value)) &&
        _info(model, c).type == BINARY
end

function MOI.is_valid(
    model::Optimizer,
    c::MOI.ConstraintIndex{MOI.SingleVariable, MOI.Integer}
)
    return haskey(model.variable_info, MOI.VariableIndex(c.value)) &&
        _info(model, c).type == INTEGER
end

function MOI.is_valid(
    model::Optimizer,
    c::MOI.ConstraintIndex{MOI.SingleVariable, MOI.Semicontinuous{Float64}}
)
    return haskey(model.variable_info, MOI.VariableIndex(c.value)) &&
        _info(model, c).type == SEMICONTINUOUS
end

function MOI.is_valid(
    model::Optimizer,
    c::MOI.ConstraintIndex{MOI.SingleVariable, MOI.Semiinteger{Float64}}
)
    return haskey(model.variable_info, MOI.VariableIndex(c.value)) &&
        _info(model, c).type == SEMIINTEGER
end

function MOI.get(
    model::Optimizer, ::MOI.ConstraintFunction,
    c::MOI.ConstraintIndex{MOI.SingleVariable, <:Any}
)
    MOI.throw_if_not_valid(model, c)
    return MOI.SingleVariable(MOI.VariableIndex(c.value))
end

function MOI.set(
    model::Optimizer, ::MOI.ConstraintFunction,
    c::MOI.ConstraintIndex{MOI.SingleVariable, <:Any}, ::MOI.SingleVariable
)
    return throw(MOI.SettingSingleVariableFunctionNotAllowed())
end

_bounds(s::MOI.GreaterThan{Float64}) = (s.lower, nothing)
_bounds(s::MOI.LessThan{Float64}) = (nothing, s.upper)
_bounds(s::MOI.EqualTo{Float64}) = (s.value, s.value)
_bounds(s::MOI.Interval{Float64}) = (s.lower, s.upper)

function _throw_if_existing_lower(
    bound::BoundType, var_type::VariableType, new_set::Type{<:MOI.AbstractSet},
    variable::MOI.VariableIndex
)
    existing_set = if bound == LESS_AND_GREATER_THAN || bound == GREATER_THAN
        MOI.GreaterThan{Float64}
    elseif bound == INTERVAL
        MOI.Interval{Float64}
    elseif bound == EQUAL_TO
        MOI.EqualTo{Float64}
    elseif var_type == SEMIINTEGER
        MOI.Semiinteger{Float64}
    elseif var_type == SEMICONTINUOUS
        MOI.Semicontinuous{Float64}
    else
        nothing  # Also covers `NONE` and `LESS_THAN`.
    end
    if existing_set !== nothing
        throw(MOI.LowerBoundAlreadySet{existing_set, new_set}(variable))
    end
end

function _throw_if_existing_upper(
    bound::BoundType, var_type::VariableType, new_set::Type{<:MOI.AbstractSet},
    variable::MOI.VariableIndex
)
    existing_set = if bound == LESS_AND_GREATER_THAN || bound == LESS_THAN
        MOI.LessThan{Float64}
    elseif bound == INTERVAL
        MOI.Interval{Float64}
    elseif bound == EQUAL_TO
        MOI.EqualTo{Float64}
    elseif var_type == SEMIINTEGER
        MOI.Semiinteger{Float64}
    elseif var_type == SEMICONTINUOUS
        MOI.Semicontinuous{Float64}
    else
        nothing  # Also covers `NONE` and `GREATER_THAN`.
    end
    if existing_set !== nothing
        throw(MOI.UpperBoundAlreadySet{existing_set, new_set}(variable))
    end
end

function MOI.add_constraint(
    model::Optimizer, f::MOI.SingleVariable, s::S
) where {S <: SCALAR_SETS}
    info = _info(model, f.variable)
    if S <: MOI.LessThan{Float64}
        _throw_if_existing_upper(info.bound, info.type, S, f.variable)
        info.bound = info.bound == GREATER_THAN ? LESS_AND_GREATER_THAN : LESS_THAN
    elseif S <: MOI.GreaterThan{Float64}
        _throw_if_existing_lower(info.bound, info.type, S, f.variable)
        info.bound = info.bound == LESS_THAN ? LESS_AND_GREATER_THAN : GREATER_THAN
    elseif S <: MOI.EqualTo{Float64}
        _throw_if_existing_lower(info.bound, info.type, S, f.variable)
        _throw_if_existing_upper(info.bound, info.type, S, f.variable)
        info.bound = EQUAL_TO
    else
        @assert S <: MOI.Interval{Float64}
        _throw_if_existing_lower(info.bound, info.type, S, f.variable)
        _throw_if_existing_upper(info.bound, info.type, S, f.variable)
        info.bound = INTERVAL
    end
    index = MOI.ConstraintIndex{MOI.SingleVariable, typeof(s)}(f.variable.value)
    MOI.set(model, MOI.ConstraintSet(), index, s)
    return index
end

function MOI.add_constraints(
    model::Optimizer, f::Vector{MOI.SingleVariable}, s::Vector{S}
) where {S <: SCALAR_SETS}
    for fi in f
        info = _info(model, fi.variable)
        if S <: MOI.LessThan{Float64}
            _throw_if_existing_upper(info.bound, info.type, S, fi.variable)
            info.bound = info.bound == GREATER_THAN ? LESS_AND_GREATER_THAN : LESS_THAN
        elseif S <: MOI.GreaterThan{Float64}
            _throw_if_existing_lower(info.bound, info.type, S, fi.variable)
            info.bound = info.bound == LESS_THAN ? LESS_AND_GREATER_THAN : GREATER_THAN
        elseif S <: MOI.EqualTo{Float64}
            _throw_if_existing_lower(info.bound, info.type, S, fi.variable)
            _throw_if_existing_upper(info.bound, info.type, S, fi.variable)
            info.bound = EQUAL_TO
        else
            @assert S <: MOI.Interval{Float64}
            _throw_if_existing_lower(info.bound, info.type, S, fi.variable)
            _throw_if_existing_upper(info.bound, info.type, S, fi.variable)
            info.bound = INTERVAL
        end
    end
    indices = [
        MOI.ConstraintIndex{MOI.SingleVariable, eltype(s)}(fi.variable.value)
        for fi in f
    ]
    _set_bounds(model, indices, s)
    return indices
end

function MOI.delete(
    model::Optimizer,
    c::MOI.ConstraintIndex{MOI.SingleVariable, MOI.LessThan{Float64}}
)
    MOI.throw_if_not_valid(model, c)
    info = _info(model, c)

    set_ub!(model.inner, [info.column], [Inf])

    if info.bound == LESS_AND_GREATER_THAN
        info.bound = GREATER_THAN
    else
        info.bound = NONE
    end
    info.lessthan_name = ""
    return
end

"""
    _set_variable_lower_bound(model, info, value)

This function is used to indirectly set the lower bound of a variable.

We need to do it this way to account for potential lower bounds of 0.0 added by
VectorOfVariables-in-SecondOrderCone constraints.

See also `_get_variable_lower_bound`.
"""
function _set_variable_lower_bound(model, info, value)
    if info.num_soc_constraints == 0
        # No SOC constraints, set directly.
        @assert isnan(info.lower_bound_if_soc)
        set_lb!(model.inner, [info.column], [value])
    elseif value >= 0.0
        # Regardless of whether there are SOC constraints, this is a valid bound
        # for the SOC constraint and should over-ride any previous bounds.
        info.lower_bound_if_soc = NaN
        set_lb!(model.inner, [info.column], [value])

    elseif isnan(info.lower_bound_if_soc)
        # Previously, we had a +ve lower bound (i.e., it was set in the case
        # above). Now we're setting this with a -ve one, but there are still
        # some SOC constraints, so we cache `value` and set the variable lower
        # bound to `0.0`.
        @assert value < 0.0
        set_lb!(model.inner, [info.column], [0.0])

        info.lower_bound_if_soc = value
    else
        # Previously, we had a -ve lower bound. We're setting this with another
        # -ve one, but there are still some SOC constraints.
        @assert info.lower_bound_if_soc < 0.0
        info.lower_bound_if_soc = value
    end
end

"""
    _get_variable_lower_bound(model, info)

Get the current variable lower bound, ignoring a potential bound of `0.0` set
by a second order cone constraint.

See also `_set_variable_lower_bound`.
"""
function _get_variable_lower_bound(model, info)
    if !isnan(info.lower_bound_if_soc)
        # There is a value stored. That means that we must have set a value that
        # was < 0.
        @assert info.lower_bound_if_soc < 0.0
        return info.lower_bound_if_soc
    end
    return get_lb!(model.inner, [info.column])
end

function MOI.delete(
    model::Optimizer,
    c::MOI.ConstraintIndex{MOI.SingleVariable, MOI.GreaterThan{Float64}}
)
    MOI.throw_if_not_valid(model, c)
    info = _info(model, c)
    _set_variable_lower_bound(model, info, -Inf)
    if info.bound == LESS_AND_GREATER_THAN
        info.bound = LESS_THAN
    else
        info.bound = NONE
    end
    info.greaterthan_interval_or_equalto_name = ""
    return
end

function MOI.delete(
    model::Optimizer,
    c::MOI.ConstraintIndex{MOI.SingleVariable, MOI.Interval{Float64}}
)
    MOI.throw_if_not_valid(model, c)
    info = _info(model, c)
    _set_variable_lower_bound(model, info, -Inf)
    set_ub!(model.inner, [info.column], [Inf])
    info.bound = NONE
    info.greaterthan_interval_or_equalto_name = ""
    return
end

function MOI.delete(
    model::Optimizer,
    c::MOI.ConstraintIndex{MOI.SingleVariable, MOI.EqualTo{Float64}}
)
    MOI.throw_if_not_valid(model, c)
    info = _info(model, c)
    _set_variable_lower_bound(model, info, -Inf)
    set_ub!(model.inner, [info.column], [Inf])
    info.bound = NONE
    info.greaterthan_interval_or_equalto_name = ""
    return
end

function MOI.get(
    model::Optimizer, ::MOI.ConstraintSet,
    c::MOI.ConstraintIndex{MOI.SingleVariable, MOI.GreaterThan{Float64}}
)
    MOI.throw_if_not_valid(model, c)
    lower = _get_variable_lower_bound(model, _info(model, c))
    return MOI.GreaterThan(lower)
end

function MOI.get(
    model::Optimizer, ::MOI.ConstraintSet,
    c::MOI.ConstraintIndex{MOI.SingleVariable, MOI.LessThan{Float64}}
)
    MOI.throw_if_not_valid(model, c)
    upper = get_ub!(model.inner, [_info(model, c).column])
    return MOI.LessThan(upper)
end

function MOI.get(
    model::Optimizer, ::MOI.ConstraintSet,
    c::MOI.ConstraintIndex{MOI.SingleVariable, MOI.EqualTo{Float64}}
)
    MOI.throw_if_not_valid(model, c)
    lower = get_lb!(model.inner, [_info(model, c).column])
    return MOI.EqualTo(lower)
end

function MOI.get(
    model::Optimizer, ::MOI.ConstraintSet,
    c::MOI.ConstraintIndex{MOI.SingleVariable, MOI.Interval{Float64}}
)
    MOI.throw_if_not_valid(model, c)
    info = _info(model, c)
    lower = _get_variable_lower_bound(model, _info(model, c))
    upper = get_ub!(model.inner, [info.column])
    return MOI.Interval(lower, upper)
end

function _set_bounds(
    model::Optimizer,
    indices::Vector{MOI.ConstraintIndex{MOI.SingleVariable, S}},
    sets::Vector{S}
) where {S}
    lower_columns, lower_values = Int[], Float64[]
    upper_columns, upper_values = Int[], Float64[]
    for (c, s) in zip(indices, sets)
        lower, upper = _bounds(s)
        info = _info(model, c)
        if lower !== nothing
            push!(lower_columns, info.column)
            push!(lower_values, lower)
        end
        if upper !== nothing
            push!(upper_columns, info.column)
            push!(upper_values, upper)
        end
    end
    if length(lower_columns) > 0
        set_lb!(model.inner, lower_columns, lower_values)
    end
    if length(upper_columns) > 0
        set_ub!(model.inner, upper_columns, upper_values)
    end
end

function MOI.set(
    model::Optimizer, ::MOI.ConstraintSet,
    c::MOI.ConstraintIndex{MOI.SingleVariable, S}, s::S
) where {S<:SCALAR_SETS}
    MOI.throw_if_not_valid(model, c)
    lower, upper = _bounds(s)
    info = _info(model, c)
    if lower !== nothing
        _set_variable_lower_bound(model, info, lower)
    end
    if upper !== nothing
        set_ub!(model.inner, [info.column], [upper])
    end
    return
end

function MOI.add_constraint(
    model::Optimizer, f::MOI.SingleVariable, ::MOI.ZeroOne
)
    info = _info(model, f.variable)
    chgcoltype!(model.inner, [info.column], XPRS_BINARY)
    info.type = BINARY
    return MOI.ConstraintIndex{MOI.SingleVariable, MOI.ZeroOne}(f.variable.value)
end

function MOI.delete(
    model::Optimizer, c::MOI.ConstraintIndex{MOI.SingleVariable, MOI.ZeroOne}
)
    MOI.throw_if_not_valid(model, c)
    info = _info(model, c)
    chgcoltype!(model.inner, [info.column], XPRS_CONTINUOUS)
    info.type = CONTINUOUS
    info.type_constraint_name = ""
    return
end

function MOI.get(
    model::Optimizer, ::MOI.ConstraintSet,
    c::MOI.ConstraintIndex{MOI.SingleVariable, MOI.ZeroOne}
)
    MOI.throw_if_not_valid(model, c)
    return MOI.ZeroOne()
end

function MOI.add_constraint(
    model::Optimizer, f::MOI.SingleVariable, ::MOI.Integer
)
    info = _info(model, f.variable)
    chgcoltype!(model.inner, [info.column], XPRS_INTEGER)
    info.type = INTEGER
    return MOI.ConstraintIndex{MOI.SingleVariable, MOI.Integer}(f.variable.value)
end

function MOI.delete(
    model::Optimizer, c::MOI.ConstraintIndex{MOI.SingleVariable, MOI.Integer}
)
    MOI.throw_if_not_valid(model, c)
    info = _info(model, c)
    chgcoltype!(model.inner, [info.column], XPRS_CONTINUOUS)
    info.type = CONTINUOUS
    info.type_constraint_name = ""
    return
end

function MOI.get(
    model::Optimizer, ::MOI.ConstraintSet,
    c::MOI.ConstraintIndex{MOI.SingleVariable, MOI.Integer}
)
    MOI.throw_if_not_valid(model, c)
    return MOI.Integer()
end

#=
Semicontinuous and Semiinteger not originally supported in Xpress. Can be added later

function MOI.add_constraint(
    model::Optimizer, f::MOI.SingleVariable, s::MOI.Semicontinuous{Float64}
)
    info = _info(model, f.variable)
    _throw_if_existing_lower(info.bound, info.type, typeof(s), f.variable)
    _throw_if_existing_upper(info.bound, info.type, typeof(s), f.variable)
    set_charattrelement!(model.inner, "VType", info.column, Char('S'))
    _set_variable_lower_bound(model, info, s.lower)
    set_dblattrelement!(model.inner, "UB", info.column, s.upper)
    info.type = SEMICONTINUOUS
    return MOI.ConstraintIndex{MOI.SingleVariable, MOI.Semicontinuous{Float64}}(f.variable.value)
end

function MOI.delete(
    model::Optimizer,
    c::MOI.ConstraintIndex{MOI.SingleVariable, MOI.Semicontinuous{Float64}}
)
    MOI.throw_if_not_valid(model, c)
    info = _info(model, c)
    add_cvars!(model.inner, info.column)
    _set_variable_lower_bound(model, info, -Inf)
    set_ub!(model.inner, [info.column], [Inf])
    info.type = CONTINUOUS
    info.type_constraint_name = ""
    return
end

function MOI.get(
    model::Optimizer, ::MOI.ConstraintSet,
    c::MOI.ConstraintIndex{MOI.SingleVariable, MOI.Semicontinuous{Float64}}
)
    MOI.throw_if_not_valid(model, c)
    info = _info(model, c)
    lower = _get_variable_lower_bound(model, info)
    upper = get_dblattrelement(model.inner, "UB", info.column)
    return MOI.Semicontinuous(lower, upper)
end

function MOI.add_constraint(
    model::Optimizer, f::MOI.SingleVariable, s::MOI.Semiinteger{Float64}
)
    info = _info(model, f.variable)
    _throw_if_existing_lower(info.bound, info.type, typeof(s), f.variable)
    _throw_if_existing_upper(info.bound, info.type, typeof(s), f.variable)
    set_charattrelement!(model.inner, "VType", info.column, Char('N'))
    _set_variable_lower_bound(model, info, s.lower)
    set_dblattrelement!(model.inner, "UB", info.column, s.upper)
    info.type = SEMIINTEGER
    return MOI.ConstraintIndex{MOI.SingleVariable, MOI.Semiinteger{Float64}}(f.variable.value)
end

function MOI.delete(
    model::Optimizer,
    c::MOI.ConstraintIndex{MOI.SingleVariable, MOI.Semiinteger{Float64}}
)
    MOI.throw_if_not_valid(model, c)
    info = _info(model, c)
    add_cvars!(model.inner, info.column)
    _set_variable_lower_bound(model, info, -Inf)
    set_ub!(model.inner, [info.column], [Inf])
    info.type = CONTINUOUS
    info.type_constraint_name = ""
    return
end

function MOI.get(
    model::Optimizer, ::MOI.ConstraintSet,
    c::MOI.ConstraintIndex{MOI.SingleVariable, MOI.Semiinteger{Float64}}
)
    MOI.throw_if_not_valid(model, c)
    info = _info(model, c)
    lower = _get_variable_lower_bound(model, info)
    upper = get_dblattrelement(model.inner, "UB", info.column)
    return MOI.Semiinteger(lower, upper)
end
=#

function MOI.get(
    model::Optimizer, ::MOI.ConstraintName,
    c::MOI.ConstraintIndex{MOI.SingleVariable, S}
) where {S}
    MOI.throw_if_not_valid(model, c)
    info = _info(model, c)
    if S <: MOI.LessThan
        return info.lessthan_name
    elseif S <: Union{MOI.GreaterThan, MOI.Interval, MOI.EqualTo}
        return info.greaterthan_interval_or_equalto_name
    else
        @assert S <: Union{MOI.ZeroOne, MOI.Integer, MOI.Semiinteger, MOI.Semicontinuous}
        return info.type_constraint_name
    end
end

function MOI.set(
    model::Optimizer, ::MOI.ConstraintName,
    c::MOI.ConstraintIndex{MOI.SingleVariable, S}, name::String
) where {S}
    MOI.throw_if_not_valid(model, c)
    info = _info(model, c)
    old_name = ""
    if S <: MOI.LessThan
        old_name = info.lessthan_name
        info.lessthan_name = name
    elseif S <: Union{MOI.GreaterThan, MOI.Interval, MOI.EqualTo}
        old_name = info.greaterthan_interval_or_equalto_name
        info.greaterthan_interval_or_equalto_name = name
    else
        @assert S <: Union{MOI.ZeroOne, MOI.Integer, MOI.Semiinteger, MOI.Semicontinuous}
        info.type_constraint_name
        info.type_constraint_name = name
    end
    if model.name_to_constraint_index !== nothing
        delete!(model.name_to_constraint_index, old_name)
    end
    if model.name_to_constraint_index === nothing || isempty(name)
        return
    end
    if haskey(model.name_to_constraint_index, name)
        model.name_to_constraint_index = nothing
    else
        model.name_to_constraint_index[name] = c
    end
    return
end

###
### ScalarAffineFunction-in-Set
###

function _info(
    model::Optimizer,
    key::MOI.ConstraintIndex{MOI.ScalarAffineFunction{Float64}, <:Any}
)
    if haskey(model.affine_constraint_info, key.value)
        return model.affine_constraint_info[key.value]
    end
    throw(MOI.InvalidIndex(key))
end

function MOI.is_valid(
    model::Optimizer,
    c::MOI.ConstraintIndex{MOI.ScalarAffineFunction{Float64}, S}
) where {S}
    info = get(model.affine_constraint_info, c.value, nothing)
    if info === nothing
        return false
    else
        return typeof(info.set) == S
    end
end

function MOI.add_constraint(
    model::Optimizer, f::MOI.ScalarAffineFunction{Float64},
    s::Union{MOI.GreaterThan{Float64}, MOI.LessThan{Float64}, MOI.EqualTo{Float64}}
)
    if !iszero(f.constant)
        throw(MOI.ScalarFunctionConstantNotZero{Float64, typeof(f), typeof(s)}(f.constant))
    end
    model.last_constraint_index += 1
    model.affine_constraint_info[model.last_constraint_index] =
        ConstraintInfo(length(model.affine_constraint_info) + 1, s)

    indices, coefficients = _indices_and_coefficients(model, f)
    sense, rhs = _sense_and_rhs(s)
    add_constr!(model.inner, indices, coefficients, sense, rhs)
    return MOI.ConstraintIndex{typeof(f), typeof(s)}(model.last_constraint_index)
end

function MOI.add_constraints(
    model::Optimizer, f::Vector{MOI.ScalarAffineFunction{Float64}},
    s::Vector{<:Union{MOI.GreaterThan{Float64}, MOI.LessThan{Float64}, MOI.EqualTo{Float64}}}
)
    if length(f) != length(s)
        error("Number of functions does not equal number of sets.")
    end
    canonicalized_functions = MOI.Utilities.canonical.(f)
    # First pass: compute number of non-zeros to allocate space.
    nnz = 0
    for fi in canonicalized_functions
        if !iszero(fi.constant)
            throw(MOI.ScalarFunctionConstantNotZero{Float64, eltype(f), eltype(s)}(fi.constant))
        end
        nnz += length(fi.terms)
    end
    # Initialize storage
    indices = Vector{MOI.ConstraintIndex{eltype(f), eltype(s)}}(undef, length(f))
    row_starts = Vector{Int}(undef, length(f) + 1)
    row_starts[1] = 1
    columns = Vector{Int}(undef, nnz)
    coefficients = Vector{Float64}(undef, nnz)
    senses = Vector{Cchar}(undef, length(f))
    rhss = Vector{Float64}(undef, length(f))
    # Second pass: loop through, passing views to _indices_and_coefficients.
    for (i, (fi, si)) in enumerate(zip(canonicalized_functions, s))
        senses[i], rhss[i] = _sense_and_rhs(si)
        row_starts[i + 1] = row_starts[i] + length(fi.terms)
        _indices_and_coefficients(
            view(columns, row_starts[i]:row_starts[i + 1] - 1),
            view(coefficients, row_starts[i]:row_starts[i + 1] - 1),
            model, fi
        )
        model.last_constraint_index += 1
        indices[i] = MOI.ConstraintIndex{eltype(f), eltype(s)}(model.last_constraint_index)
        model.affine_constraint_info[model.last_constraint_index] =
            ConstraintInfo(length(model.affine_constraint_info) + 1, si)
    end
    pop!(row_starts)  # Gurobi doesn't need the final row start.
    add_constrs!(model.inner, row_starts, columns, coefficients, senses, rhss)
    return indices
end

function MOI.delete(
    model::Optimizer,
    c::MOI.ConstraintIndex{MOI.ScalarAffineFunction{Float64}, <:Any}
)
    row = _info(model, c).row
    del_constrs!(model.inner, row)
    for (key, info) in model.affine_constraint_info
        if info.row > row
            info.row -= 1
        end
    end
    model.name_to_constraint_index = nothing
    delete!(model.affine_constraint_info, c.value)
    return
end

function MOI.get(
    model::Optimizer, ::MOI.ConstraintSet,
    c::MOI.ConstraintIndex{MOI.ScalarAffineFunction{Float64}, S}
) where {S}
    row = _info(model, c).row
    rhs = get_rhs(model.inner, row, row)[1]
    return S(rhs)
end

function MOI.set(
    model::Optimizer, ::MOI.ConstraintSet,
    c::MOI.ConstraintIndex{MOI.ScalarAffineFunction{Float64}, S}, s::S
) where {S}
    set_rhs!(model.inner, _info(model, c).row, MOI.constant(s))
    return
end

function MOI.get(
    model::Optimizer, ::MOI.ConstraintFunction,
    c::MOI.ConstraintIndex{MOI.ScalarAffineFunction{Float64}, S}
) where {S}
    row = _info(model, c).row
    sparse_a = SparseArrays.sparse(get_rows(model.inner, row, row)')
    terms = MOI.ScalarAffineTerm{Float64}[]
    for (col, val) in zip(sparse_a.rowval, sparse_a.nzval)
        iszero(val) && continue
        push!(
            terms,
            MOI.ScalarAffineTerm(
                val,
                model.variable_info[CleverDicts.LinearIndex(col)].index
            )
        )
    end
    return MOI.ScalarAffineFunction(terms, 0.0)
end

function MOI.get(
    model::Optimizer, ::MOI.ConstraintName,
    c::MOI.ConstraintIndex{MOI.ScalarAffineFunction{Float64}, <:Any}
)
    return _info(model, c).name
end

function MOI.set(
    model::Optimizer, ::MOI.ConstraintName,
    c::MOI.ConstraintIndex{MOI.ScalarAffineFunction{Float64}, <:Any},
    name::String
)
    info = _info(model, c)
    if !isempty(info.name) && model.name_to_constraint_index !== nothing
        delete!(model.name_to_constraint_index, info.name)
    end
    info.name = name
    if !isempty(name)
        addrowname(model.inner, name, info.row)
    end
    if model.name_to_constraint_index === nothing || isempty(name)
        return
    end
    if haskey(model.name_to_constraint_index, name)
        model.name_to_constraint_index = nothing
    else
        model.name_to_constraint_index[name] = c
    end
    return
end

function MOI.get(model::Optimizer, ::Type{MOI.ConstraintIndex}, name::String)
    if model.name_to_constraint_index === nothing
        _rebuild_name_to_constraint_index(model)
    end
    return get(model.name_to_constraint_index, name, nothing)
end

function MOI.get(
    model::Optimizer, C::Type{MOI.ConstraintIndex{F, S}}, name::String
) where {F, S}
    index = MOI.get(model, MOI.ConstraintIndex, name)
    if typeof(index) == C
        return index::MOI.ConstraintIndex{F, S}
    end
    return nothing
end

function _rebuild_name_to_constraint_index(model::Optimizer)
    model.name_to_constraint_index = Dict{String, Int}()
    _rebuild_name_to_constraint_index_util(
        model, model.affine_constraint_info, MOI.ScalarAffineFunction{Float64}
    )
    _rebuild_name_to_constraint_index_util(
        model, model.quadratic_constraint_info, MOI.ScalarQuadraticFunction{Float64}
    )
    _rebuild_name_to_constraint_index_util(
        model, model.sos_constraint_info, MOI.VectorOfVariables
    )
    _rebuild_name_to_constraint_index_variables(model)
    return
end

function _rebuild_name_to_constraint_index_util(model::Optimizer, dict, F)
    for (index, info) in dict
        info.name == "" && continue
        if haskey(model.name_to_constraint_index, info.name)
            model.name_to_constraint_index = nothing
            error("Duplicate constraint name detected: $(info.name)")
        end
        model.name_to_constraint_index[info.name] =
            MOI.ConstraintIndex{F, typeof(info.set)}(index)
    end
    return
end

function _rebuild_name_to_constraint_index_variables(model::Optimizer)
    for (key, info) in model.variable_info
        for S in (
            MOI.LessThan{Float64}, MOI.GreaterThan{Float64},
            MOI.EqualTo{Float64}, MOI.Interval{Float64}, MOI.ZeroOne,
            MOI.Integer, MOI.Semicontinuous{Float64}, MOI.Semiinteger{Float64}
        )
            constraint_name = ""
            if info.bound in _bound_enums(S)
                constraint_name = S == MOI.LessThan{Float64} ?
                    info.lessthan_name : info.greaterthan_interval_or_equalto_name
            elseif info.type in _type_enums(S)
                constraint_name = info.type_constraint_name
            end
            constraint_name == "" && continue
            if haskey(model.name_to_constraint_index, constraint_name)
                model.name_to_constraint_index = nothing
                error("Duplicate constraint name detected: ", constraint_name)
            end
            model.name_to_constraint_index[constraint_name] =
                MOI.ConstraintIndex{MOI.SingleVariable, S}(key.value)
        end
    end
    return
end

# Implement Quadratic Later

###
### ScalarQuadraticFunction-in-SCALAR_SET
###
#=
function _info(
    model::Optimizer,
    c::MOI.ConstraintIndex{MOI.ScalarQuadraticFunction{Float64}, S}
) where {S}
    if haskey(model.quadratic_constraint_info, c.value)
        return model.quadratic_constraint_info[c.value]
    end
    throw(MOI.InvalidIndex(c))
end

function MOI.add_constraint(
    model::Optimizer,
    f::MOI.ScalarQuadraticFunction{Float64}, s::SCALAR_SETS
)
    if !iszero(f.constant)
        throw(MOI.ScalarFunctionConstantNotZero{Float64, typeof(f), typeof(s)}(f.constant))
    end
    indices, coefficients, I, J, V = _indices_and_coefficients(model, f)
    sense, rhs = _sense_and_rhs(s)
    add_qconstr!(model.inner, indices, coefficients, I, J, V, sense, rhs)
    model.last_constraint_index += 1
    model.quadratic_constraint_info[model.last_constraint_index] =
        ConstraintInfo(length(model.quadratic_constraint_info) + 1, s)
    return MOI.ConstraintIndex{MOI.ScalarQuadraticFunction{Float64}, typeof(s)}(model.last_constraint_index)
end

function MOI.is_valid(
    model::Optimizer,
    c::MOI.ConstraintIndex{MOI.ScalarQuadraticFunction{Float64}, S}
) where {S}
    info = get(model.quadratic_constraint_info, c.value, nothing)
    return info !== nothing && typeof(info.set) == S
end

function MOI.delete(
    model::Optimizer,
    c::MOI.ConstraintIndex{MOI.ScalarQuadraticFunction{Float64}, S}
) where {S}
    info = _info(model, c)
    delqconstrs!(model.inner, [info.row])
    for (key, info_2) in model.quadratic_constraint_info
        if info_2.row > info.row
            info_2.row -= 1
        end
    end
    model.name_to_constraint_index = nothing
    delete!(model.quadratic_constraint_info, c.value)
    return
end

function MOI.get(
    model::Optimizer, ::MOI.ConstraintSet,
    c::MOI.ConstraintIndex{MOI.ScalarQuadraticFunction{Float64}, S}
) where {S}
    rhs = get_dblattrelement(model.inner, "QCRHS", _info(model, c).row)
    return S(rhs)
end

function MOI.get(
    model::Optimizer, ::MOI.ConstraintFunction,
    c::MOI.ConstraintIndex{MOI.ScalarQuadraticFunction{Float64}, S}
) where {S}
    affine_cols, affine_coefficients, I, J, V = getqconstr(model.inner, _info(model, c).row)
    affine_terms = MOI.ScalarAffineTerm{Float64}[]
    for (col, coef) in zip(affine_cols, affine_coefficients)
        iszero(coef) && continue
        push!(
            affine_terms,
            MOI.ScalarAffineTerm(
                coef,
                model.variable_info[CleverDicts.LinearIndex(col + 1)].index
                )
        )
    end
    quadratic_terms = MOI.ScalarQuadraticTerm{Float64}[]
    for (i, j, coef) in zip(I, J, V)
        new_coef = i == j ? 2coef : coef
        push!(
            quadratic_terms,
            MOI.ScalarQuadraticTerm(
                new_coef,
                model.variable_info[CleverDicts.LinearIndex(i + 1)].index,
                model.variable_info[CleverDicts.LinearIndex(j + 1)].index
            )
        )
    end
    return MOI.ScalarQuadraticFunction(affine_terms, quadratic_terms, 0.0)
end

function MOI.get(
    model::Optimizer, ::MOI.ConstraintName,
    c::MOI.ConstraintIndex{MOI.ScalarQuadraticFunction{Float64}, S}
) where {S}
    return _info(model, c).name
end

function MOI.set(
    model::Optimizer, ::MOI.ConstraintName,
    c::MOI.ConstraintIndex{MOI.ScalarQuadraticFunction{Float64}, S},
    name::String
) where {S}
    info = _info(model, c)
    if !isempty(info.name) && model.name_to_constraint_index !== nothing
        delete!(model.name_to_constraint_index, info.name)
    end
    set_strattrelement!(model.inner, "QCName", info.row, name)
    info.name = name
    if model.name_to_constraint_index === nothing || isempty(name)
        return
    end
    if haskey(model.name_to_constraint_index, name)
        model.name_to_constraint_index = nothing
    else
        model.name_to_constraint_index[c] = name
    end
    return
end
=#
###
### VectorOfVariables-in-SOS{I|II}
###

const SOS = Union{MOI.SOS1{Float64}, MOI.SOS2{Float64}}

function _info(
    model::Optimizer,
    key::MOI.ConstraintIndex{MOI.VectorOfVariables, <:SOS}
)
    if haskey(model.sos_constraint_info, key.value)
        return model.sos_constraint_info[key.value]
    end
    throw(MOI.InvalidIndex(key))
end

_sos_type(::MOI.SOS1) = :SOS1
_sos_type(::MOI.SOS2) = :SOS2

function MOI.is_valid(
    model::Optimizer,
    c::MOI.ConstraintIndex{MOI.VectorOfVariables, S}
) where {S}
    info = get(model.sos_constraint_info, c.value, nothing)
    if info === nothing
        return false
    else
        return typeof(info.set) == S
    end
end

function MOI.add_constraint(
    model::Optimizer, f::MOI.VectorOfVariables, s::SOS
)
    columns = Int[_info(model, v).column for v in f.variables]
    add_sos!(model.inner, _sos_type(s), columns, s.weights)
    model.last_constraint_index += 1
    index = MOI.ConstraintIndex{MOI.VectorOfVariables, typeof(s)}(model.last_constraint_index)
    model.sos_constraint_info[index.value] = ConstraintInfo(
        length(model.sos_constraint_info) + 1, s
    )
    return index
end

function MOI.delete(
    model::Optimizer, c::MOI.ConstraintIndex{MOI.VectorOfVariables, <:SOS}
)
    row = _info(model, c).row
    del_sos!(model.inner, [Cint(row)])
    for (key, info) in model.sos_constraint_info
        if info.row > row
            info.row -= 1
        end
    end
    delete!(model.sos_constraint_info, c.value)
    return
end

function MOI.get(
    model::Optimizer, ::MOI.ConstraintName,
    c::MOI.ConstraintIndex{MOI.VectorOfVariables, <:Any}
)
    return _info(model, c).name
end

function MOI.set(
    model::Optimizer, ::MOI.ConstraintName,
    c::MOI.ConstraintIndex{MOI.VectorOfVariables, <:Any}, name::String
)
    info = _info(model, c)
    if !isempty(info.name) && model.name_to_constraint_index !== nothing
        delete!(model.name_to_constraint_index, info.name)
    end
    info.name = name
    if model.name_to_constraint_index === nothing || isempty(name)
        return
    end
    if haskey(model.name_to_constraint_index, name)
        model.name_to_constraint_index = nothing
    else
        model.name_to_constraint_index[name] = c
    end
    return
end

function MOI.get(
    model::Optimizer, ::MOI.ConstraintSet,
    c::MOI.ConstraintIndex{MOI.VectorOfVariables, S}
) where {S <: SOS}
    full_matrix, _ = get_sos_matrix(model.inner)
    line = full_matrix[_info(model, c).row,:] #sparse vec
    return S(line.nzval)
end


function MOI.get(
    model::Optimizer, ::MOI.ConstraintFunction,
    c::MOI.ConstraintIndex{MOI.VectorOfVariables, S}
) where {S <: SOS}
    full_matrix, _ = get_sos_matrix(model.inner)
    line = full_matrix[_info(model, c).row,:] #sparse vec
    cols = line.nzind
    return MOI.VectorOfVariables(
        [model.variable_info[CleverDicts.LinearIndex(i)].index for i in cols]
    )
end

###
### Optimize methods.
###

function MOI.optimize!(model::Optimizer)
    optimize(model.inner)
    model.has_infeasibility_cert =
    MOI.get(model, MOI.DualStatus()) == MOI.INFEASIBILITY_CERTIFICATE
    model.has_unbounded_ray =
        MOI.get(model, MOI.PrimalStatus()) == MOI.INFEASIBILITY_CERTIFICATE
    return
end
##
# Update these for Xpress Using LPSTATUS, https://www.fico.com/fico-xpress-optimization/docs/latest/solver/optimizer/HTML/LPSTATUS.html
# MIPSTATUS https://www.fico.com/fico-xpress-optimization/docs/latest/solver/optimizer/HTML/MIPSTATUS.html
# and STOP https://www.fico.com/fico-xpress-optimization/docs/latest/solver/optimizer/HTML/STOPSTATUS.html
const RAW_STATUS_STRINGS = [
    (MOI.OPTIMIZE_NOT_CALLED, "Model is loaded, but no solution information is available."),
    (MOI.OPTIMAL, "Model was solved to optimality (subject to tolerances), and an optimal solution is available."),
    (MOI.INFEASIBLE, "Model was proven to be infeasible."),
    (MOI.INFEASIBLE_OR_UNBOUNDED, "Model was proven to be either infeasible or unbounded. To obtain a more definitive conclusion, set the DualReductions parameter to 0 and reoptimize."),
    (MOI.DUAL_INFEASIBLE, "Model was proven to be unbounded. Important note: an unbounded status indicates the presence of an unbounded ray that allows the objective to improve without limit. It says nothing about whether the model has a feasible solution. If you require information on feasibility, you should set the objective to zero and reoptimize."),
    (MOI.OBJECTIVE_LIMIT, "Optimal objective for model was proven to be worse than the value specified in the Cutoff parameter. No solution information is available."),
    (MOI.ITERATION_LIMIT, "Optimization terminated because the total number of simplex iterations performed exceeded the value specified in the IterationLimit parameter, or because the total number of barrier iterations exceeded the value specified in the BarIterLimit parameter."),
    (MOI.NODE_LIMIT, "Optimization terminated because the total number of branch-and-cut nodes explored exceeded the value specified in the NodeLimit parameter."),
    (MOI.TIME_LIMIT, "Optimization terminated because the time expended exceeded the value specified in the TimeLimit parameter."),
    (MOI.SOLUTION_LIMIT, "Optimization terminated because the number of solutions found reached the value specified in the SolutionLimit parameter."),
    (MOI.INTERRUPTED, "Optimization was terminated by the user."),
    (MOI.NUMERICAL_ERROR, "Optimization was terminated due to unrecoverable numerical difficulties."),
    (MOI.OTHER_LIMIT, "Unable to satisfy optimality tolerances; a sub-optimal solution is available."),
    (MOI.OTHER_ERROR, "An asynchronous optimization call was made, but the associated optimization run is not yet complete."),
    (MOI.OBJECTIVE_LIMIT, "User specified an objective limit (a bound on either the best objective or the best bound), and that limit has been reached.")
]

function MOI.get(model::Optimizer, ::MOI.RawStatusString)
    status_code = -1 #get_status_code(model.inner)
    if 1 <= status_code <= length(RAW_STATUS_STRINGS)
        return RAW_STATUS_STRINGS[status_code][2]
    end
    return MOI.OTHER_ERROR
end

function _get_stopstatus(model::Model)
    ss = get_stopstatus(model)
    if ss == StopTimeLimit
        return MOI.TIME_LIMIT
    elseif ss == StopControlC
        return MOI.INTERRUPTED
    elseif ss == StopNodeLimit
        # should not be here
        @warn("should not be here")
        return MOI.NODE_LIMIT
    elseif ss == StopIterLimit
        return MOI.ITERATION_LIMIT
    elseif ss == StopMIPGap
        return MOI.OBJECTIVE_LIMIT
    elseif ss == StopSolLimit
        return MOI.SOLUTION_LIMIT
    elseif ss == StopUser
        return MOI.INTERRUPTED
    end
    return MOI.OTHER_ERROR
end

function MOI.get(model::Optimizer, ::MOI.TerminationStatus)
    # First determine the stop status.
    stat_lp = get_lp_status2(model.inner)
    if is_mip(model.inner)
        stat_mip = get_mip_status2(model.inner)
        if stat_mip == MIP_NotLoaded
            return MOI.OTHER_ERROR
        elseif stat_mip == MIP_LPNotOptimal
            # MIP search incomplete but there is no linear sol
            return MOI.OTHER_ERROR
        elseif stat_mip == MIP_NoSolFound
            # MIP search incomplete but there is no integer sol
            other = _get_stopstatus(model.inner)
            if other == MOI.OTHER_ERROR
                return MOI.SLOW_PROGRESS#OtherLimit
            else
                return other
            end

        elseif stat_mip == MIP_Solution
            # MIP search incomplete but there is a solution
            other = _get_stopstatus(model.inner)
            if other == MOI.OTHER_ERROR
                return MOI.OTHER_LIMIT
            else
                return other
            end

        elseif stat_mip == MIP_Infeasible
            return MOI.INFEASIBLE
        elseif stat_mip == MIP_Optimal
            return MOI.OPTIMAL
        elseif stat_mip == MIP_Unbounded
            return MOI.DUAL_INFEASIBLE
        end
        return MOI.OTHER_ERROR
    else
        if stat_lp == LP_Unstarted
            return MOI.OTHER_ERROR
        elseif stat_lp == LP_Optimal
            return MOI.OPTIMAL
        elseif stat_lp == LP_Infeasible
            return MOI.INFEASIBLE
        elseif stat_lp == LP_CutOff
            return MOI.OBJECTIVE_LIMIT
        elseif stat_lp == LP_Unfinished
            return _get_stopstatus(model.inner)
        elseif stat_lp == LP_Unbounded
            return MOI.DUAL_INFEASIBLE
        elseif stat_lp == LP_CutOffInDual
            return MOI.OBJECTIVE_LIMIT
        elseif stat_lp == LP_Unsolved
            return MOI.OTHER_ERROR
        elseif stat_lp == LP_NonConvex
            return MOI.INVALID_MODEL
        end
        return MOI.OTHER_ERROR
    end
end

function MOI.get(model::Optimizer, ::MOI.PrimalStatus)
    if is_mip(model.inner)
        stat_mip = get_mip_status2(model.inner)
        if stat_mip in [MIP_Solution, MIP_Optimal]
            return MOI.FEASIBLE_POINT
        elseif stat_mip == MIP_Unbounded && hasprimalray(model.inner)
            return MOI.INFEASIBILITY_CERTIFICATE
        elseif stat_mip in [MIP_LPOptimal, MIP_NoSolFound]
            return MOI.INFEASIBLE_POINT
        end
        return MOI.NO_SOLUTION
    else
        stat_lp = get_lp_status2(model.inner)
        if stat_lp == LP_Optimal
            return MOI.FEASIBLE_POINT
        elseif stat_lp == LP_Unbounded && hasprimalray(model.inner)
            return MOI.INFEASIBILITY_CERTIFICATE
        # elseif stat_lp == LP_Infeasible
        #     return MOI.InfeasiblePoint - xpress wont return
        # elseif cutoff//cutoffindual ???
        else
            return MOI.NO_SOLUTION
        end
    end
end

function MOI.get(model::Optimizer, ::MOI.DualStatus)
    if is_mip(model.inner)
        return MOI.NO_SOLUTION
    else
        stat_lp = get_lp_status2(model.inner)
        if stat_lp == LP_Optimal
            return MOI.FEASIBLE_POINT
        elseif stat_lp == LP_Infeasible && hasdualray(model.inner)
            return MOI.INFEASIBILITY_CERTIFICATE
        # elseif stat_lp == LP_Unbounded
        #     return MOI.InfeasiblePoint - xpress wont return
        # elseif cutoff//cutoffindual ???
        else
            return MOI.NO_SOLUTION
        end
    end
end


#### Pending Block Start ######
#LQOI.get_unbounded_ray!(instance::Optimizer, place) = XPR.getprimalray!(instance.inner, place)


function MOI.get(model::Optimizer, ::MOI.VariablePrimal, x::MOI.VariableIndex)
    return model.variable_primal_solution[_info(model, x).column]
    # if model.has_unbounded_ray
        # return get_dblattrelement(model.inner, "UnbdRay", _info(model, x).column)
    # else
        # return get_dblattrelement(model.inner, "X", _info(model, x).column)
    # end
end

function MOI.get(
    model::Optimizer, ::MOI.ConstraintPrimal,
    c::MOI.ConstraintIndex{MOI.SingleVariable, <:Any}
)
    return MOI.get(model, MOI.VariablePrimal(), MOI.VariableIndex(c.value))
end

function MOI.get(
    model::Optimizer, ::MOI.ConstraintPrimal,
    c::MOI.ConstraintIndex{MOI.ScalarAffineFunction{Float64}, <:Any}
)
    row = _info(model, c).row
    rhs = get_dblattrelement(model.inner, "RHS", row)
    slack = get_dblattrelement(model.inner, "Slack", row)
    return rhs - slack
end

function MOI.get(
    model::Optimizer, ::MOI.ConstraintPrimal,
    c::MOI.ConstraintIndex{MOI.ScalarQuadraticFunction{Float64}, <:Any}
)
    row = _info(model, c).row
    rhs = get_dblattrelement(model.inner, "QCRHS", row)
    slack = get_dblattrelement(model.inner, "QCSlack", row)
    return rhs - slack
end

function _dual_multiplier(model::Optimizer)
    return MOI.get(model, MOI.ObjectiveSense()) == MOI.MIN_SENSE ? 1.0 : -1.0
end

function MOI.get(
    model::Optimizer, ::MOI.ConstraintDual,
    c::MOI.ConstraintIndex{MOI.SingleVariable, MOI.LessThan{Float64}}
)
    column = _info(model, c).column
    x = get_dblattrelement(model.inner, "X", column)
    ub = get_dblattrelement(model.inner, "UB", column)
    if x ≈ ub
        return _dual_multiplier(model) * get_dblattrelement(model.inner, "RC", column)
    else
        return 0.0
    end
end

function MOI.get(
    model::Optimizer, ::MOI.ConstraintDual,
    c::MOI.ConstraintIndex{MOI.SingleVariable, MOI.GreaterThan{Float64}}
)
    info = _info(model, c)
    x = get_dblattrelement(model.inner, "X", info.column)
    lb = _get_variable_lower_bound(model, info)
    if x ≈ lb
        return _dual_multiplier(model) * get_dblattrelement(model.inner, "RC", info.column)
    else
        return 0.0
    end
end

function MOI.get(
    model::Optimizer, ::MOI.ConstraintDual,
    c::MOI.ConstraintIndex{MOI.SingleVariable, MOI.EqualTo{Float64}}
)
    return _dual_multiplier(model) * get_dblattrelement(model.inner, "RC", _info(model, c).column)
end

function MOI.get(
    model::Optimizer, ::MOI.ConstraintDual,
    c::MOI.ConstraintIndex{MOI.SingleVariable, MOI.Interval{Float64}}
)
    return _dual_multiplier(model) * get_dblattrelement(model.inner, "RC", _info(model, c).column)
end

function MOI.get(
    model::Optimizer, ::MOI.ConstraintDual,
    c::MOI.ConstraintIndex{MOI.ScalarAffineFunction{Float64}, <:Any}
)
    if model.has_infeasibility_cert
        return -_dual_multiplier(model) * get_dblattrelement(model.inner, "FarkasDual", _info(model, c).row)
    end
    return _dual_multiplier(model) * get_dblattrelement(model.inner, "Pi", _info(model, c).row)
end

function MOI.get(
    model::Optimizer, ::MOI.ConstraintDual,
    c::MOI.ConstraintIndex{MOI.ScalarQuadraticFunction{Float64}, <:Any}
)
    return _dual_multiplier(model) * get_dblattrelement(model.inner, "QCPi", _info(model, c).row)
end

MOI.get(model::Optimizer, ::MOI.ObjectiveValue) = get_objval(model.inner)

function MOI.get(model::Optimizer, ::MOI.ObjectiveBound)
    obj_rhs = get_dblattr(model.inner, XPRS_OBJRHS)
    if is_mip(model.inner)
        return get_bestbound(model.inner)+obj_rhs
    else
        return get_objval(model.inner)+obj_rhs
    end
end

#### Pending Block End  ######

# Not implemented in Old Wrapper. Get CPUTIME Attribute
#MOI.get(model::Optimizer, ::MOI.SolveTime) = get_dblattr(model.inner, "RunTime")

MOI.get(model::Optimizer, ::MOI.SimplexIterations) = get_simplex_iter_count(model.inner)

MOI.get(model::Optimizer, ::MOI.BarrierIterations) = get_barrier_iter_count(model.inner)
MOI.get(model::Optimizer, ::MOI.NodeCount) = get_node_count(model.inner)

# No MIP gap attribute in Xpress Manual
function MOI.get(model::Optimizer, ::MOI.RelativeGap)
    L = get_mip_objval(model.inner)
    U = get_bestbound(model.inner)
    return abs(U-L)/U
end

MOI.supports(model::Optimizer, ::MOI.DualObjectiveValue) = true

MOI.get(model::Optimizer, ::MOI.DualObjectiveValue) = get_bestbound(model.inner)

function MOI.get(model::Optimizer, ::MOI.ResultCount)
    if model.has_infeasibility_cert || model.has_unbounded_ray
        return 1
    end
    return get_intattr(model.inner, "SolCount")
end

function MOI.get(model::Optimizer, ::MOI.Silent)
    return model.silent
end

function MOI.set(model::Optimizer, ::MOI.Silent, flag::Bool)
    model.silent = flag
    output_flag = flag ? 0 : get(model.params, "OutputFlag", 1)
    setparam!(model.inner, "OutputFlag", output_flag)
    return
end

function MOI.get(model::Optimizer, ::MOI.Name)
    return get_strattr(model.inner, "ModelName")
end

function MOI.set(model::Optimizer, ::MOI.Name, name::String)
    set_strattr!(model.inner, "ModelName", name)
    return
end

MOI.get(model::Optimizer, ::MOI.NumberOfVariables) = length(model.variable_info)
function MOI.get(model::Optimizer, ::MOI.ListOfVariableIndices)
    return sort!(collect(keys(model.variable_info)), by = x -> x.value)
end

MOI.get(model::Optimizer, ::MOI.RawSolver) = model.inner

function MOI.set(
    model::Optimizer, ::MOI.VariablePrimalStart, x::MOI.VariableIndex,
    value::Union{Nothing, Float64}
)
    info = _info(model, x)
    info.start = value
    if value !== nothing
        set_dblattrelement!(model.inner, "Start", info.column, value)

    end
    return
end

function MOI.get(
    model::Optimizer, ::MOI.VariablePrimalStart, x::MOI.VariableIndex
)
    return _info(model, x).start
end

function MOI.get(model::Optimizer, ::MOI.NumberOfConstraints{F, S}) where {F, S}
    # TODO: this could be more efficient.
    return length(MOI.get(model, MOI.ListOfConstraintIndices{F, S}()))
end

_bound_enums(::Type{<:MOI.LessThan}) = (LESS_THAN, LESS_AND_GREATER_THAN)
_bound_enums(::Type{<:MOI.GreaterThan}) = (GREATER_THAN, LESS_AND_GREATER_THAN)
_bound_enums(::Type{<:MOI.Interval}) = (INTERVAL,)
_bound_enums(::Type{<:MOI.EqualTo}) = (EQUAL_TO,)
_bound_enums(::Any) = (nothing,)

_type_enums(::Type{MOI.ZeroOne}) = (BINARY,)
_type_enums(::Type{MOI.Integer}) = (INTEGER,)
_type_enums(::Type{<:MOI.Semicontinuous}) = (SEMICONTINUOUS,)
_type_enums(::Type{<:MOI.Semiinteger}) = (SEMIINTEGER,)
_type_enums(::Any) = (nothing,)

function MOI.get(
    model::Optimizer, ::MOI.ListOfConstraintIndices{MOI.SingleVariable, S}
) where {S}
    indices = MOI.ConstraintIndex{MOI.SingleVariable, S}[]
    for (key, info) in model.variable_info
        if info.bound in _bound_enums(S) || info.type in _type_enums(S)
            push!(indices, MOI.ConstraintIndex{MOI.SingleVariable, S}(key.value))
        end
    end
    return sort!(indices, by = x -> x.value)
end

function MOI.get(
    model::Optimizer,
    ::MOI.ListOfConstraintIndices{MOI.ScalarAffineFunction{Float64}, S}
) where {S}
    indices = MOI.ConstraintIndex{MOI.ScalarAffineFunction{Float64}, S}[]
    for (key, info) in model.affine_constraint_info
        if typeof(info.set) == S
            push!(indices, MOI.ConstraintIndex{MOI.ScalarAffineFunction{Float64}, S}(key))
        end
    end
    return sort!(indices, by = x -> x.value)
end

function MOI.get(
    model::Optimizer,
    ::MOI.ListOfConstraintIndices{MOI.ScalarQuadraticFunction{Float64}, S}
) where {S}
    indices = MOI.ConstraintIndex{MOI.ScalarQuadraticFunction{Float64}, S}[]
    for (key, info) in model.quadratic_constraint_info
        if typeof(info.set) == S
            push!(indices, MOI.ConstraintIndex{MOI.ScalarQuadraticFunction{Float64}, S}(key))
        end
    end
    return sort!(indices, by = x -> x.value)
end

function MOI.get(
    model::Optimizer, ::MOI.ListOfConstraintIndices{MOI.VectorOfVariables, S}
) where {S <: Union{<:MOI.SOS1, <:MOI.SOS2}}
    indices = MOI.ConstraintIndex{MOI.VectorOfVariables, S}[]
    for (key, info) in model.sos_constraint_info
        if typeof(info.set) == S
            push!(indices, MOI.ConstraintIndex{MOI.VectorOfVariables, S}(key))
        end
    end
    return sort!(indices, by = x -> x.value)
end

function MOI.get(
    model::Optimizer,
    ::MOI.ListOfConstraintIndices{MOI.VectorOfVariables, MOI.SecondOrderCone}
)
    indices = MOI.ConstraintIndex{MOI.VectorOfVariables, MOI.SecondOrderCone}[
        MOI.ConstraintIndex{MOI.VectorOfVariables, MOI.SecondOrderCone}(key)
        for (key, info) in model.quadratic_constraint_info
            if typeof(info.set) == MOI.SecondOrderCone
    ]
    return sort!(indices, by = x -> x.value)
end

function MOI.get(model::Optimizer, ::MOI.ListOfConstraints)
    constraints = Set{Tuple{DataType, DataType}}()
    for info in values(model.variable_info)
        if info.bound == NONE
        elseif info.bound == LESS_THAN
            push!(constraints, (MOI.SingleVariable, MOI.LessThan{Float64}))
        elseif info.bound == GREATER_THAN
            push!(constraints, (MOI.SingleVariable, MOI.GreaterThan{Float64}))
        elseif info.bound == LESS_AND_GREATER_THAN
            push!(constraints, (MOI.SingleVariable, MOI.LessThan{Float64}))
            push!(constraints, (MOI.SingleVariable, MOI.GreaterThan{Float64}))
        elseif info.bound == EQUAL_TO
            push!(constraints, (MOI.SingleVariable, MOI.EqualTo{Float64}))
        elseif info.bound == INTERVAL
            push!(constraints, (MOI.SingleVariable, MOI.Interval{Float64}))
        end
        if info.type == CONTINUOUS
        elseif info.type == BINARY
            push!(constraints, (MOI.SingleVariable, MOI.ZeroOne))
        elseif info.type == INTEGER
            push!(constraints, (MOI.SingleVariable, MOI.Integer))
        elseif info.type == SEMICONTINUOUS
            push!(constraints, (MOI.SingleVariable, MOI.Semicontinuous{Float64}))
        elseif info.type == SEMIINTEGER
            push!(constraints, (MOI.SingleVariable, MOI.Semiinteger{Float64}))
        end
    end
    for info in values(model.affine_constraint_info)
        push!(constraints, (MOI.ScalarAffineFunction{Float64}, typeof(info.set)))
    end
    for info in values(model.quadratic_constraint_info)
        if typeof(info.set) == MOI.SecondOrderCone
            push!(constraints, (MOI.VectorOfVariables, MOI.SecondOrderCone))
        else
            push!(constraints, (MOI.ScalarQuadraticFunction{Float64}, typeof(info.set)))
        end
    end
    for info in values(model.sos_constraint_info)
        push!(constraints, (MOI.VectorOfVariables, typeof(info.set)))
    end
    return collect(constraints)
end

function MOI.get(model::Optimizer, ::MOI.ObjectiveFunctionType)
    if model.objective_type == SINGLE_VARIABLE
        return MOI.SINGLE_VARIABLE
    elseif model.objective_type == SCALAR_AFFINE
        return MOI.ScalarAffineFunction{Float64}
    else
        @assert model.objective_type == SCALAR_QUADRATIC
        return MOI.ScalarQuadraticFunction{Float64}
    end
end

function MOI.modify(
    model::Optimizer,
    c::MOI.ConstraintIndex{MOI.ScalarAffineFunction{Float64}, <:Any},
    chg::MOI.ScalarCoefficientChange{Float64}
)
    chg_coeffs!(
        model.inner, _info(model, c).row, _info(model, chg.variable).column,
        chg.new_coefficient
    )
end

function MOI.modify(
    model::Optimizer,
    c::MOI.ObjectiveFunction{MOI.ScalarAffineFunction{Float64}},
    chg::MOI.ScalarCoefficientChange{Float64}
)
    set_dblattrelement!(
        model.inner, "Obj", _info(model, chg.variable).column,
        chg.new_coefficient
    )
end

"""
    _replace_with_matching_sparsity!(
        model::Optimizer,
        previous::MOI.ScalarAffineFunction,
        replacement::MOI.ScalarAffineFunction, row::Int
    )

Internal function, not intended for external use.

Change the linear constraint function at index `row` in `model` from
`previous` to `replacement`. This function assumes that `previous` and
`replacement` have exactly the same sparsity pattern w.r.t. which variables
they include and that both constraint functions are in canonical form (as
returned by `MOIU.canonical()`. Neither assumption is checked within the body
of this function.
"""
function _replace_with_matching_sparsity!(
    model::Optimizer,
    previous::MOI.ScalarAffineFunction,
    replacement::MOI.ScalarAffineFunction, row::Int
)
    rows = fill(Cint(row), length(replacement.terms))
    cols = [Cint(_info(model, t.variable_index).column) for t in replacement.terms]
    coefs = MOI.coefficient.(replacement.terms)
    chg_coeffs!(model.inner, rows, cols, coefs)
    return
end

"""
    _replace_with_different_sparsity!(
        model::Optimizer,
        previous::MOI.ScalarAffineFunction,
        replacement::MOI.ScalarAffineFunction, row::Int
    )

Internal function, not intended for external use.

    Change the linear constraint function at index `row` in `model` from
`previous` to `replacement`. This function assumes that `previous` and
`replacement` may have different sparsity patterns.

This function (and `_replace_with_matching_sparsity!` above) are necessary
because in order to fully replace a linear constraint, we have to zero out the
current matrix coefficients and then set the new matrix coefficients. When the
sparsity patterns match, the zeroing-out step can be skipped.
"""
function _replace_with_different_sparsity!(
    model::Optimizer,
    previous::MOI.ScalarAffineFunction,
    replacement::MOI.ScalarAffineFunction, row::Int
)
    # First, zero out the old constraint function terms.
    rows = fill(Cint(row), length(previous.terms))
    cols = [Cint(_info(model, t.variable_index).column) for t in previous.terms]
    coefs = fill(0.0, length(previous.terms))
    chg_coeffs!(model.inner, rows, cols, coefs)
    # Next, set the new constraint function terms.
    rows = fill(Cint(row), length(replacement.terms))
    cols = [Cint(_info(model, t.variable_index).column) for t in replacement.terms]
    coefs = MOI.coefficient.(replacement.terms)
    chg_coeffs!(model.inner, rows, cols, coefs)
    return
end

"""
    _matching_sparsity_pattern(
        f1::MOI.ScalarAffineFunction{Float64},
        f2::MOI.ScalarAffineFunction{Float64}
    )

Internal function, not intended for external use.

Determines whether functions `f1` and `f2` have the same sparsity pattern
w.r.t. their constraint columns. Assumes both functions are already in
canonical form.
"""
function _matching_sparsity_pattern(
    f1::MOI.ScalarAffineFunction{Float64}, f2::MOI.ScalarAffineFunction{Float64}
)
    if axes(f1.terms) != axes(f2.terms)
        return false
    end
    for (f1_term, f2_term) in zip(f1.terms, f2.terms)
        if MOI.term_indices(f1_term) != MOI.term_indices(f2_term)
            return false
        end
    end
    return true
end

function MOI.set(
    model::Optimizer, ::MOI.ConstraintFunction,
    c::MOI.ConstraintIndex{MOI.ScalarAffineFunction{Float64}, <:SCALAR_SETS},
    f::MOI.ScalarAffineFunction{Float64}
)
    previous = MOI.get(model, MOI.ConstraintFunction(), c)
    MOI.Utilities.canonicalize!(previous)
    replacement = MOI.Utilities.canonical(f)
    # If the previous and replacement constraint functions have exactly
    # the same sparsity pattern, then we can take a faster path by just
    # passing the replacement terms to the model. But if their sparsity
    # patterns differ, then we need to first zero out the previous terms
    # and then set the replacement terms.
    row = _info(model, c).row
    if _matching_sparsity_pattern(previous, replacement)
        _replace_with_matching_sparsity!(model, previous, replacement, row)
    else
        _replace_with_different_sparsity!(model, previous, replacement, row)
    end
    current_rhs = get_dblattrelement(model.inner, "RHS", row)
    new_rhs = current_rhs - (replacement.constant - previous.constant)
    set_dblattrelement!(model.inner, "RHS", row, new_rhs)
    return
end

function MOI.get(
    model::Optimizer, ::MOI.ConstraintBasisStatus,
    c::MOI.ConstraintIndex{MOI.ScalarAffineFunction{Float64}, S}
) where {S <: SCALAR_SETS}
    row = _info(model, c).row
    cbasis = get_intattrelement(model.inner, "CBasis", row)
    if cbasis == 0
        return MOI.BASIC
    elseif cbasis == -1
        return MOI.NONBASIC
    else
        error("CBasis value of $(cbasis) isn't defined.")
    end
end

function MOI.get(
    model::Optimizer, ::MOI.ConstraintBasisStatus,
    c::MOI.ConstraintIndex{MOI.SingleVariable, S}
) where {S <: SCALAR_SETS}
    column = _info(model, c).column
    vbasis = get_intattrelement(model.inner, "VBasis", column)
    if vbasis == 0
        return MOI.BASIC
    elseif vbasis == -1
        if S <: MOI.LessThan
            return MOI.BASIC
        elseif !(S <: MOI.Interval)
            return MOI.NONBASIC
        else
            return MOI.NONBASIC_AT_LOWER
        end
    elseif vbasis == -2
        MOI.NONBASIC_AT_UPPER
        if S <: MOI.GreaterThan
            return MOI.BASIC
        elseif !(S <: MOI.Interval)
            return MOI.NONBASIC
        else
            return MOI.NONBASIC_AT_UPPER
        end
    elseif vbasis == -3
        return MOI.SUPER_BASIC
    else
        error("VBasis value of $(vbasis) isn't defined.")
    end
end

# ==============================================================================
#    Callbacks in Gurobi
# ==============================================================================

struct CallbackFunction <: MOI.AbstractOptimizerAttribute end

function MOI.set(model::Optimizer, ::CallbackFunction, f::Function)
    set_callback_func!(model.inner, f)
    update_model!(model.inner)
    return
end

struct CallbackVariablePrimal <: MOI.AbstractVariableAttribute end

function load_callback_variable_primal(model, cb_data, cb_where)
    if cb_where != CB_MIPSOL
        error("`load_callback_variable_primal` must be called from `CB_MIPSOL`.")
    end
    resize!(model.callback_variable_primal, length(model.variable_info))
    cbget_mipsol_sol(cb_data, cb_where, model.callback_variable_primal)
    return
end

# Note: you must call load_callback_variable_primal first.
function MOI.get(
    model::Optimizer, ::CallbackVariablePrimal, x::MOI.VariableIndex
)
    return model.callback_variable_primal[_info(model, x).column]
end

"""
    function cblazy!(
        cb_data::CallbackData, model::Optimizer,
        f::MOI.ScalarAffineFunction{Float64},
        s::Union{MOI.LessThan{Float64}, MOI.GreaterThan{Float64}, MOI.EqualTo{Float64}}
    )

Add a lazy cut to the model `m`.

You must have the option `LazyConstraints` set  via `Optimizer(LazyConstraint=1)`.
This can only be called in a callback from `CB_MIPSOL`.
"""
function cblazy!(
    cb_data::CallbackData, model::Optimizer,
    f::MOI.ScalarAffineFunction{Float64},
    s::Union{MOI.LessThan{Float64}, MOI.GreaterThan{Float64}, MOI.EqualTo{Float64}}
)
    indices, coefficients = _indices_and_coefficients(model, f)
    sense, rhs = _sense_and_rhs(s)
    return cblazy(cb_data, Cint.(indices), coefficients, Char(sense), rhs)
end

"""
    compute_conflict(model::Optimizer)

Compute a minimal subset of the constraints and variables that keep the model
infeasible.

See also `Gurobi.ConflictStatus` and `Gurobi.ConstraintConflictStatus`.

Note that if `model` is modified after a call to `compute_conflict`, the
conflict is not purged, and any calls to the above attributes will return values
for the original conflict without a warning.
"""
function compute_conflict(model::Optimizer)
    try
        computeIIS(model.inner)
    catch exc
        if isa(exc, GurobiError) && exc.code == 10015
            model.inner.conflict = Gurobi.GRB_INFEASIBLE
        else
            rethrow(exc)
        end
    end
    return
end

function _ensure_conflict_computed(model::Optimizer)
    if model.inner.conflict == -1
        error("Cannot access conflict status. Call `Gurobi.compute_conflict(model)` first. " *
              "In case the model is modified, the computed conflict will not be purged.")
    end
end

function _is_feasible(model::Optimizer)
    return model.inner.conflict == Gurobi.GRB_INFEASIBLE
end

"""
    ConflictStatus()

Return an `MOI.TerminationStatusCode` indicating the status of the last
computed conflict. If a minimal conflict is found, it will return
`MOI.OPTIMAL`. If the problem is feasible, it will return `MOI.INFEASIBLE`. If
`compute_conflict` has not been called yet, it will return
`MOI.OPTIMIZE_NOT_CALLED`.
"""
struct ConflictStatus <: MOI.AbstractModelAttribute end

MOI.is_set_by_optimize(::ConflictStatus) = true

function MOI.get(model::Optimizer, ::ConflictStatus)
    if model.inner.conflict == -1
        return MOI.OPTIMIZE_NOT_CALLED
    elseif model.inner.conflict == 0
        return MOI.OPTIMAL
    elseif model.inner.conflict == Gurobi.GRB_LOADED
        return MOI.OTHER_ERROR
    elseif model.inner.conflict == Gurobi.GRB_OPTIMAL
        return MOI.OPTIMAL
    elseif model.inner.conflict == Gurobi.GRB_INFEASIBLE
        return MOI.INFEASIBLE
    elseif model.inner.conflict == Gurobi.GRB_INF_OR_UNBD
        return MOI.INFEASIBLE_OR_UNBOUNDED
    elseif model.inner.conflict == Gurobi.GRB_USER_OBJ_LIMIT
        return MOI.OBJECTIVE_LIMIT
    elseif model.inner.conflict == Gurobi.GRB_ITERATION_LIMIT
        return MOI.ITERATION_LIMIT
    elseif model.inner.conflict == Gurobi.GRB_NODE_LIMIT
        return MOI.NODE_LIMIT
    elseif model.inner.conflict == Gurobi.GRB_TIME_LIMIT
        return MOI.TIME_LIMIT
    elseif model.inner.conflict == Gurobi.GRB_SOLUTION_LIMIT
        return MOI.SOLUTION_LIMIT
    elseif model.inner.conflict == Gurobi.GRB_INTERRUPTED
        return MOI.INTERRUPTED
    elseif model.inner.conflict == Gurobi.GRB_NUMERIC
        return MOI.NUMERICAL_ERROR
    elseif model.inner.conflict == Gurobi.GRB_SUBOPTIMAL
        return MOI.OTHER_LIMIT
    elseif model.inner.conflict == Gurobi.GRB_INPROGRESS
        return MOI.OTHER_ERROR
    else
        return MOI.OTHER_ERROR
    end
end

function MOI.supports(::Optimizer, ::ConflictStatus)
    return true
end

"""
    ConstraintConflictStatus()

A Boolean constraint attribute indicating whether the constraint participates
in the last computed conflict.
"""
struct ConstraintConflictStatus <: MOI.AbstractConstraintAttribute end

MOI.is_set_by_optimize(::ConstraintConflictStatus) = true

function MOI.get(
    model::Optimizer, ::ConstraintConflictStatus,
    index::MOI.ConstraintIndex{MOI.SingleVariable, <:MOI.LessThan}
)
    _ensure_conflict_computed(model)
    if _is_feasible(model)
        return false
    end
    return get_intattrelement(model.inner, "IISUB", _info(model, index).column) > 0
end

function MOI.get(
    model::Optimizer, ::ConstraintConflictStatus,
    index::MOI.ConstraintIndex{MOI.SingleVariable, <:MOI.GreaterThan}
)
    _ensure_conflict_computed(model)
    if _is_feasible(model)
        return false
    end
    return get_intattrelement(model.inner, "IISLB", _info(model, index).column) > 0
end

function MOI.get(
    model::Optimizer, ::ConstraintConflictStatus,
    index::MOI.ConstraintIndex{
        MOI.SingleVariable, <:Union{MOI.EqualTo, MOI.Interval}
    }
)
    _ensure_conflict_computed(model)
    if _is_feasible(model)
        return false
    end
    if get_intattrelement(model.inner, "IISLB", _info(model, index).column) > 0
        return true
    end
    return get_intattrelement(model.inner, "IISUB", _info(model, index).column) > 0
end

function MOI.get(
    model::Optimizer, ::ConstraintConflictStatus,
    index::MOI.ConstraintIndex{
        MOI.ScalarAffineFunction{Float64},
        <:Union{MOI.LessThan, MOI.GreaterThan, MOI.EqualTo}
    }
)
    _ensure_conflict_computed(model)
    if _is_feasible(model)
        return false
    end
    return get_intattrelement(model.inner, "IISConstr", _info(model, index).row) > 0
end

function MOI.get(
    model::Optimizer, ::ConstraintConflictStatus,
    index::MOI.ConstraintIndex{
        MOI.ScalarQuadraticFunction{Float64},
        <:Union{MOI.LessThan, MOI.GreaterThan}
    }
)
    _ensure_conflict_computed(model)
    if _is_feasible(model)
        return false
    end
    return get_intattrelement(model.inner, "IISQConstr", _info(model, index).row) > 0
end

function MOI.supports(
    ::Optimizer, ::ConstraintConflictStatus,
    ::Type{<:MOI.ConstraintIndex{MOI.SingleVariable, <:SCALAR_SETS}}
)
    return true
end

function MOI.supports(
    ::Optimizer, ::ConstraintConflictStatus,
    ::Type{<:MOI.ConstraintIndex{
        MOI.ScalarAffineFunction{Float64},
        <:Union{MOI.LessThan, MOI.GreaterThan, MOI.EqualTo}
    }}
)
    return true
end

function MOI.supports(
    ::Optimizer, ::ConstraintConflictStatus,
    ::Type{<:MOI.ConstraintIndex{
        MOI.ScalarQuadraticFunction{Float64},
        <:Union{MOI.LessThan, MOI.GreaterThan}
    }}
)
    return true
end

#= Implemenent SOC later
###
### VectorOfVariables-in-SecondOrderCone
###

function _info(
    model::Optimizer,
    c::MOI.ConstraintIndex{MOI.VectorOfVariables, MOI.SecondOrderCone}
)
    if haskey(model.quadratic_constraint_info, c.value)
        return model.quadratic_constraint_info[c.value]
    end
    throw(MOI.InvalidIndex(c))
end

function MOI.add_constraint(
    model::Optimizer, f::MOI.VectorOfVariables, s::MOI.SecondOrderCone
)
    if length(f.variables) != s.dimension
        error("Dimension of $(s) does not match number of terms in $(f)")
    end

    # SOC is the cone: t ≥ ||x||₂ ≥ 0. In quadratic form, this is
    # t² - Σᵢ xᵢ² ≥ 0 and t ≥ 0.

    # First, check the lower bound on t.

    t_info = _info(model, f.variables[1])
    lb = _get_variable_lower_bound(model, t_info)
    if isnan(t_info.lower_bound_if_soc) && lb < 0.0
        t_info.lower_bound_if_soc = lb
        set_dblattrelement!(model.inner, "LB", t_info.column, 0.0)
    end
    t_info.num_soc_constraints += 1

    # Now add the quadratic constraint.

    I = Cint[_info(model, v).column for v in f.variables]
    V = fill(Cdouble(-1.0), length(f.variables))
    V[1] = 1.0
    add_qconstr!(model.inner, Cint[], Cdouble[], I, I, V, Cchar('>'), 0.0)
    model.last_constraint_index += 1
    model.quadratic_constraint_info[model.last_constraint_index] =
        ConstraintInfo(length(model.quadratic_constraint_info) + 1, s)
    return MOI.ConstraintIndex{MOI.VectorOfVariables, MOI.SecondOrderCone}(model.last_constraint_index)
end

function MOI.is_valid(
    model::Optimizer,
    c::MOI.ConstraintIndex{MOI.VectorOfVariables, MOI.SecondOrderCone}
)
    info = get(model.quadratic_constraint_info, c.value, nothing)
    return info !== nothing && typeof(info.set) == MOI.SecondOrderCone
end

function MOI.delete(
    model::Optimizer,
    c::MOI.ConstraintIndex{MOI.VectorOfVariables, MOI.SecondOrderCone}
)
    f = MOI.get(model, MOI.ConstraintFunction(), c)
    info = _info(model, c)
    delqconstrs!(model.inner, [info.row])
    for (key, info_2) in model.quadratic_constraint_info
        if info_2.row > info.row
            info_2.row -= 1
        end
    end
    model.name_to_constraint_index = nothing
    delete!(model.quadratic_constraint_info, c.value)
    # Reset the lower bound on the `t` variable.
    t_info = _info(model, f.variables[1])
    t_info.num_soc_constraints -= 1
    if t_info.num_soc_constraints > 0
        # Don't do anything. There are still SOC associated with this variable.
        return
    elseif isnan(t_info.lower_bound_if_soc)
        # Don't do anything. It must have a >0 lower bound anyway.
        return
    end
    # There was a previous bound that we over-wrote, and it must have been
    # < 0 otherwise we wouldn't have needed to overwrite it.
    @assert t_info.lower_bound_if_soc < 0.0
    tmp_lower_bound = t_info.lower_bound_if_soc
    t_info.lower_bound_if_soc = NaN
    set_dblattrelement!(model.inner, "LB", t_info.column, tmp_lower_bound)
    return
end

function MOI.get(
    model::Optimizer, ::MOI.ConstraintSet,
    c::MOI.ConstraintIndex{MOI.VectorOfVariables, MOI.SecondOrderCone}
)
    return _info(model, c).set
end

function MOI.get(
    model::Optimizer, ::MOI.ConstraintFunction,
    c::MOI.ConstraintIndex{MOI.VectorOfVariables, MOI.SecondOrderCone}
)
    a, b, I, J, V = getqconstr(model.inner, _info(model, c).row)
    @assert length(a) == length(b) == 0  # Check for no linear terms.
    t = nothing
    x = MOI.VariableIndex[]
    for (i, j, coef) in zip(I, J, V)
        v = model.variable_info[CleverDicts.LinearIndex(i + 1)].index
        @assert i == j  # Check for no off-diagonals.
        if coef == 1.0
            @assert t === nothing  # There should only be one `t`.
            t = v
        else
            @assert coef == -1.0  # The coefficients _must_ be -1 for `x` terms.
            push!(x, v)
        end
    end
    @assert t !== nothing  # Check that we found a `t` variable.
    return MOI.VectorOfVariables([t; x])
end

function MOI.get(
    model::Optimizer, ::MOI.ConstraintPrimal,
    c::MOI.ConstraintIndex{MOI.VectorOfVariables, MOI.SecondOrderCone}
)
    f = MOI.get(model, MOI.ConstraintFunction(), c)
    return MOI.get(model, MOI.VariablePrimal(), f.variables)
end

function MOI.get(
    model::Optimizer, ::MOI.ConstraintName,
    c::MOI.ConstraintIndex{MOI.VectorOfVariables, MOI.SecondOrderCone}
)
    return _info(model, c).name
end

function MOI.set(
    model::Optimizer, ::MOI.ConstraintName,
    c::MOI.ConstraintIndex{MOI.VectorOfVariables, MOI.SecondOrderCone},
    name::String
)
    info = _info(model, c)
    if !isempty(info.name) && model.name_to_constraint_index !== nothing
        delete!(model.name_to_constraint_index, info.name)
    end
    set_strattrelement!(model.inner, "QCName", info.row, name)
    info.name = name
    if model.name_to_constraint_index === nothing || isempty(name)
        return
    end
    if haskey(model.name_to_constraint_index, name)
        model.name_to_constraint_index = nothing
    else
        model.name_to_constraint_index[c] = name
    end
    return
end
=#
