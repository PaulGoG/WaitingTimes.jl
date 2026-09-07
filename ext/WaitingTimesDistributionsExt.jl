module WaitingTimesDistributionsExt

using Distributions: DiscreteNonParametric
using WaitingTimes: WaitingTimes, WaitingTimeDistribution, nsamples, probabilities, support

"""
    WaitingTimes.discrete_distribution(d::WaitingTimeDistribution)

`DiscreteNonParametric` over the support of `d` with its probability masses,
so the standard `cdf`, `ccdf`, `quantile`, `mean` and `rand` methods apply and
truncated model distributions can be compared with it.
"""
function WaitingTimes.discrete_distribution(d::WaitingTimeDistribution)
    nsamples(d) > 0 || throw(ArgumentError("the distribution is empty"))
    return DiscreteNonParametric(support(d), probabilities(d))
end

DiscreteNonParametric(d::WaitingTimeDistribution) = WaitingTimes.discrete_distribution(d)

end # module
