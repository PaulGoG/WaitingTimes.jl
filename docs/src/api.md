# API

## Grid and thresholds

```@docs
quantize
Threshold
threshold
format_threshold
parse_threshold
WaitingTimes.narrow_integer
```

## Series and gaps

```@docs
QuantizedSeries
PreparationRecord
PreparationStep
detect_gaps
declare_gaps
gap_table
classify
class_counts
```

## Kernels

```@docs
AbstractSearch
NaiveSearch
GuardedSearch
SegmentTreeSearch
FenwickSweep
StreamingSearch
DeviceSearch
device_search
waiting_times
waiting_times!
WaitingTimes.workspace
WaitingTimes.suffix_maximum
```

## Streaming

```@docs
StreamingState
update!
pending
DistributionAccumulator
```

## Distributions

```@docs
WaitingTimeDistribution
empirical_distribution
WaitingTimes.support
WaitingTimes.counts
WaitingTimes.probabilities
WaitingTimes.cumulative
WaitingTimes.survival
WaitingTimes.nsamples
WaitingTimes.mean_waiting_time
WaitingTimes.discrete_distribution
```

## Pipeline

```@docs
Settings
load_settings
threshold_list
effective_config
prepare
generate
validate
run_pipeline
CollectionHandle
```

## Preprocessing

```@docs
WaitingTimes.Preprocessing.RawSeries
WaitingTimes.Preprocessing.read_series
WaitingTimes.Preprocessing.select_range
WaitingTimes.Preprocessing.exclude_intervals
WaitingTimes.Preprocessing.trailing_mean_fluctuations
WaitingTimes.Preprocessing.log_returns
WaitingTimes.Preprocessing.differences
WaitingTimes.Preprocessing.centered_moving_average
WaitingTimes.Preprocessing.clip_quantile
WaitingTimes.Preprocessing.collapse_ties
WaitingTimes.Preprocessing.quantized_series
WaitingTimes.Preprocessing.sampling_summary
WaitingTimes.Preprocessing.value_summary
```

## Provenance, naming, storage

```@docs
WaitingTimes.Provenance.artefact_id
WaitingTimes.Provenance.content_hash
WaitingTimes.Provenance.canonical_toml
WaitingTimes.Provenance.slugify
WaitingTimes.Provenance.git_state
WaitingTimes.Provenance.hardware_fingerprint
WaitingTimes.Provenance.backup_existing!
WaitingTimes.Naming.artefact_name
WaitingTimes.Naming.parse_artefact_name
WaitingTimes.Storage.partition_path
WaitingTimes.Storage.load_distributions
```

## Backends and figures

```@docs
WaitingTimes.Backends.get_best_backend
WaitingTimes.Backends.to_backend
WaitingTimes.Backends.backend_name
WaitingTimes.plot_series
WaitingTimes.plot_distribution
WaitingTimes.save_figure
```

## Synthetic data

```@docs
WaitingTimes.Synthetic.random_walk
WaitingTimes.Synthetic.iid_series
WaitingTimes.Synthetic.insert_missing
WaitingTimes.Synthetic.irregular_times
```
