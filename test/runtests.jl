using Xpress, Test

@testset "Xpress API" begin

    @test Xpress.getversion() isa VersionNumber

    @test Xpress.getbanner() isa String

    xp = Xpress.XpressProblem()

    @test Xpress.getprobname(xp) == ""
    @test Xpress.setprobname(xp, "xpress-optimization-problem") == nothing
    @test Xpress.getprobname(xp) == "xpress-optimization-problem"
using SparseArrays
using LinearAlgebra
using Test

#=
tests = ["xprs_attrs_test",
         "lp_01a",
         "lp_01b",
         "lp_02",
         "lp_03",
         "lp_04",
         "mip_01",
         "qp_01",
         "qp_02",
         "qcqp_01",
         "iis",
         "mathprog",
         "MOIWrapper",
        #  "wordhunt"
         ]
=#

tests = ["MOI_Wrapper",
        #  "wordhunt"
         ]

end
