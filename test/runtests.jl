using WaitingTimes
using Test
using Aqua
using JET

@testset "WaitingTimes.jl" begin
    @testset "Code quality (Aqua.jl)" begin
        Aqua.test_all(WaitingTimes)
    end
    @testset "Code linting (JET.jl)" begin
        JET.test_package(WaitingTimes; target_modules = (WaitingTimes,))
    end
    # Write your tests here.
end
