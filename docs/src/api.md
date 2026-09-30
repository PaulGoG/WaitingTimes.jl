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
WaitingTimes.scan_work
```

## Streaming and online estimation

```@docs
StreamingState
update!
pending
WaitingTimes.compact!
DistributionAccumulator
OnlineWaitingTimes
snapshot
status
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
WaitingTimes.ks_distance
WaitingTimes.discrete_distribution
```

## Pipeline

```@docs
Settings
load_settings
threshold_list
WaitingTimes.Config.threshold_decimals
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
WaitingTimes.Preprocessing.round_values
WaitingTimes.Preprocessing.trailing_mean_fluctuations
WaitingTimes.Preprocessing.log_returns
WaitingTimes.Preprocessing.differences
WaitingTimes.Preprocessing.centered_moving_average
WaitingTimes.Preprocessing.clip_quantile
WaitingTimes.Preprocessing.clip_sigma
WaitingTimes.Preprocessing.clip_extremes
WaitingTimes.Preprocessing.remove_rows
WaitingTimes.Preprocessing.collapse_ties
WaitingTimes.Preprocessing.quantized_series
WaitingTimes.Preprocessing.sampling_summary
WaitingTimes.Preprocessing.value_summary
WaitingTimes.Preprocessing.resolution_digits
WaitingTimes.Preprocessing.increment_scale
WaitingTimes.Preprocessing.digits_sensitivity
WaitingTimes.Preprocessing.suggest_digits
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
Collection
load_collection
list_collections
distribution
thresholds
summary_table
load_series
export_legacy
WaitingTimes.Storage.write_collection_readme
```

## Backends and figures

```@docs
WaitingTimes.Backends.get_best_backend
WaitingTimes.Backends.to_backend
WaitingTimes.Backends.backend_name
WaitingTimes.figure_theme
WaitingTimes.decade_ticks
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
WaitingTimes.Synthetic.duty_cycle_mask
WaitingTimes.Synthetic.bernoulli_mask
WaitingTimes.Synthetic.gilbert_elliott_mask
WaitingTimes.Synthetic.stationary_loss_rate
WaitingTimes.Synthetic.Disruption
WaitingTimes.Synthetic.disruption_mask
WaitingTimes.Synthetic.apply_mask
WaitingTimes.Synthetic.gap_scenario
```
