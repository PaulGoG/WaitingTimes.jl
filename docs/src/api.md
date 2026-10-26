# API

```@docs
WaitingTimes
```

## Grid and thresholds

```@docs
quantize
Threshold
threshold
format_threshold
parse_threshold
WaitingTimes.narrow_integer
WaitingTimes.GRID_TOLERANCE
WaitingTimes.on_grid
float(::Threshold)
```

## Series and gaps

```@docs
QuantizedSeries
PreparationRecord
PreparationStep
detect_gaps
declare_gaps
WaitingTimes.GAP_KINDS
gap_table
classify
class_counts
WaitingTimes.with_step
WaitingTimes.sampling_step
WaitingTimes.record_length
WaitingTimes.observed_mask
WaitingTimes.segment_lengths
WaitingTimes.segment_table
WaitingTimes.describe
WaitingTimes.SeriesDescription
WaitingTimes.TIME_UNITS
WaitingTimes.CLASS_EXACT
WaitingTimes.CLASS_GAP_CROSSING
WaitingTimes.CLASS_RIGHT_CENSORED
WaitingTimes.record!
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
WaitingTimes.SearchWorkspace
WaitingTimes.MaxTree
WaitingTimes.FenwickWorkspace
WaitingTimes.check_threshold
WaitingTimes.first_at_least
WaitingTimes.duration
```

## Streaming and online estimation

```@docs
StreamingState
update!
pending
DistributionAccumulator
OnlineWaitingTimes
push!(::OnlineWaitingTimes, ::Integer, ::Real)
push!(::OnlineWaitingTimes, ::Real)
append!(::OnlineWaitingTimes, ::Any, ::Any)
snapshot
status
```

## Distributions

```@docs
WaitingTimeDistribution
empirical_distribution
==(::WaitingTimeDistribution, ::WaitingTimeDistribution)
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
WaitingTimes.PACKAGE_ROOT
WaitingTimes.Config.KNOWN_KEYS
WaitingTimes.Config.PREPROCESSING_OPS
WaitingTimes.Config.step_tag
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
WaitingTimes.Preprocessing.log_levels
WaitingTimes.Preprocessing.differences
WaitingTimes.Preprocessing.centered_moving_average
WaitingTimes.Preprocessing.clip_quantile
WaitingTimes.Preprocessing.clip_sigma
WaitingTimes.Preprocessing.clip_extremes
WaitingTimes.Preprocessing.collapse_ties
WaitingTimes.Preprocessing.quantized_series
WaitingTimes.Preprocessing.index_series
WaitingTimes.Preprocessing.read_gap_intervals
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
WaitingTimes.Provenance.tree_hash
WaitingTimes.Provenance.active_manifest
WaitingTimes.Provenance.manifest_entry
WaitingTimes.Provenance.source_identity
WaitingTimes.Provenance.package_identity
WaitingTimes.Provenance.source_summary
WaitingTimes.Provenance.MINIMUM_PRODUCER_VERSION
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
source_descriptor
WaitingTimes.censoring_histogram
export_legacy
WaitingTimes.Storage.write_collection_readme
```

## Backends and figures

```@docs
WaitingTimes.Backends.get_best_backend
WaitingTimes.Backends.to_backend
WaitingTimes.Backends.backend_name
WaitingTimes.Backends.register_backend!
WaitingTimes.Backends.BACKEND_PROBES
WaitingTimes.Backends.cpu_model
WaitingTimes.Backends.device_fingerprint
WaitingTimes.Backends.reclaim_device_memory!
WaitingTimes.Backends.host_backend
WaitingTimes.Backends.load_device_packages
WaitingTimes.Backends.GPU_PACKAGES
WaitingTimes.figure_theme
WaitingTimes.decade_ticks
WaitingTimes.plot_series
WaitingTimes.plot_distribution
WaitingTimes.plot_values
WaitingTimes.save_figure
```

## Synthetic data

```@docs
WaitingTimes.Synthetic.random_walk
WaitingTimes.Synthetic.iid_series
WaitingTimes.Synthetic.insert_missing
WaitingTimes.Synthetic.irregular_times
```
