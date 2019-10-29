struct XpressError <: Exception
    errorcode::Int
    msg::String
end

function Base.showerror(io::IO, err::XpressError)
    print(io, "XpressError: ")
    if err.errorcode == 1
        print(io, "Bad input encountered.")
    elseif err.errorcode == 2
        print(io, "Bad or corrupt file - unrecoverable.")
    elseif err.errorcode == 4
        print(io, "Memory error.")
    elseif err.errorcode == 8
        print(io, "Corrupt use.")
    elseif err.errorcode == 16
        print(io, "Program error.")
    elseif err.errorcode == 32
        print(io, "Subroutine not completed successfully, possibly due to invalid argument.")
    elseif err.errorcode == 128
        print(io, "Too many users.")
    else
        print(io, "Unrecoverable error.")
    end
    print(io, " $(err.msg)")
end

function fixinfinity(val::Float64)
    if val == Inf
        return XPRS_PLUSINFINITY
    elseif val == -Inf
        return XPRS_MINUSINFINITY
    else
        return val
    end
end

function fixinfinity!(vals::Vector{Float64})
    map!(fixinfinity, vals, vals)
end

"""
    Xpress.CWrapper

abstract type Xpress.CWrapper
"""
abstract type CWrapper end

Base.unsafe_convert(T::Type{Ptr{Nothing}}, t::CWrapper) = t.ptr

struct XpressProblem <: CWrapper
    ptr::Lib.XPRSprob
    function XpressProblem()
        ref = Ref{Lib.XPRSprob}()
        r = createprob(ref)
        r != 0 && error("Unable to create a Xpress Problem. Received error code $r")
        ptr = ref[]
        ptr == C_NULL && error("Failed to create XpressProblem. Received null pointer from Xpress C interface.")
        p = new(ptr)
        atexit(() -> destroyprob(p))
        return p
    end
end




