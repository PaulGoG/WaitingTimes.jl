# DiscreteNonParametric view of a distribution: the method of
# discrete_distribution, declared and documented in src/WaitingTimes.jl.
module WaitingTimesDistributionsExt

using Distributions: Distributions, DiscreteNonParametric
using WaitingTimes: WaitingTimes, WaitingTimeDistribution, nsamples, probabilities, support

function WaitingTimes.discrete_distribution(d::WaitingTimeDistribution)
    nsamples(d) > 0 || throw(ArgumentError("the distribution is empty"))
    return DiscreteNonParametric(support(d), probabilities(d))
end

function Distributions.DiscreteNonParametric(d::WaitingTimeDistribution)
    WaitingTimes.discrete_distribution(d)
end

end # module
