# Internals

Docstrings of the internal modules and functions, kept here so that the whole package is documented; none of these names is part of the public contract ([Interfacing](interfacing.md)).

## Config

```@docs
WaitingTimes.Config
WaitingTimes.Config.PreprocessingOp
WaitingTimes.Config.validate_step
WaitingTimes.Config.warn_ignored_keys
WaitingTimes.Config.decimals
```

## Preprocessing

```@docs
WaitingTimes.Preprocessing
WaitingTimes.Preprocessing.apply_steps
WaitingTimes.Preprocessing.terminal_overview
WaitingTimes.Preprocessing.remove_rows
WaitingTimes.Preprocessing.STEP_TRANSFORMS
WaitingTimes.Preprocessing.check_finite
```

## Provenance

```@docs
WaitingTimes.Provenance
WaitingTimes.Provenance.write_toml
WaitingTimes.Provenance.read_toml
WaitingTimes.Provenance.file_sha256
WaitingTimes.Provenance.write_hardware_fingerprint
WaitingTimes.Provenance.session_id
WaitingTimes.Provenance.record_to_dict
WaitingTimes.Provenance.dict_to_record
WaitingTimes.Provenance.toml_ready
WaitingTimes.Provenance.git_output
WaitingTimes.Provenance.work_tree_identity
WaitingTimes.Provenance.manifest_identity
WaitingTimes.Provenance.identity_record
WaitingTimes.Provenance.merge_config
```

## Naming

```@docs
WaitingTimes.Naming
```

## Monitoring

```@docs
WaitingTimes.Monitoring
WaitingTimes.Monitoring.with_run_logging
WaitingTimes.Monitoring.run_progress
WaitingTimes.Monitoring.log_level
```

## Storage

```@docs
WaitingTimes.Storage
WaitingTimes.Storage.MANIFEST_FILE
WaitingTimes.Storage.SOURCE_FILE
WaitingTimes.Storage.write_distribution
WaitingTimes.Storage.read_distribution
WaitingTimes.Storage.write_summary
WaitingTimes.Storage.write_catalog
WaitingTimes.Storage.write_index
WaitingTimes.Storage.read_index
WaitingTimes.Storage.write_waiting_times
WaitingTimes.Storage.read_waiting_times
WaitingTimes.Storage.write_series_files
WaitingTimes.Storage.read_series_files
WaitingTimes.Storage.write_gap_file
WaitingTimes.Storage.read_gap_file
WaitingTimes.Storage.write_censoring
WaitingTimes.Storage.censoring_path
WaitingTimes.Storage.distribution_table
WaitingTimes.Storage.READABLE_SCHEMAS
WaitingTimes.Storage.preprocessing_steps
```

## Orchestrator

```@docs
WaitingTimes.Orchestrator
WaitingTimes.Orchestrator.dataset_descriptor
WaitingTimes.Orchestrator.make_kernel
WaitingTimes.Orchestrator.estimate_memory_bytes
WaitingTimes.Orchestrator.reference_check!
WaitingTimes.Orchestrator.resolve_digits
WaitingTimes.Orchestrator.SCHEMA
WaitingTimes.Orchestrator.transient_bytes
WaitingTimes.Orchestrator.session_record
WaitingTimes.Orchestrator.write_index_files
WaitingTimes.Orchestrator.compare_with_reference
WaitingTimes.Orchestrator.reference_thresholds
WaitingTimes.Orchestrator.early_reference_check
WaitingTimes.Orchestrator.check_record
```

## Backends

```@docs
WaitingTimes.Backends
WaitingTimes.Backends.cpu_backend
```

## Synthetic

```@docs
WaitingTimes.Synthetic
```

## Kernels and streaming

```@docs
WaitingTimes.merge_gaps
WaitingTimes.compact!
WaitingTimes.DeviceWorkspace
WaitingTimes.DEVICE_LOCK
WaitingTimes.MAX_DIGITS
WaitingTimes.INT32_NARROWING_LIMIT
WaitingTimes.threshold_integer
WaitingTimes.censoring_counts
WaitingTimes.class_columns
WaitingTimes.GapEntry
WaitingTimes.gap_entries
WaitingTimes.segment_runs
WaitingTimes.run_lengths
WaitingTimes.check_gap_kind
WaitingTimes.KIND_PRECEDENCE
WaitingTimes.grid_value
WaitingTimes.MIN_COMPACTION
```
