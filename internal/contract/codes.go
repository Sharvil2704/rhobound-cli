// SPDX-License-Identifier: Apache-2.0

package contract

// The finding codes. This file is the only place a code string is written: other packages use these constants, and
// the registry below gives each code its level, its trigger and its fix. The tables of docs/mcp/DATA.md (sections 3.14
// and 19) are generated from All().

// Codes a capture or its store triggers (DATA.md 3.14).
const (
	StoreUnreadableObject    = "store.unreadable_object"
	StoreCompressionMismatch = "store.compression_mismatch"
	StoreManifestMismatch    = "store.manifest_mismatch"
	StoreTooLarge            = "store.too_large"
	InputTooLarge            = "input.too_large"
	StorePartitionTZOffset   = "store.partition_tz_offset"
	StoreLateBatches         = "store.late_batches"
	StoreSmallBatches        = "store.small_batches"
	StoreQueryAPIIncomplete  = "store.query_api_incomplete"

	TraceBadJSON                = "trace.bad_json"
	TraceJSONLPretty            = "trace.jsonl_pretty"
	TraceJSONArray              = "trace.json_array"
	TracePartialTailDropped     = "trace.partial_tail_dropped"
	TraceSnakeCaseKeys          = "trace.snake_case_keys"
	TracePreV1OTLP              = "trace.pre_v1_otlp"
	TraceNotOTLP                = "trace.not_otlp"
	TraceIDsBase64              = "trace.ids_base64"
	TraceTraceID64Bit           = "trace.trace_id_64bit"
	TraceIDsMixed               = "trace.ids_mixed"
	TraceKindEnumName           = "trace.kind_enum_name"
	TraceKindUnknown            = "trace.kind_unknown"
	TraceTimeNotInteger         = "trace.time_not_integer"
	TraceSpansSkipped           = "trace.spans_skipped"
	TraceServiceNameNotString   = "trace.service_name_not_string"
	TraceServiceNameDefault     = "trace.service_name_default"
	TraceMixedEnvironments      = "trace.mixed_environments"
	TraceNoServerSpans          = "trace.no_server_spans"
	TraceDuplicateSpansDropped  = "trace.duplicate_spans_dropped"
	TraceSpanIDCollision        = "trace.span_id_collision"
	TraceClientSpansMissing     = "trace.client_spans_missing"
	TraceContextNotPropagated   = "trace.context_not_propagated"
	TraceEdgeLoss               = "trace.edge_loss"
	TraceBrokenTraces           = "trace.broken_traces"
	TraceSamplingUnverified     = "trace.sampling_unverified"
	TraceSamplingMixed          = "trace.sampling_mixed"
	TraceSamplerNotProportional = "trace.sampler_not_proportional"
	TraceKeptShareConflict      = "trace.kept_share_conflict"
	TraceSamplingMinority       = "trace.sampling_minority"
	FitQueueRebuildSampled      = "fit.queue_rebuild_sampled"
	TraceRateMismatch           = "trace.rate_mismatch"
	TraceImageDigestMissing     = "trace.image_digest_missing"
	TraceMixedImages            = "trace.mixed_images"
	TraceInstancePerProcess     = "trace.instance_per_process"
	TracePodShared              = "trace.pod_shared"
	TracePodIdentityCollapsed   = "trace.pod_identity_collapsed"
	TraceFaaSService            = "trace.faas_service"
	TraceProbeLikeTraffic       = "trace.probe_like_traffic"
	TraceErrorsPresent          = "trace.errors_present"
	TraceShedding               = "trace.shedding"
	TraceRetries                = "trace.retries"
	TraceStreams                = "trace.streams"
	TraceStreamingRPC           = "trace.streaming_rpc"
	TraceLinksPresent           = "trace.links_present"
	TraceClockSkew              = "trace.clock_skew"
	TraceWholeMsStarts          = "trace.whole_ms_starts"
	TraceLoadTrend              = "trace.load_trend"
	TraceArrivalsOverdispersed  = "trace.arrivals_overdispersed"
	TraceArrivalsUnjudged       = "trace.arrivals_unjudged"
	TracePodChurn               = "trace.pod_churn"
	TraceAsyncTailTruncated     = "trace.async_tail_truncated"
	TraceWindowUnrepresentative = "trace.window_unrepresentative"
	TracePeerRenamed            = "trace.peer_renamed"
	TracePersonalDataSuspect    = "trace.personal_data_suspect"
	TraceTooFewEntries          = "trace.too_few_entries"
	TraceCycle                  = "trace.cycle"
	TraceTooManyShapes          = "trace.too_many_shapes"
	TraceNegativeServiceTime    = "trace.negative_service_time"
	ModelUtilizationObserved    = "model.utilization_observed"
	ModelUtilizationAfter       = "model.utilization_after"
	ModelBatchArrivals          = "model.batch_arrivals"
	LoadBeyondValidated         = "load.beyond_validated"
)

// Every other code (DATA.md 19).
const (
	StorePagedAPI    = "store.paged_api"
	StoreMetricsOnly = "store.metrics_only"
	StoreNotSpans    = "store.not_spans"

	ClusterNotList         = "cluster.not_list"
	ClusterUnscrubbed      = "cluster.unscrubbed"
	ClusterWindowMismatch  = "cluster.window_mismatch"
	ClusterLayoutAmbiguous = "cluster.layout_ambiguous"
	ClusterPeerMapInvalid  = "cluster.peer_map_invalid"
	ClusterDigestDisagrees = "cluster.digest_disagrees"
	ClusterTimeUnknown     = "cluster.time_unknown"
	ClusterSingleSnapshot  = "cluster.single_snapshot"

	CountWindowMismatch = "count.window_mismatch"
	CountUnknownEntry   = "count.unknown_entry"

	EnvCPUThrottled         = "env.cpu_throttled"
	FitUtilizationDisagrees = "fit.utilization_disagrees"
	FitExpired              = "fit.expired"
	FitNoBaseline           = "fit.no_baseline"
	FitVersion              = "fit.version"
	FitStale                = "fit.stale"

	ABNotConcurrent   = "ab.not_concurrent"
	ABHardwareDiffers = "ab.hardware_differs"
	ABSampled         = "ab.sampled"
	ABErrorsDiffer    = "ab.errors_differ"
	ABTooFewVisits    = "ab.too_few_visits"
	ABCountConflict   = "ab.count_conflict"

	ChangeLabelNotMinted        = "change.label_not_minted"
	ChangeUnknownService        = "change.unknown_service"
	ChangeAmbiguousService      = "change.ambiguous_service"
	ChangeNegativeTime          = "change.negative_time"
	ChangeRangeInverted         = "change.range_inverted"
	ChangeTooManyRanges         = "change.too_many_ranges"
	ChangeUnsupportedOp         = "change.unsupported_op"
	ChangeFreeText              = "change.free_text"
	ChangeCPUProfileNotOwnTime  = "change.cpu_profile_not_own_time"
	ChangeIncludesQueueing      = "change.includes_queueing"
	ChangeMicrobenchUnvalidated = "change.microbench_unvalidated"
	ChangeRouteScopeUnsupported = "change.route_scope_unsupported"
	ChangeCalleeCostAssumed     = "change.callee_cost_assumed"

	LoadBusiestUnknown = "load.busiest_unknown"

	BudgetNoPolicy = "budget.no_policy"

	PolicyNoThreshold      = "policy.no_threshold"
	PolicyBadValue         = "policy.bad_value"
	PolicyModelBandRemoved = "policy.model_band_removed"
	PolicyInlineRefused    = "policy.inline_refused"
	PolicyNotNamed         = "policy.not_named"
	PolicyUnknown          = "policy.unknown"

	GateEnforceNotEarned = "gate.enforce_not_earned"

	JudgeMsForbidden           = "judge.ms_forbidden"
	JudgeLoosening             = "judge.loosening"
	JudgePacketMismatch        = "judge.packet_mismatch"
	JudgeEvidenceUnresolved    = "judge.evidence_unresolved"
	JudgeAnswerOutsideQuestion = "judge.answer_outside_question"

	HandleExpired        = "handle.expired"
	HandleUnknown        = "handle.unknown"
	RateLimited          = "rate.limited"
	JobTimeout           = "job.timeout"
	JobFailed            = "job.failed"
	ServerEngineMismatch = "server.engine_mismatch"

	ProfileNotFound           = "profile.not_found"
	ProfileDigestUnresolvable = "profile.digest_unresolvable"
	ProfileMediaTypeParameter = "profile.media_type_parameter"
	ProfileBadSignature       = "profile.bad_signature"
	ProfileVarianceChanged    = "profile.variance_changed"
	ProfileStructureChanged   = "profile.structure_changed"
	ProfileSelfReportMismatch = "profile.self_report_mismatch"
	ProfileUntrustedSigner    = "profile.untrusted_signer"
	ProfilePredicateType      = "profile.predicate_type"
	ProfileHarnessNotAllowed  = "profile.harness_not_allowed"
	ProfileSubjectMismatch    = "profile.subject_mismatch"
	ProfileBaselineNotRunning = "profile.baseline_not_running"
	ProfileStale              = "profile.stale"
	ProfileTimeDisagrees      = "profile.time_disagrees"
	ProfileHardwareMismatch   = "profile.hardware_mismatch"
	ProfileLoadOutOfRange     = "profile.load_out_of_range"
	ProfileScopeNotMean       = "profile.scope_not_mean"
	ProfileNoVariance         = "profile.no_variance"
	ProfileTooFewVisits       = "profile.too_few_visits"
	ProfileWindowOverCap      = "profile.window_over_cap"
	ProfileLevelDrift         = "profile.level_drift"
	ProfileTransferGap        = "profile.transfer_gap"
	ProfileErrorsDiffer       = "profile.errors_differ"
	ProfileNoStructure        = "profile.no_structure"
	ProfileNoOutsideMeasure   = "profile.no_outside_measurement"
	ProfileLocationsPresent   = "profile.locations_present"
	VerifySampled             = "verify.sampled"
	VerifyDigestMismatch      = "verify.digest_mismatch"
	VerifyNotPreregistered    = "verify.not_preregistered"
	CodeNoBaseTree            = "code.no_base_tree"
	CodeBuildUnbound          = "code.build_unbound"
	CodeLanguageUnsupported   = "code.language_unsupported"
	CodeRouteKeyMissing       = "code.route_key_missing"
)

// The registry statuses: built into the first slice ("new"), an existing message given a code ("coded"), stated in
// the docs but built later ("later"), or research only ("research"). Only "new" and "coded" codes need a test.
const (
	StatusNew      = "new"
	StatusCoded    = "coded"
	StatusLater    = "later"
	StatusResearch = "research"
)

const since = "v1.0"

// Doc anchors.
const (
	data314 = "DATA.md 3.14"
	data19  = "DATA.md 19"
)

// Shared texts of the rows that DATA.md 3.14 lists together.
const (
	fixOTLPExporters  = "export with the Collector's OTLP/JSON exporters"
	fixCurrentCollect = "use a current Collector with the matching receiver"
	fixServiceName    = "set OTEL_SERVICE_NAME"
	fixSampling       = "one constant head-sampling share, or none"
	fixErrorsWindow   = "fix the errors, or capture a quiet window"
	fixClocks         = "NTP, or CLIENT spans"
	fixSteadyWindow   = "a steady window; a longer window"
	fixAsMessage      = "as the message says"
	fixWorkers        = "--workers when the count is a lower bound"
)

// registry is every code, in the order the docs list them: the trace and store codes of DATA.md 3.14, then the other
// codes of DATA.md 19.
var registry = []Code{
	// DATA.md 3.14: trigger capture
	{ID: StoreUnreadableObject, Level: Refuse, Trigger: Capture, When: "an object with a suffix the reader does not parse",
		Fix: "export with marshaler: otlp_json, compression: gzip", Today: "skipped silently"},
	{ID: StoreCompressionMismatch, Level: Refuse, Trigger: Capture, When: "a .gz object that is not gzip",
		Fix: "fix the exporter", Today: "read error"},
	{ID: StoreManifestMismatch, Level: Refuse, Trigger: Capture, When: "a file's sha256, size or count differs from the capture manifest",
		Fix: "re-fetch the window; never edit a capture in place", Today: "n/a (no manifest today)"},
	{ID: StoreTooLarge, Level: Refuse, Trigger: Capture, When: "the listing or the inflated stream passes a cap",
		Fix: "a capture over its cap: a shorter window; an object over its cap: smaller objects (rotate the Collector's " +
			"files sooner, or send smaller batches)", Today: "no limit"},
	{ID: InputTooLarge, Level: Refuse, Trigger: Capture,
		When: "the inflated stream passes a reader cap: its bytes, a line, the span count or a kept attribute value",
		Fix: "a value or a line too long: shorten it in the Collector (an OTTL truncate_all) or split the batch; " +
			"too many bytes or spans: a shorter window or smaller files", Today: "no limit"},
	{ID: StorePartitionTZOffset, Level: Refuse, Trigger: Capture, When: "partition minutes differ from span starts by whole hours",
		Fix: "set s3_partition_timezone: UTC", Today: "not detected"},
	{ID: StoreLateBatches, Level: Doubt, Trigger: Capture, When: "spans of the window found in the last margin minute",
		Fix: "raise the margin; check the Collector's export errors", Today: "not detected"},
	{ID: StoreSmallBatches, Level: Note, Trigger: Capture, When: "more than 30 [D] objects per Collector-minute; the note carries the monthly request cost",
		Fix: "raise the batch timeout to 5-10 s", Today: "not detected"},
	{ID: StoreQueryAPIIncomplete, Level: Refuse, Trigger: Capture, Status: StatusLater, When: "the source is a trace backend's search API (Tempo, Jaeger, SaaS)",
		Fix: "tee the Collector pipeline to S3 or files", Today: "n/a"},
	{ID: TraceBadJSON, Level: Refuse, Trigger: Capture, When: "an undecodable value, with file and line, from either decoder path (3.2)",
		Fix: "re-export; do not edit by hand", Today: "bad OTLP/JSON: ... or <path>: ..."},
	{ID: TraceJSONLPretty, Level: Refuse, Trigger: Capture, When: "pretty-printed values in .jsonl; one array of requests",
		Fix: "write one request per line", Today: "bad OTLP/JSON"},
	{ID: TraceJSONArray, Level: Refuse, Trigger: Capture, When: "pretty-printed values in .jsonl; one array of requests",
		Fix: "write one request per line", Today: "bad OTLP/JSON"},
	{ID: TracePartialTailDropped, Level: Note, Trigger: Capture, When: "an unterminated last line of the newest object",
		Fix: "none needed", Today: "whole capture refused"},
	{ID: TraceSnakeCaseKeys, Level: Refuse, Trigger: Capture,
		When: "resource_spans; instrumentationLibrarySpans; Jaeger UI, Zipkin or X-Ray JSON (named)", Fix: fixCurrentCollect, Today: "no usable spans"},
	{ID: TracePreV1OTLP, Level: Refuse, Trigger: Capture,
		When: "resource_spans; instrumentationLibrarySpans; Jaeger UI, Zipkin or X-Ray JSON (named)", Fix: fixCurrentCollect, Today: "no usable spans"},
	{ID: TraceNotOTLP, Level: Refuse, Trigger: Capture,
		When: "resource_spans; instrumentationLibrarySpans; Jaeger UI, Zipkin or X-Ray JSON (named)", Fix: fixCurrentCollect, Today: "no usable spans"},
	{ID: TraceIDsBase64, Level: Refuse, Trigger: Capture, When: "id encodings other than OTLP/JSON hex",
		Fix: fixOTLPExporters, Today: "every span skipped; no usable spans"},
	{ID: TraceTraceID64Bit, Level: Refuse, Trigger: Capture, When: "id encodings other than OTLP/JSON hex",
		Fix: fixOTLPExporters, Today: "every span skipped; no usable spans"},
	{ID: TraceIDsMixed, Level: Refuse, Trigger: Capture, When: "id encodings other than OTLP/JSON hex",
		Fix: fixOTLPExporters, Today: "every span skipped; no usable spans"},
	{ID: TraceKindEnumName, Level: Refuse, Trigger: Capture, When: "string span kinds",
		Fix: fixOTLPExporters, Today: "whole capture refused"},
	{ID: TraceKindUnknown, Level: Refuse, Trigger: Capture, When: "string span kinds",
		Fix: fixOTLPExporters, Today: "whole capture refused"},
	{ID: TraceTimeNotInteger, Level: Note, Trigger: Capture, When: "float or exponent times, normalized",
		Fix: "none needed", Today: "read approximately"},
	{ID: TraceSpansSkipped, Level: Doubt, Trigger: Capture, When: "more than 0.1% [D] of spans skipped for missing ids or times",
		Fix: "fix the exporter", Today: "a warning"},
	{ID: TraceServiceNameNotString, Level: Refuse, Trigger: Capture, When: "non-string or unknown_service* names",
		Fix: fixServiceName, Today: "skipped, or merged silently"},
	{ID: TraceServiceNameDefault, Level: Refuse, Trigger: Capture, When: "non-string or unknown_service* names",
		Fix: fixServiceName, Today: "skipped, or merged silently"},
	{ID: TraceMixedEnvironments, Level: Refuse, Trigger: Capture, When: "more than one deployment environment",
		Fix: "one environment per prefix", Today: "not detected"},
	{ID: TraceNoServerSpans, Level: Refuse, Trigger: Capture, Status: StatusCoded, When: "coded",
		Fix: "instrument the servers", Today: "refused"},
	{ID: TraceDuplicateSpansDropped, Level: Note, Trigger: Capture, When: "byte-identical repeats dropped",
		Fix: "none needed", Today: "misleading refusal"},
	{ID: TraceSpanIDCollision, Level: Refuse, Trigger: Capture, When: "same ids, different content",
		Fix: "find the second writer", Today: "misleading refusal"},
	{ID: TraceClientSpansMissing, Level: Doubt, Trigger: Capture, When: "per edge, more than 5% [D] of calls lack a CLIENT span",
		Fix: "enable client instrumentation", Today: "silent, 13-35% high in a test"},
	{ID: TraceContextNotPropagated, Level: Refuse, Trigger: Capture, When: "a callee whose SERVER spans are almost all roots while calls address it",
		Fix: "propagate W3C traceparent", Today: "silent double count"},
	{ID: TraceEdgeLoss, Level: Doubt, Trigger: Capture, When: "more than 1% [D] of calls on an edge lost",
		Fix: "check exporter queues and SDK drops", Today: "silent below 5%"},
	{ID: TraceBrokenTraces, Level: Refuse, Trigger: Capture, Status: StatusCoded, When: "coded: more than 5% of traces miss spans, edges named",
		Fix: fixAsMessage, Today: "refused in English"},
	{ID: TraceSamplingUnverified, Level: Doubt, Trigger: Capture, When: "no independent count and no proportional-sampler evidence",
		Fix: "supply a request count (I4)", Today: "silent"},
	{ID: TraceSamplingMixed, Level: Refuse, Trigger: Capture, When: "section 3.8", Fix: fixSampling, Today: "silent"},
	{ID: TraceSamplerNotProportional, Level: Refuse, Trigger: Capture, When: "section 3.8", Fix: fixSampling, Today: "silent"},
	{ID: TraceKeptShareConflict, Level: Refuse, Trigger: Capture, When: "section 3.8", Fix: fixSampling, Today: "silent"},
	{ID: TraceSamplingMinority, Level: Doubt, Trigger: Capture, When: "under 1% [D] of the entries carry a th other than " +
		"the dominant one, a missing th counting as one: their th is ignored (section 3.8)",
		Fix: "none needed: a th on a few entries is usually a caller's tracestate, which a ParentBased sampler keeps", Today: "silent"},
	{ID: FitQueueRebuildSampled, Level: Doubt, Trigger: Capture, When: "kept share below 1",
		Fix: "capture every request for gating windows", Today: "silent"},
	{ID: TraceRateMismatch, Level: Doubt, Trigger: Capture, When: "the trace entry rate differs from the independent count by more than 5% [D]",
		Fix: "find the dropped spans or the sampler", Today: "n/a"},
	{ID: TraceImageDigestMissing, Level: Doubt, Trigger: Capture, When: "no container.image.repo_digests on a service's resource",
		Fix: "run k8sattributes with container.image.repo_digests extracted, and keep container.id or k8s.container.name on resources " +
			"so that it can pick the container in a pod with sidecars (4.1)", Today: "n/a"},
	{ID: TraceMixedImages, Level: Refuse, Trigger: Capture, When: "two digests for one service in the window",
		Fix: "a window after the rollout settled", Today: "not detected"},
	{ID: TraceInstancePerProcess, Level: Doubt, Trigger: Capture, When: "several instance ids of one service on one host, and no pod or task identity",
		Fix: "add k8s.pod.name or aws.ecs.task.arn; or declare --pod-identity host when the processes share one listening socket", Today: "silent misread"},
	{ID: TracePodShared, Level: Doubt, Trigger: Capture, When: "one pod identity carries SERVER spans of two services",
		Fix: "if it is not a sidecar pod, fix the pod association (4.1)", Today: "silent"},
	{ID: TracePodIdentityCollapsed, Level: Refuse, Trigger: Capture, When: "one pod identity carries SERVER spans of three or more services [D]",
		Fix: "associate pods by k8s.pod.uid set upstream, or export directly (4.1)", Today: "silent misread: all pods read as one"},
	{ID: TraceFaaSService, Level: Refuse, Trigger: Capture, When: "SERVER spans from a function platform",
		Fix: "not modelled", Today: "silent misread"},
	{ID: TraceProbeLikeTraffic, Level: Doubt, Trigger: Capture, When: "probe-like routes above 1% [D] of entries",
		Fix: "declare probe routes, or filter them in the Collector", Today: "counted as user traffic"},
	{ID: TraceErrorsPresent, Level: Doubt, Trigger: Capture, When: "section 3.5", Fix: fixErrorsWindow, Today: "silent"},
	{ID: TraceShedding, Level: Doubt, Trigger: Capture, When: "section 3.5", Fix: fixErrorsWindow, Today: "silent"},
	{ID: TraceRetries, Level: Doubt, Trigger: Capture, When: "section 3.5", Fix: fixErrorsWindow, Today: "silent"},
	{ID: TraceStreams, Level: Refuse, Trigger: Capture, Status: StatusCoded, When: "coded: long spans at 5% or more of busy time",
		Fix: "cut the window by trace start", Today: "refused in English"},
	{ID: TraceStreamingRPC, Level: Refuse, Trigger: Capture, When: "message events show a stream",
		Fix: "exclude the route, or cut the window", Today: "silent"},
	{ID: TraceLinksPresent, Level: Doubt, Trigger: Capture, When: "CONSUMER spans with links",
		Fix: "none in this version", Today: "ignored"},
	{ID: TraceClockSkew, Level: Doubt, Trigger: Capture, Status: StatusCoded, When: "coded from today's warnings, plus the per-pod-pair detector",
		Fix: fixClocks, Today: "warning text"},
	{ID: TraceWholeMsStarts, Level: Doubt, Trigger: Capture, Status: StatusCoded, When: "coded from today's warnings, plus the per-pod-pair detector",
		Fix: fixClocks, Today: "warning text"},
	{ID: TraceLoadTrend, Level: Doubt, Trigger: Capture, When: "section 3.12", Fix: fixSteadyWindow, Today: "not detected"},
	{ID: TraceArrivalsOverdispersed, Level: Doubt, Trigger: Capture, When: "section 3.12", Fix: fixSteadyWindow, Today: "not detected"},
	{ID: TraceArrivalsUnjudged, Level: Doubt, Trigger: Capture, When: "section 3.12", Fix: fixSteadyWindow, Today: "not detected"},
	{ID: TracePodChurn, Level: Doubt, Trigger: Capture, When: "a pod present for part of the window",
		Fix: "a quiet window", Today: "not modelled, silent"},
	{ID: TraceAsyncTailTruncated, Level: Doubt, Trigger: Capture, When: "traces still open at the margin's end",
		Fix: "raise the margin", Today: "silent"},
	{ID: TraceWindowUnrepresentative, Level: Doubt, Trigger: Capture, Status: StatusLater,
		When: "the window's load is below the policy's minimum relative to the reference", Fix: "gate at the busiest window", Today: "n/a"},
	{ID: TracePeerRenamed, Level: Note, Trigger: Capture,
		When: "a CLIENT peer given as an address was renamed to a service from the cluster dump or the peer map (section 5)",
		Fix:  "none needed", Today: "the address stays an outside delay"},
	{ID: TracePersonalDataSuspect, Level: Doubt, Trigger: Capture,
		When: "a kept string value looks like an e-mail address, a JWT or a card number; it is masked (section 15)",
		Fix:  "tighten the privacy list in the Collector", Today: "kept as is"},
	{ID: TraceTooFewEntries, Level: Refuse, Trigger: Capture, Status: StatusCoded, When: "coded: fewer than 100 entry requests",
		Fix: "a longer window", Today: "refused in English"},
	{ID: TraceCycle, Level: Refuse, Trigger: Capture, Status: StatusCoded, When: "coded from today's refusals",
		Fix: fixAsMessage, Today: "refused in English"},
	{ID: TraceTooManyShapes, Level: Refuse, Trigger: Capture, Status: StatusCoded, When: "coded from today's refusals",
		Fix: fixAsMessage, Today: "refused in English"},
	{ID: TraceNegativeServiceTime, Level: Refuse, Trigger: Capture, Status: StatusCoded, When: "coded from today's refusals",
		Fix: fixAsMessage, Today: "refused in English"},
	{ID: ModelUtilizationObserved, Level: Refuse, Trigger: Capture, Status: StatusCoded, When: "coded from limitError",
		Fix: fixWorkers, Today: "refused in English"},
	{ID: ModelUtilizationAfter, Level: Refuse, Trigger: Capture, Status: StatusCoded, When: "coded from limitError",
		Fix: fixWorkers, Today: "refused in English"},
	{ID: ModelBatchArrivals, Level: Doubt, Trigger: Capture, Status: StatusCoded, When: "coded from today's warning",
		Fix: "none in this version", Today: "warning text"},
	{ID: LoadBeyondValidated, Level: Doubt, Trigger: Capture,
		When: "a service on a gated path above max_utilization_validated (refuse-like in enforce mode)",
		Fix:  "none: the model is untested there", Today: "n/a"},

	// DATA.md 19: every other code
	{ID: StorePagedAPI, Level: Refuse, Trigger: Input, Status: StatusLater, Doc: "DATA.md 4.4",
		When: "the source is CloudWatch aws/spans or an X-Ray retrieval API", Fix: "add an S3 exporter to the same Collector"},
	{ID: StoreMetricsOnly, Level: Refuse, Trigger: Input, Status: StatusLater, Doc: "DATA.md 4.4",
		When: "the source is Application Signals metrics", Fix: "capture spans; metrics are a verification source only"},
	{ID: StoreNotSpans, Level: Refuse, Trigger: Input, Status: StatusLater, Doc: "DATA.md 4.4",
		When: "the source is Athena results or Parquet", Fix: "export spans as OTLP/JSON"},
	{ID: ClusterNotList, Level: Refuse, Trigger: Input, Doc: "DATA.md 5",
		When: "a cluster file that is not JSON or not a Kubernetes List", Fix: "dump with kubectl get ... -o json"},
	{ID: ClusterUnscrubbed, Level: Refuse, Trigger: Input, Doc: "DATA.md 5",
		When: "secrets, ConfigMaps, env values, managedFields or the last-applied annotation in a dump",
		Fix:  "scrub the dump before it leaves the cluster"},
	{ID: ClusterWindowMismatch, Level: Refuse, Trigger: Input, Doc: "DATA.md 5",
		When: "a dump taken more than a minute [D] outside the window", Fix: "dump at the window's start and end"},
	{ID: ClusterLayoutAmbiguous, Level: Refuse, Trigger: Input, Doc: "DATA.md 5",
		When: "both a flat cluster/ folder and start/ or end/", Fix: "keep one layout"},
	{ID: ClusterPeerMapInvalid, Level: Refuse, Trigger: Input, Doc: "DATA.md 5",
		When: "an ECS peer map that does not match rhobound.peer-map/v1", Fix: "write the peer map as rhobound.peer-map/v1"},
	{ID: ClusterDigestDisagrees, Level: Doubt, Trigger: Input, Doc: "DATA.md 5",
		When: "a pod's imageID and the spans' repo_digests name different images", Fix: "a window after the rollout settled"},
	{ID: ClusterTimeUnknown, Level: Note, Trigger: Input, Doc: "DATA.md 5",
		When: "no taken_at recorded for a dump", Fix: "record taken_at in the capture manifest"},
	{ID: ClusterSingleSnapshot, Level: Note, Trigger: Input, Doc: "DATA.md 5",
		When: "a flat cluster/ folder: one snapshot for the whole window", Fix: "dump at the window's start and end"},
	{ID: CountWindowMismatch, Level: Refuse, Trigger: Input, Doc: "DATA.md 6",
		When: "the count's window edges more than 10 s [D] from the capture's", Fix: "count the capture's own window"},
	{ID: CountUnknownEntry, Level: Refuse, Trigger: Input, Doc: "DATA.md 6",
		When: "the count names an entry the capture does not have", Fix: "name entries by their service.name"},
	{ID: EnvCPUThrottled, Level: Doubt, Trigger: Input, Status: StatusLater, Doc: "DATA.md 7",
		When: "throttled periods above a threshold [D] in resource metrics", Fix: "raise the CPU limit, or capture a quieter window"},
	{ID: FitUtilizationDisagrees, Level: Doubt, Trigger: Input, Status: StatusLater, Doc: "DATA.md 7",
		When: "inferred utilization and CPU use disagree beyond a band", Fix: "check the worker counts"},
	{ID: FitExpired, Level: Refuse, Trigger: Runtime, Doc: "ARCHITECTURE.md 4.2",
		When: "a fit past its expiry", Fix: "fit a fresh window"},
	{ID: FitNoBaseline, Level: Refuse, Trigger: Runtime, Doc: "ARCHITECTURE.md 4.2, 5.8",
		When: "a call names an environment that has no baseline fit yet", Fix: "name a fit_id, or wait for the environment's first fit"},
	{ID: FitVersion, Level: Refuse, Trigger: Runtime, Doc: "ARCHITECTURE.md 4.2",
		When: "a fit or A/B record of another schema version, one whose fixed fields (the tool, digests, kept share, " +
			"findings) this version does not write, or a fit record whose bytes are not those fit wrote (serialized " +
			"again)", Fix: "fit again with this version, and store the record's bytes as fit wrote them"},
	{ID: FitStale, Level: Doubt, Trigger: Runtime, Doc: "ARCHITECTURE.md 4.2, 6.3",
		When: "a fit older than max_fit_age_h at gate time (rule token fit_stale)", Fix: "fit a fresh window"},
	{ID: ABNotConcurrent, Level: Refuse, Trigger: Input, Doc: "DATA.md 8",
		When: "A/B arms overlapping less than 90% [D]", Fix: "run both arms at the same time"},
	{ID: ABHardwareDiffers, Level: Refuse, Trigger: Input, Doc: "DATA.md 8",
		When: "A/B arms on different instance types or container resources", Fix: "one instance type and one resource spec for both arms"},
	{ID: ABSampled, Level: Refuse, Trigger: Input, Doc: "DATA.md 8",
		When: "an A/B arm whose kept share is not proven to be 1", Fix: "capture every request, with the load generator's count"},
	{ID: ABErrorsDiffer, Level: Doubt, Trigger: Input, Doc: "DATA.md 8",
		When: "error shares more than 1 point [D] apart", Fix: "fix the errors in the failing arm"},
	{ID: ABTooFewVisits, Level: Doubt, Trigger: Input, Doc: "DATA.md 8, 9.3",
		When: "fewer visits than the sizing rule needs for the gate's margin", Fix: "run each arm longer"},
	{ID: ABCountConflict, Level: Doubt, Trigger: Input, Doc: "DATA.md 8",
		When: "an A/B arm whose own request count gives a kept share other than 1, while the load generator's log, which " +
			"admits the arm, says its traces hold every request (the subject is the arm)",
		Fix: "give each arm its own request count, or none: the log alone proves an arm's kept share"},
	{ID: ChangeLabelNotMinted, Level: Refuse, Trigger: Input, Doc: "DATA.md 11.2",
		When: "a label other than declared without a record the CLI can find and recompute", Fix: "cite an A/B record the CLI computed, or label it declared"},
	{ID: ChangeUnknownService, Level: Refuse, Trigger: Input, Doc: "DATA.md 11.2",
		When: "a change or --workers names a service the fit does not have", Fix: "name a service of the fit"},
	{ID: ChangeAmbiguousService, Level: Refuse, Trigger: Input, Doc: "DATA.md 11.2",
		When: "a change or --workers names a service by a name the views show for more than one service, none of them " +
			"named so as the traces wrote it (a collision of hashes)",
		Fix: "name the service as the traces wrote it, as the services of the fit record list it"},
	{ID: ChangeNegativeTime, Level: Refuse, Trigger: Input, Doc: "DATA.md 11.2",
		When: "the change makes a time negative", Fix: "a change no larger than the time it removes"},
	{ID: ChangeRangeInverted, Level: Refuse, Trigger: Input, Doc: "DATA.md 11.2",
		When: "lo > hi", Fix: "give the range as lo <= hi"},
	{ID: ChangeTooManyRanges, Level: Refuse, Trigger: Input, Doc: "DATA.md 11.2; ARCHITECTURE.md 4.5",
		When: "more than 6 unsigned ranged items", Fix: "at most 6 unsigned ranged items"},
	{ID: ChangeUnsupportedOp, Level: Refuse, Trigger: Input, Doc: "DATA.md 11.2",
		When: "an operation this version cannot apply", Fix: "use own_ms, own_pct, workers or load_scale"},
	{ID: ChangeFreeText, Level: Refuse, Trigger: Input, Doc: "DATA.md 11.2",
		When: "a number given in prose", Fix: "give the number as a value"},
	{ID: ChangeCPUProfileNotOwnTime, Level: Refuse, Trigger: Input, Doc: "DATA.md 11.2",
		When: "a CPU profile offered as own time", Fix: "measure own time per visit (an A/B run)"},
	{ID: ChangeIncludesQueueing, Level: Refuse, Trigger: Input, Doc: "DATA.md 11.2",
		When: "a latency that already contains the queue offered as own time", Fix: "measure own time per visit (an A/B run)"},
	{ID: ChangeMicrobenchUnvalidated, Level: Refuse, Trigger: Input, Doc: "DATA.md 11.2",
		When: "a microbenchmark delta outside research use", Fix: "measure own time per visit (an A/B run)"},
	{ID: ChangeRouteScopeUnsupported, Level: Refuse, Trigger: Input, Doc: "DATA.md 11.2",
		When: "an operation restricted to a route", Fix: "convert to a per-visit mean: ms times the route's share of visits"},
	{ID: ChangeCalleeCostAssumed, Level: Doubt, Trigger: Input, Status: StatusLater, Doc: "DATA.md 11.2",
		When: "a structural operation that assumes the callee's mean visit", Fix: "measure the callee's visit for that endpoint"},
	{ID: LoadBusiestUnknown, Level: Note, Trigger: Runtime, Doc: "ARCHITECTURE.md 4.2",
		When: "no busiest-window pointer yet: evaluated at the fit's window", Fix: "none needed"},
	{ID: BudgetNoPolicy, Level: Doubt, Trigger: Input, Doc: "ARCHITECTURE.md 4.7",
		When: "a budget under no policy: no entry threshold applies, only the utilization limits bind", Fix: "name a policy (budget --policy P, or the budget tool's policy argument), so that its entry threshold binds"},
	{ID: PolicyNoThreshold, Level: Refuse, Trigger: Input, Doc: "DATA.md 13",
		When: "neither threshold key is set", Fix: "set max_entry_mean_change_pct or max_entry_mean_change_ms"},
	{ID: PolicyBadValue, Level: Refuse, Trigger: Input, Doc: "DATA.md 13",
		When: "a known key with a bad value, or an unregistered code in doubts_that_hold (exit 2)", Fix: "correct the value"},
	{ID: PolicyModelBandRemoved, Level: Refuse, Trigger: Input, Doc: "DATA.md 13",
		When: "enforce without the model band", Fix: "keep model_band when enforce is true"},
	{ID: PolicyInlineRefused, Level: Refuse, Trigger: Input, Doc: "DATA.md 13",
		When: "an inline policy from an agent", Fix: "name a policy from the server's configuration"},
	{ID: PolicyNotNamed, Level: Refuse, Trigger: Runtime, Doc: "ARCHITECTURE.md 5.8",
		When: "a budget or a prediction names no policy, and the configuration has none named default", Fix: "name a configured policy"},
	{ID: PolicyUnknown, Level: Refuse, Trigger: Runtime, Doc: "ARCHITECTURE.md 5.8",
		When: "a policy name the server's configuration does not list", Fix: "name a configured policy"},
	{ID: GateEnforceNotEarned, Level: Note, Trigger: Runtime, Doc: "ARCHITECTURE.md 6.6",
		When: "enforce: true before the readiness conditions hold (always, in the first build)", Fix: "none: the verdict is advisory"},
	{ID: JudgeMsForbidden, Level: Refuse, Trigger: Input, Doc: "DATA.md 13",
		When: "a millisecond figure in a judge answer", Fix: "answer with typed fields only"},
	{ID: JudgeLoosening, Level: Refuse, Trigger: Input, Doc: "DATA.md 13",
		When: "an answer that would relax a verdict", Fix: "answer with typed fields only"},
	{ID: JudgePacketMismatch, Level: Refuse, Trigger: Input, Doc: "DATA.md 13",
		When: "the answer cites another packet", Fix: "answer the packet that was sent"},
	{ID: JudgeEvidenceUnresolved, Level: Refuse, Trigger: Input, Doc: "DATA.md 13",
		When: "an evidence reference that is not in the packet", Fix: "cite evidence from the packet"},
	{ID: JudgeAnswerOutsideQuestion, Level: Refuse, Trigger: Input, Doc: "DATA.md 13",
		When: "a range for a question the packet did not ask, or outside its bounds", Fix: "answer the packet's questions within their bounds"},
	{ID: HandleExpired, Level: Refuse, Trigger: Runtime, Doc: "ARCHITECTURE.md 5.8",
		When: "a handle past its expiry", Fix: "start a new fit or prediction"},
	{ID: HandleUnknown, Level: Refuse, Trigger: Runtime, Doc: "ARCHITECTURE.md 5.8",
		When: "an unknown handle, or another principal's", Fix: "use a handle this principal received"},
	{ID: RateLimited, Level: Refuse, Trigger: Runtime, Doc: "ARCHITECTURE.md 5.8",
		When: "a per-principal limit was hit (retry_after_ms)", Fix: "retry after retry_after_ms"},
	{ID: JobTimeout, Level: Refuse, Trigger: Runtime, Doc: "ARCHITECTURE.md 5.5",
		When: "a job past its deadline_at", Fix: "start the job again, with a shorter window"},
	{ID: JobFailed, Level: Refuse, Trigger: Runtime, Doc: "ARCHITECTURE.md 5.5",
		When: "a job's step failed without a coded refusal: the engine exited without one, or wrote no record",
		Fix: "start the job again; if it fails again, the server's operator can run rhobound check and fit on the " +
			"capture to read the engine's message"},
	{ID: ServerEngineMismatch, Level: Refuse, Trigger: Runtime, Doc: "DEPLOY_AWS.md 2.2",
		When: "the engine binary's sha256 differs from the configured one", Fix: "install the configured engine binary"},
	{ID: ProfileNotFound, Level: Refuse, Trigger: Runtime, Doc: "DATA.md 9.5 #2",
		When: "no verified record for (baseline, candidate)", Fix: "profile the candidate, or run an A/B"},
	{ID: ProfileDigestUnresolvable, Level: Refuse, Trigger: Input, Doc: "DATA.md 9.5 #1",
		When: "a digest that cannot be resolved to the node's platform manifest", Fix: "push a platform manifest for the node's architecture"},
	{ID: ProfileMediaTypeParameter, Level: Refuse, Trigger: Input, Doc: "DATA.md 9.2",
		When: "a manifest media type with parameters (;version=)", Fix: "push media types without parameters"},
	{ID: ProfileBadSignature, Level: Refuse, Trigger: Input, Doc: "DATA.md 9.5 #3",
		When: "the signature does not verify (the first build refuses every signature)", Fix: "sign with a key on the trust list"},
	{ID: ProfileVarianceChanged, Level: Doubt, Trigger: Input, Doc: "DATA.md 8, 9.5 #15",
		When: "the own time's variance (diff-fit) or cs2 (a profile) differs beyond 2 standard errors", Fix: "none in this version: inconclusive until a variance patch exists"},
	{ID: ProfileStructureChanged, Level: Doubt, Trigger: Input, Doc: "DATA.md 8, 9.5 #14",
		When: "calls per visit differ between arms (also from diff-fit)", Fix: "describe the change structurally"},
	{ID: ProfileSelfReportMismatch, Level: Doubt, Trigger: Input, Doc: "DATA.md 8, 9.5 #16",
		When: "the outside measurement disagrees with the spans (also from diff-fit)", Fix: "check the candidate's instrumentation"},
	{ID: ProfileUntrustedSigner, Level: Refuse, Trigger: Input, Status: StatusLater, Doc: "DATA.md 9.5 #4",
		When: "the signer is not the harness identity", Fix: "sign with the harness identity"},
	{ID: ProfilePredicateType, Level: Refuse, Trigger: Input, Status: StatusLater, Doc: "DATA.md 9.5 #5",
		When: "another predicate type or version", Fix: "use the frozen predicate type"},
	{ID: ProfileHarnessNotAllowed, Level: Refuse, Trigger: Input, Status: StatusLater, Doc: "DATA.md 9.5 #6",
		When: "harness, load generator or Collector config not on the allow-list", Fix: "use an allowed harness"},
	{ID: ProfileSubjectMismatch, Level: Refuse, Trigger: Input, Status: StatusLater, Doc: "DATA.md 9.5 #7",
		When: "the subject or the baseline arm is not the expected digest", Fix: "profile the candidate about to run against the running digest"},
	{ID: ProfileBaselineNotRunning, Level: Refuse, Trigger: Input, Status: StatusLater, Doc: "DATA.md 9.5 #7",
		When: "the subject or the baseline arm is not the expected digest", Fix: "profile the candidate about to run against the running digest"},
	{ID: ProfileStale, Level: Refuse, Trigger: Input, Status: StatusLater, Doc: "DATA.md 9.5 #8",
		When: "too old, or its time disagrees with the witness row", Fix: "profile again"},
	{ID: ProfileTimeDisagrees, Level: Refuse, Trigger: Input, Status: StatusLater, Doc: "DATA.md 9.5 #8",
		When: "too old, or its time disagrees with the witness row", Fix: "profile again"},
	{ID: ProfileHardwareMismatch, Level: Refuse, Trigger: Input, Status: StatusLater, Doc: "DATA.md 9.5 #9",
		When: "instance type, CPU family, limit or container spec differ from production", Fix: "profile on production's instance type and spec"},
	{ID: ProfileLoadOutOfRange, Level: Refuse, Trigger: Input, Status: StatusLater, Doc: "DATA.md 9.5 #10",
		When: "the operating point after the change lies outside the measured levels", Fix: "measure a level at production's per-pod rate"},
	{ID: ProfileScopeNotMean, Level: Refuse, Trigger: Input, Status: StatusLater, Doc: "DATA.md 9.5 #11",
		When: "not a mean profile, or no variance", Fix: "profile the mean with its variance"},
	{ID: ProfileNoVariance, Level: Refuse, Trigger: Input, Status: StatusLater, Doc: "DATA.md 9.5 #11",
		When: "not a mean profile, or no variance", Fix: "profile the mean with its variance"},
	{ID: ProfileTooFewVisits, Level: Refuse, Trigger: Input, Status: StatusLater, Doc: "DATA.md 9.5 #12",
		When: "too few visits for the gate's margin", Fix: "measure each level longer"},
	{ID: ProfileWindowOverCap, Level: Refuse, Trigger: Input, Status: StatusLater, Doc: "DATA.md 9.3",
		When: "the sized measurement window is over the cost cap", Fix: "a wider margin, or a higher cap"},
	{ID: ProfileLevelDrift, Level: Doubt, Trigger: Input, Status: StatusLater, Doc: "DATA.md 9.5 #13",
		When: "flatness across load levels not shown", Fix: "measure at production's per-pod rate"},
	{ID: ProfileTransferGap, Level: Doubt, Trigger: Input, Status: StatusLater, Doc: "DATA.md 9.5 #17",
		When: "the harness baseline differs from production's own time", Fix: "none: the delta is given as a range over two transfer rules"},
	{ID: ProfileErrorsDiffer, Level: Doubt, Trigger: Input, Status: StatusLater, Doc: "DATA.md 9.5 #18",
		When: "error shares more than one point [D] apart", Fix: "fix the errors in the failing arm"},
	{ID: ProfileNoStructure, Level: Refuse, Trigger: Input, Doc: "DATA.md 9.2",
		When: "a profile without calls per visit per arm", Fix: "measure the calls per visit to each callee in both arms"},
	{ID: ProfileNoOutsideMeasure, Level: Refuse, Trigger: Input, Doc: "DATA.md 9.2",
		When: "a profile without the client-side latency or the cgroup CPU time per visit", Fix: "measure each arm from outside the system under test"},
	{ID: ProfileLocationsPresent, Level: Refuse, Trigger: Input, Doc: "DATA.md 9.2",
		When: "a storage location, account id or cluster ARN in a profile's predicate", Fix: "record digests only; never a location"},
	{ID: VerifySampled, Level: Refuse, Trigger: Input, Status: StatusLater, Doc: "DATA.md 12",
		When: "an after-capture that is sampled, or runs another digest", Fix: "capture every request on the deployed digest"},
	{ID: VerifyDigestMismatch, Level: Refuse, Trigger: Input, Status: StatusLater, Doc: "DATA.md 12",
		When: "an after-capture that is sampled, or runs another digest", Fix: "capture every request on the deployed digest"},
	{ID: VerifyNotPreregistered, Level: Note, Trigger: Input, Status: StatusLater, Doc: "DATA.md 12",
		When: "the prediction was not registered before the window: stored, not counted", Fix: "register the prediction before the deploy"},
	{ID: CodeNoBaseTree, Level: Refuse, Trigger: Input, Status: StatusResearch, Doc: "CODEPATHS.md 5",
		When: "code-path inputs that cannot be analysed", Fix: "supply the base tree and the build identity"},
	{ID: CodeBuildUnbound, Level: Refuse, Trigger: Input, Status: StatusResearch, Doc: "CODEPATHS.md 5",
		When: "code-path inputs that cannot be analysed", Fix: "supply the base tree and the build identity"},
	{ID: CodeLanguageUnsupported, Level: Refuse, Trigger: Input, Status: StatusResearch, Doc: "CODEPATHS.md 5",
		When: "code-path inputs that cannot be analysed", Fix: "supply the base tree and the build identity"},
	{ID: CodeRouteKeyMissing, Level: Doubt, Trigger: Input, Status: StatusResearch, Doc: "CODEPATHS.md 5",
		When: "no route key on SERVER spans: falls back to services only", Fix: "record http.route or rpc.method on SERVER spans"},
}

// numberNames are the names of the numbers a finding or a refusal of a code carries, by code: every name the engine,
// the server or its fetcher writes. A finding read from a stored record with another number is not one this registry
// makes (CheckStored), and the server shows a stored refusal's or finding's numbers only by these names. The
// data contract lists them (docs/mcp/data-contract.json, numbers).
var numberNames = map[string][]string{
	StoreUnreadableObject:    {"object", "objects"},
	StoreCompressionMismatch: {"object", "line", "value", "objects"},
	StoreManifestMismatch: {"object", "missing", "size", "unlisted", "line", "objects", "listed_bytes", "read_bytes",
		"files", "other_entries"},
	StoreTooLarge:              {"bytes", "limit", "listed_bytes", "cap_bytes", "objects"},
	InputTooLarge:              {"limit"},
	StorePartitionTZOffset:     {"derived_offset_h", "objects_sampled"},
	StoreLateBatches:           {"late_spans", "margin_after_s"},
	StoreSmallBatches:          {"objects_per_minute", "put_requests_per_month", "put_cost_usd_per_month", "threshold_objects_per_minute"},
	TraceBadJSON:               {"object", "line", "value"},
	TraceKindUnknown:           {"object", "line", "value"},
	TraceKindEnumName:          {"object"},
	TraceJSONLPretty:           {"object"},
	TraceJSONArray:             {"object"},
	TraceNotOTLP:               {"object"},
	TraceSnakeCaseKeys:         {"object"},
	TracePreV1OTLP:             {"object"},
	TraceTooFewEntries:         {"entries", "needed", "objects"},
	TraceSpansSkipped:          {"skipped", "share", "ids", "no_service", "times"},
	TraceTimeNotInteger:        {"spans"},
	TracePartialTailDropped:    {"lines"},
	TraceIDsBase64:             {"spans", "object"},
	TraceTraceID64Bit:          {"spans", "object"},
	TraceIDsMixed:              {"base64", "hex64", "hex", "object"},
	TracePersonalDataSuspect:   {"spans"},
	TraceMixedEnvironments:     {"environments"},
	TraceMixedImages:           {"digests"},
	TraceInstancePerProcess:    {"hosts", "instances_on_one_host"},
	TraceSpanIDCollision:       {"spans"},
	TraceDuplicateSpansDropped: {"spans"},
	TraceClientSpansMissing:    {"calls", "without_client_span"},
	TraceEdgeLoss:              {"calls", "lost", "share"},
	TracePeerRenamed:           {"calls"},
	TraceContextNotPropagated:  {"root_share", "calls_addressing_it", "calls_containing_it", "shuffled_baseline"},
	TraceErrorsPresent:         {"share"},
	TraceShedding:              {"share"},
	TraceRetries:               {"share"},
	TraceStreamingRPC:          {"spans"},
	TraceLinksPresent:          {"spans"},
	TraceProbeLikeTraffic:      {"share"},
	TracePodIdentityCollapsed:  {"services"},
	TracePodShared:             {"services"},
	TraceClockSkew:             {"calls", "outside_share", "max_offset_ms"},
	TraceWholeMsStarts:         {"spans"},
	TracePodChurn:              {"present_share"},
	TraceArrivalsUnjudged:      {"entries", "needed"},
	TraceArrivalsOverdispersed: {"dispersion_index", "sub_windows"},
	TraceLoadTrend:             {"second_half_over_first"},
	TraceAsyncTailTruncated:    {"share"},
	TraceSamplingMinority:      {"entries_ignored", "thresholds"},
	TraceSamplingMixed:         {"thresholds", "entries_without_th"},
	CountWindowMismatch:        {"seconds_apart"},
	TraceRateMismatch:          {"traced_entries", "counted_entries", "ratio"},
	// a conflict names the declared share and each other source's, by the source's name (KeptShare.Source)
	TraceKeptShareConflict:    {"declared", "counted", "derived_th", "assumed"},
	FitQueueRebuildSampled:    {"kept_share"},
	TraceBrokenTraces:         {"broken", "traces"},
	TraceTooManyShapes:        {"left_out_share", "limit"},
	TraceStreams:              {"busy_share"},
	ClusterLayoutAmbiguous:    {"flat_files"},
	ClusterUnscrubbed:         {"item"},
	ClusterWindowMismatch:     {"seconds_outside"},
	ClusterDigestDisagrees:    {"pods"},
	FitStale:                  {"max_fit_age_h", "fit_age_h"},
	LoadBeyondValidated:       {"utilization", "max_utilization_validated"},
	ModelUtilizationObserved:  {"utilization", "limit"},
	ModelUtilizationAfter:     {"utilization", "limit"},
	ChangeRangeInverted:       {"lo", "hi"},
	ChangeNegativeTime:        {"own_ms", "change_ms", "glue_ms"},
	ChangeTooManyRanges:       {"unsigned_ranges", "limit"},
	ABNotConcurrent:           {"overlap_share", "needed"},
	ABSampled:                 {"traced_requests", "sent"},
	ABTooFewVisits:            {"visits", "needed"},
	ABErrorsDiffer:            {"baseline", "candidate"},
	ABCountConflict:           {"kept_share", "log_share"},
	ProfileVarianceChanged:    {"cs2_delta", "cs2_se", "levels"},
	ProfileSelfReportMismatch: {"client_delta_ms", "span_delta_ms", "levels"},
	ProfileStructureChanged:   {"levels"},
	ProfileErrorsDiffer:       {"levels"},
	ProfileLevelDrift:         {"levels"},
	ProfileStale:              {"age_days", "valid_for_days"},
	ProfileTimeDisagrees:      {"seconds_apart"},
	ProfileHardwareMismatch:   {"fields"},
	ProfileLoadOutOfRange:     {"pod_rps", "measured_lo", "measured_hi", "candidate_utilization"},
	ProfileTooFewVisits:       {"arm_levels_short", "visits_needed", "margin_ms"},
	ProfileLocationsPresent:   {"fields"},
	ProfileNoVariance:         {"fields"},
	ProfileNoStructure:        {"fields"},
	ProfileNoOutsideMeasure:   {"fields"},
	ProfileScopeNotMean:       {"fields"},
	ProfilePredicateType:      {"fields"},
	RateLimited:               {"retry_after_ms"},
}

func init() {
	for i := range registry {
		c := &registry[i]
		c.Numbers = numberNames[c.ID]
		if c.Status == "" {
			c.Status = StatusNew
		}
		if c.Since == "" {
			c.Since = since
		}
		if c.Doc == "" {
			if c.Trigger == Capture {
				c.Doc = data314
			} else {
				c.Doc = data19
			}
		}
	}
}
