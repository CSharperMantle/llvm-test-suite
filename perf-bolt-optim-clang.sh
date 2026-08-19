#!/bin/bash
# shellcheck disable=SC2329
# vim: set tabstop=8 shiftwidth=8 softtabstop=8 noexpandtab:
# SPDX-License-Identifier: GPL-3.0-or-later

LLVM_PATH="${1:?Usage: \[LD=\{bfd,lld,mold\}\] \[BASIC=\{0,1\}\] \[BUILD_JOBS=...\] \[LINK_JOBS=...\] \[RUN_JOBS=...\] \[WARMUP_RUNS=...\] \[BENCH_RUNS=...\] \[FRONTEND_RUNS=...\] \[BENCH_CPU=...\] \[RESULT_DIR=...\] $0 <LLVM_SOURCE_ROOT> \[ARTIFACT_ROOT\]}"
ARTIFACT_ROOT="${2:-"$LLVM_PATH"}"

LD="${LD:-lld}"
BASIC="${BASIC:-0}"
case "$LD" in
bfd | lld | mold)
	;;
*)
	printf 'XXX E harness: LD must be one of {bfd,lld,mold}\n' >&2
	exit 2
	;;
esac

nproc_count="$(nproc)"
bench_cpu_default="$((nproc_count - 1))"

BUILD_JOBS="${BUILD_JOBS:-"$nproc_count"}"
LINK_JOBS="${LINK_JOBS:-"$((nproc_count / 4))"}"
RUN_JOBS="${RUN_JOBS:-"$nproc_count"}"
WARMUP_RUNS="${WARMUP_RUNS:-3}"
BENCH_RUNS="${BENCH_RUNS:-15}"
FRONTEND_RUNS="${FRONTEND_RUNS:-5}"
BENCH_SEED="${BENCH_SEED:-"$((16#0d000721))"}"
BENCH_CPU="${BENCH_CPU:-"$bench_cpu_default"}"
NICE_LEVEL="${NICE_LEVEL:-15}"
MERGE_BATCH_SIZE="${MERGE_BATCH_SIZE:-256}"
KEEP_RAW_PROFILES="${KEEP_RAW_PROFILES:-1}"
SMOKE_RUNS="${SMOKE_RUNS:-3}"
RESULT_DIR="${RESULT_DIR:-"$PWD"}"
stage0_cc="${CC:-clang}"
stage0_cxx="${CXX:-clang++}"

user_cflags="${CFLAGS:-}"
user_cxxflags="${CXXFLAGS:-}"
user_ldflags="${LDFLAGS:-}"
stage_cflags="-mcmodel=medium${user_cflags:+ $user_cflags}"
stage_cxxflags="-mcmodel=medium${user_cxxflags:+ $user_cxxflags}"
stage_ldflags="${user_ldflags:+$user_ldflags }-Wl,-q"

export LC_ALL=C

if [ ! -d "$LLVM_PATH" ]; then
	printf 'XXX E harness: LLVM source root does not exist: %s\n' "$LLVM_PATH" >&2
	exit 2
fi
LLVM_PATH="$(realpath "$LLVM_PATH")"
mkdir -p "$ARTIFACT_ROOT" "$RESULT_DIR" || exit 2
ARTIFACT_ROOT="$(realpath "$ARTIFACT_ROOT")"
RESULT_DIR="$(realpath "$RESULT_DIR")"

stage1="$ARTIFACT_ROOT"/build-bolt-optim-clang-stage-1
stage2="$ARTIFACT_ROOT"/build-bolt-optim-clang-stage-2
stage3="$ARTIFACT_ROOT"/build-bolt-optim-clang-stage-3
stage4="$ARTIFACT_ROOT"/build-bolt-optim-clang-stage-4
stage5="$ARTIFACT_ROOT"/build-bolt-optim-clang-stage-5
profile_dir="$stage2"/bolt-profile
merged_profile="$profile_dir"/clang.merged.fdata

log_dir="$RESULT_DIR"/logs-clang-stage
raw_dir="$RESULT_DIR"/results-clang-raw
command_dir="$raw_dir"/commands
hyperfine_dir="$raw_dir"/hyperfine
primary_dir="$raw_dir"/primary
frontend_dir="$raw_dir"/frontend
merge_dir="$raw_dir"/profile-merge

stages_csv="$RESULT_DIR"/results-clang-stages.csv
artifacts_csv="$RESULT_DIR"/results-clang-artifacts.csv
profile_csv="$RESULT_DIR"/results-clang-profile.csv
stage1_csv="$RESULT_DIR"/results-clang-stage1-vanilla.csv
stage4_vanilla_csv="$RESULT_DIR"/results-clang-stage4-vanilla.csv
stage4_bolt_csv="$RESULT_DIR"/results-clang-stage4-bolt.csv
stage1_perf_csv="$RESULT_DIR"/results-clang-stage1-vanilla-perf.csv
stage4_vanilla_perf_csv="$RESULT_DIR"/results-clang-stage4-vanilla-perf.csv
stage4_bolt_perf_csv="$RESULT_DIR"/results-clang-stage4-bolt-perf.csv
e_log="$RESULT_DIR"/e.log

primary_events=(
	'cycles:u'
	'instructions:u'
	'branches:u'
	'branch-misses:u'
	'context-switches'
	'cpu-migrations'
	'page-faults'
)

frontend_events=(
	'l1-icache-loads:u'
	'l1-icache-load-misses:u'
	'itlb-loads:u'
	'itlb-load-misses:u'
)

benchmark_specs=(
	'isel-lowering|llvm/lib/Target/LoongArch/LoongArchISelLowering.cpp|lib/Target/LoongArch/CMakeFiles/LLVMLoongArchCodeGen.dir/LoongArchISelLowering.cpp.o'
	'dag-combiner|llvm/lib/CodeGen/SelectionDAG/DAGCombiner.cpp|lib/CodeGen/SelectionDAG/CMakeFiles/LLVMSelectionDAG.dir/DAGCombiner.cpp.o'
	'expand-pseudos|llvm/lib/Target/LoongArch/LoongArchExpandPseudoInsts.cpp|lib/Target/LoongArch/CMakeFiles/LLVMLoongArchCodeGen.dir/LoongArchExpandPseudoInsts.cpp.o'
)

stage_keys=(
	prerequisites
	stage1-build
	stage1-check-bolt
	stage2-build
	stage4-vanilla-build
	stage2-instrument
	stage3-build
	profile-merge
	stage4-bolt
	stage4-smoke
	stage5-build
	stage5-check-llvm
	stage5-check-bolt
	benchmark-commands
	benchmark-timing
	benchmark-primary
	benchmark-frontend
	output-identity
)

declare -A stage_label=(
	[prerequisites]='Prerequisites'
	[stage1-build]='Stage 1 configure/build'
	[stage1-check-bolt]='Stage 1 check-bolt'
	[stage2-build]='Stage 2 configure/build'
	[stage4-vanilla-build]='Stage 4 vanilla configure/build'
	[stage2-instrument]='Stage 2 instrumentation smoke'
	[stage3-build]='Stage 3 configure/build'
	[profile-merge]='Profile merge'
	[stage4-bolt]='Stage 4 BOLT application'
	[stage4-smoke]='Stage 4 optimized smoke'
	[stage5-build]='Stage 5 configure/build'
	[stage5-check-llvm]='Stage 5 check-llvm'
	[stage5-check-bolt]='Stage 5 check-bolt'
	[benchmark-commands]='Benchmark command acquisition'
	[benchmark-timing]='Hyperfine wall-time benchmark'
	[benchmark-primary]='Primary PMU benchmark'
	[benchmark-frontend]='Frontend benchmark'
	[output-identity]='Output identity'
)

declare -A stage_status stage_rc stage_start_ns stage_end_ns stage_wall_ns
declare -A compiler_path compiler_csv compiler_perf_csv
declare -A source_command_file source_command_hash source_benchmark_file
declare -A expected_output_hash

order=()
raw_profiles=()

timing_columns=(
	source source_path ninja_target compiler_stage compiler_path block_order
	run wall_seconds return_code output_bytes output_sha256 command_file
	command_sha256 hyperfine_json hyperfine_summary_csv stdout_log stderr_log
)

perf_columns=(
	measurement_set source source_path ninja_target compiler_stage compiler_path
	block_order run cpu return_code output_bytes output_sha256 command_file
	command_sha256 event value unit event_runtime_ns pcnt_running perf_log
	stdout_log stderr_log perf_stdout_log perf_stderr_log
)

_handle_signal() {
	trap '' INT TERM
	echo 'XXX I harness: Interrupt received, killing children...' >&2
	kill -- -"$$" 2>/dev/null || true
	exit $((128 + $1))
}
trap '_handle_signal $(kill -l INT)' INT
trap '_handle_signal $(kill -l TERM)' TERM

csv_quote() {
	local value="$1"
	value="${value//\"/\"\"}"
	printf '"%s"' "$value"
}

csv_row() {
	local file="$1"
	local separator=''
	local value
	shift
	{
		for value in "$@"; do
			printf '%s' "$separator"
			csv_quote "$value"
			separator=,
		done
		printf '\n'
	} >>"$file"
}

write_stage_csv() {
	local key
	: >"$stages_csv"
	csv_row "$stages_csv" stage status return_code start_ns end_ns wall_ns
	for key in "${stage_keys[@]}"; do
		csv_row "$stages_csv" \
			"${stage_label[$key]}" \
			"${stage_status[$key]}" \
			"${stage_rc[$key]}" \
			"${stage_start_ns[$key]}" \
			"${stage_end_ns[$key]}" \
			"${stage_wall_ns[$key]}"
	done
}

report_results() {
	local key output
	write_stage_csv
	printf -- '---\n'
	printf -- '\n'
	printf -- 'Test Results\n'
	printf -- '============\n'
	printf -- '\n'
	printf -- '\n'
	printf -- 'Stages\n'
	printf -- '------\n'
	printf -- '\n'
	for key in "${stage_keys[@]}"; do
		printf '\t%s\t%s\n' "${stage_status[$key]}" "${stage_label[$key]}"
	done
	printf -- '\n'
	printf -- '\n'
	printf -- 'Outputs\n'
	printf -- '-------\n'
	printf -- '\n'
	for output in \
		"$stage1_csv" \
		"$stage4_vanilla_csv" \
		"$stage4_bolt_csv" \
		"$stage1_perf_csv" \
		"$stage4_vanilla_perf_csv" \
		"$stage4_bolt_perf_csv" \
		"$stages_csv" \
		"$artifacts_csv" \
		"$profile_csv" \
		"$raw_dir" \
		"$log_dir"; do
		if [ -e "$output" ]; then
			printf '\t%s\n' "$output"
		fi
	done
	printf -- '\n'
	printf -- '\n'
	printf -- 'Notable entries in e.log\n'
	printf -- '------------------------\n'
	printf -- '\n'
	if [ -s "$e_log" ]; then
		grep -E '^XXX (W|E) ' "$e_log" 2>/dev/null |
			while IFS= read -r output; do
				printf '\t%s\n' "$output"
			done
	fi
	printf -- '\n'
	printf -- '---\n'
}

stage_begin() {
	local key="$1"
	stage_status[$key]=RUNNING
	stage_rc[$key]=''
	stage_start_ns[$key]="$(date +%s%N)"
	stage_end_ns[$key]=''
	stage_wall_ns[$key]=''
	write_stage_csv
	printf 'XXX I harness: %s\n' "${stage_label[$key]}" >&2
}

stage_pass() {
	local key="$1"
	stage_end_ns[$key]="$(date +%s%N)"
	stage_wall_ns[$key]="$((stage_end_ns[$key] - stage_start_ns[$key]))"
	stage_status[$key]=PASS
	stage_rc[$key]=0
	write_stage_csv
}

stage_skip() {
	local key="$1"
	local reason="$2"
	stage_start_ns[$key]="$(date +%s%N)"
	stage_end_ns[$key]="${stage_start_ns[$key]}"
	stage_wall_ns[$key]=0
	stage_status[$key]=SKIP
	stage_rc[$key]=0
	printf 'XXX W harness: %s: %s\n' "${stage_label[$key]}" "$reason" | tee -a "$e_log" >&2
	write_stage_csv
}

stage_fail() {
	local key="$1"
	local rc="$2"
	local message="$3"
	if [ -z "${stage_start_ns[$key]}" ]; then
		stage_start_ns[$key]="$(date +%s%N)"
	fi
	stage_end_ns[$key]="$(date +%s%N)"
	stage_wall_ns[$key]="$((stage_end_ns[$key] - stage_start_ns[$key]))"
	stage_status[$key]=FAIL
	stage_rc[$key]="$rc"
	printf 'XXX E harness: %s: %s\n' "${stage_label[$key]}" "$message" | tee -a "$e_log" >&2
	write_stage_csv
	report_results
	if [ "$rc" -le 0 ] || [ "$rc" -gt 255 ]; then
		rc=1
	fi
	exit "$rc"
}

configure_stage() {
	local build_dir="$1"
	local c_compiler="$2"
	local cxx_compiler="$3"
	local cxx_launcher="$4"
	local cmake_args=(
		cmake
		-S "$LLVM_PATH"/llvm
		-B "$build_dir"
		-G Ninja
		-DCMAKE_C_COMPILER="$c_compiler"
		-DCMAKE_CXX_COMPILER="$cxx_compiler"
		-DCMAKE_C_COMPILER_LAUNCHER=
		-DCMAKE_CXX_COMPILER_LAUNCHER="$cxx_launcher"
		-DCMAKE_C_FLAGS="$stage_cflags"
		-DCMAKE_CXX_FLAGS="$stage_cxxflags"
		-DCMAKE_INSTALL_PREFIX="$HOME"/.local
		-DCMAKE_BUILD_TYPE=Release
		-DLLVM_ENABLE_ASSERTIONS=ON
		-DLLVM_USE_LINKER="$LD"
		'-DLLVM_ENABLE_PROJECTS=clang;bolt;lld'
		'-DLLVM_TARGETS_TO_BUILD=X86;AArch64;LoongArch;RISCV'
		-DLLVM_CCACHE_BUILD=OFF
		-DCMAKE_EXPORT_COMPILE_COMMANDS=ON
		-DCMAKE_JOB_POOLS="link_pool=$LINK_JOBS"
		-DCMAKE_JOB_POOL_LINK=link_pool
		-DLLVM_LIT_ARGS="-sv;-j;$RUN_JOBS"
	)
	env LDFLAGS="$stage_ldflags" "${cmake_args[@]}"
}

build_stage() {
	local build_dir="$1"
	nice -n "$NICE_LEVEL" ninja -j "$BUILD_JOBS" -C "$build_dir"
}

verify_relocations() {
	local file="$1"
	readelf -SW "$file" 2>/dev/null | grep -F '.rela.text' >/dev/null
}

record_artifact() {
	local kind="$1"
	local stage="$2"
	local path="$3"
	local bytes hash
	bytes="$(stat -c %s "$path")"
	hash="$(sha256sum "$path" | awk '{print $1}')"
	csv_row "$artifacts_csv" "$kind" "$stage" "$path" "$bytes" "$hash"
}

record_profile() {
	csv_row "$profile_csv" "$@"
}

read_perf_file() {
	local file="$1"
	local counter_value counter_unit event_name event_runtime percent_running
	unset perf_value perf_unit perf_runtime perf_pcnt
	declare -gA perf_value=() perf_unit=() perf_runtime=() perf_pcnt=()
	if [ ! -r "$file" ]; then
		return 0
	fi
	while IFS=';' read -r counter_value counter_unit event_name event_runtime percent_running _; do
		case "$counter_value" in
		'' | '#'* )
			continue
			;;
		esac
		if [ -z "$event_name" ]; then
			continue
		fi
		perf_value["$event_name"]="$counter_value"
		perf_unit["$event_name"]="$counter_unit"
		perf_runtime["$event_name"]="$event_runtime"
		perf_pcnt["$event_name"]="$percent_running"
	done <"$file"
}

set_condition_order() {
	local source_index="$1"
	local round="$2"
	local permutation="$(((BENCH_SEED + source_index + round - 1) % 6))"
	case "$permutation" in
	0)
		order=(stage1-vanilla stage4-vanilla stage4-bolt)
		;;
	1)
		order=(stage1-vanilla stage4-bolt stage4-vanilla)
		;;
	2)
		order=(stage4-vanilla stage1-vanilla stage4-bolt)
		;;
	3)
		order=(stage4-vanilla stage4-bolt stage1-vanilla)
		;;
	4)
		order=(stage4-bolt stage1-vanilla stage4-vanilla)
		;;
	5)
		order=(stage4-bolt stage4-vanilla stage1-vanilla)
		;;
	esac
}

check_output_hash() {
	local source="$1"
	local hash="$2"
	if [ -z "${expected_output_hash[$source]}" ]; then
		expected_output_hash[$source]="$hash"
		return 0
	fi
	[ "${expected_output_hash[$source]}" = "$hash" ]
}

run_hyperfine_block() {
	local source="$1"
	local source_path="$2"
	local target="$3"
	local compiler_stage="$4"
	local block_order="$5"
	local compiler="${compiler_path[$compiler_stage]}"
	local csv="${compiler_csv[$compiler_stage]}"
	local command_file="${source_command_file[$source]}"
	local command_hash="${source_command_hash[$source]}"
	local benchmark_file="${source_benchmark_file[$source]}"
	local output="$stage5"/"$target"
	local log_prefix="$hyperfine_dir"/"$source"-"$compiler_stage"
	local json="$log_prefix".json
	local summary_csv="$log_prefix".csv
	local hash_log="$log_prefix".sha256
	local hyperfine_stdout="$log_prefix".hyperfine.stdout.log
	local hyperfine_stderr="$log_prefix".hyperfine.stderr.log
	local benchmark_command prepare_command conclude_command
	local expected_hash_lines hash_lines bytes hash
	local -a hashes

	printf -v benchmark_command '%q' "$hyperfine_runner"
	printf -v prepare_command '%q' "$hyperfine_prepare"
	printf -v conclude_command '%q' "$hyperfine_conclude"
	rm -f -- \
		"$json" "$summary_csv" "$hash_log" \
		"$hyperfine_stdout" "$hyperfine_stderr" \
		"$log_prefix"-*.stdout.log "$log_prefix"-*.stderr.log

	printf 'XXX I HYPERFINE: source=%s compiler=%s block=%d\n' \
		"$source" "$compiler_stage" "$block_order" >&2
	(
		cd "$stage5" || exit 125
		env \
			CLANG_BENCHMARK_COMPILER="$compiler" \
			HYPERFINE_BENCH_CPU="$BENCH_CPU" \
			HYPERFINE_COMMAND_FILE="$benchmark_file" \
			HYPERFINE_LOG_PREFIX="$log_prefix" \
			HYPERFINE_OUTPUT="$output" \
			HYPERFINE_HASH_LOG="$hash_log" \
			hyperfine \
				--style basic \
				--shell bash \
				--warmup "$WARMUP_RUNS" \
				--runs "$BENCH_RUNS" \
				--prepare "$prepare_command" \
				--conclude "$conclude_command" \
				--command-name "$source-$compiler_stage" \
				--export-json "$json" \
				--export-csv "$summary_csv" \
				"$benchmark_command"
	) > >(tee "$hyperfine_stdout") 2> >(tee "$hyperfine_stderr" >&2) || return 1

	expected_hash_lines="$((WARMUP_RUNS + BENCH_RUNS))"
	hash_lines="$(wc -l <"$hash_log")"
	if [ "$hash_lines" -ne "$expected_hash_lines" ]; then
		return 1
	fi
	mapfile -t hashes < <(awk '{print $1}' "$hash_log" | sort -u)
	if [ "${#hashes[@]}" -ne 1 ]; then
		return 2
	fi
	hash="${hashes[0]}"
	bytes="$(stat -c %s "$output")"
	if ! check_output_hash "$source" "$hash"; then
		return 2
	fi

	jq -r \
		--arg source "$source" \
		--arg source_path "$source_path" \
		--arg target "$target" \
		--arg compiler_stage "$compiler_stage" \
		--arg compiler "$compiler" \
		--arg block_order "$block_order" \
		--arg bytes "$bytes" \
		--arg hash "$hash" \
		--arg command_file "$command_file" \
		--arg command_hash "$command_hash" \
		--arg json "$json" \
		--arg summary_csv "$summary_csv" \
		--arg log_prefix "$log_prefix" \
		'.results[0] as $result |
		 range(0; ($result.times | length)) as $index |
		 [
			$source,
			$source_path,
			$target,
			$compiler_stage,
			$compiler,
			$block_order,
			($index + 1),
			$result.times[$index],
			$result.exit_codes[$index],
			$bytes,
			$hash,
			$command_file,
			$command_hash,
			$json,
			$summary_csv,
			($log_prefix + "-" + ($index | tostring) + ".stdout.log"),
			($log_prefix + "-" + ($index | tostring) + ".stderr.log")
		 ] | @csv' \
		"$json" >>"$csv" || return 1
	return 0
}

append_perf_rows() {
	local measurement_set="$1"
	local source="$2"
	local source_path="$3"
	local target="$4"
	local compiler_stage="$5"
	local block_order="$6"
	local run="$7"
	local rc="$8"
	local bytes="$9"
	shift 9
	local hash="$1"
	local command_file="$2"
	local command_hash="$3"
	local perf_log="$4"
	local stdout_log="$5"
	local stderr_log="$6"
	local perf_stdout_log="$7"
	local perf_stderr_log="$8"
	local compiler="${compiler_path[$compiler_stage]}"
	local csv="${compiler_perf_csv[$compiler_stage]}"
	local event
	local -a events

	if [ "$measurement_set" = primary ]; then
		events=("${primary_events[@]}")
	else
		events=("${frontend_events[@]}")
	fi
	for event in "${events[@]}"; do
		csv_row "$csv" \
			"$measurement_set" "$source" "$source_path" "$target" \
			"$compiler_stage" "$compiler" "$block_order" "$run" \
			"$BENCH_CPU" "$rc" "$bytes" "$hash" "$command_file" \
			"$command_hash" "$event" "${perf_value[$event]-}" \
			"${perf_unit[$event]-}" "${perf_runtime[$event]-}" \
			"${perf_pcnt[$event]-}" "$perf_log" "$stdout_log" "$stderr_log" \
			"$perf_stdout_log" "$perf_stderr_log"
	done
}

run_perf_measurement() {
	local measurement_set="$1"
	local source="$2"
	local source_path="$3"
	local target="$4"
	local run="$5"
	local block_order="$6"
	local compiler_stage="$7"
	local event_list="$8"
	local compiler="${compiler_path[$compiler_stage]}"
	local command_file="${source_command_file[$source]}"
	local command_hash="${source_command_hash[$source]}"
	local benchmark_file="${source_benchmark_file[$source]}"
	local output="$stage5"/"$target"
	local directory run_id stdout_log stderr_log perf_log
	local perf_stdout_log perf_stderr_log rc bytes hash

	if [ "$measurement_set" = primary ]; then
		directory="$primary_dir"
	else
		directory="$frontend_dir"
	fi
	run_id="${measurement_set}-${source}-${compiler_stage}-r${run}"
	stdout_log="$directory"/"$run_id".stdout.log
	stderr_log="$directory"/"$run_id".stderr.log
	perf_log="$directory"/"$run_id".perf.csv
	perf_stdout_log="$directory"/"$run_id".perf.stdout.log
	perf_stderr_log="$directory"/"$run_id".perf.stderr.log
	rm -f -- \
		"$output" "$output".d "$stdout_log" "$stderr_log" "$perf_log" \
		"$perf_stdout_log" "$perf_stderr_log"

	(
		cd "$stage5" || exit 125
		env \
			CLANG_BENCHMARK_COMPILER="$compiler" \
			PERF_COMMAND_FILE="$benchmark_file" \
			PERF_STDOUT_LOG="$stdout_log" \
			PERF_STDERR_LOG="$stderr_log" \
			perf stat --no-big-num -x ';' -o "$perf_log" \
				-e "$event_list" -- \
				taskset -c "$BENCH_CPU" "$perf_runner"
	) >"$perf_stdout_log" 2>"$perf_stderr_log"
	rc=$?
	bytes=''
	hash=''
	if [ -s "$output" ]; then
		bytes="$(stat -c %s "$output")"
		hash="$(sha256sum "$output" | awk '{print $1}')"
	fi
	read_perf_file "$perf_log"
	append_perf_rows "$measurement_set" "$source" "$source_path" "$target" \
		"$compiler_stage" "$block_order" "$run" "$rc" "$bytes" "$hash" \
		"$command_file" "$command_hash" "$perf_log" "$stdout_log" \
		"$stderr_log" "$perf_stdout_log" "$perf_stderr_log"
	if [ "$rc" -ne 0 ] || [ -z "$hash" ]; then
		return 1
	fi
	if ! check_output_hash "$source" "$hash"; then
		return 2
	fi
	return 0
}

rm -rf -- "$log_dir" "$raw_dir"
rm -f -- \
	"$stages_csv" "$artifacts_csv" "$profile_csv" \
	"$stage1_csv" "$stage4_vanilla_csv" "$stage4_bolt_csv" \
	"$stage1_perf_csv" "$stage4_vanilla_perf_csv" "$stage4_bolt_perf_csv" \
	"$e_log"
mkdir -p \
	"$log_dir" "$command_dir" "$hyperfine_dir" "$merge_dir" || exit 2
if [ "$BASIC" != 1 ]; then
	mkdir -p "$primary_dir" "$frontend_dir" || exit 2
fi
: >"$e_log"

for key in "${stage_keys[@]}"; do
	stage_status[$key]=NOTRUN
	stage_rc[$key]=''
	stage_start_ns[$key]=''
	stage_end_ns[$key]=''
	stage_wall_ns[$key]=''
done

csv_row "$artifacts_csv" kind stage path bytes sha256
csv_row "$profile_csv" kind count bytes lines sha256 path
csv_row "$stage1_csv" "${timing_columns[@]}"
csv_row "$stage4_vanilla_csv" "${timing_columns[@]}"
csv_row "$stage4_bolt_csv" "${timing_columns[@]}"
if [ "$BASIC" != 1 ]; then
	csv_row "$stage1_perf_csv" "${perf_columns[@]}"
	csv_row "$stage4_vanilla_perf_csv" "${perf_columns[@]}"
	csv_row "$stage4_bolt_perf_csv" "${perf_columns[@]}"
fi
write_stage_csv

stage_begin prerequisites
if [ ! -f "$LLVM_PATH"/llvm/CMakeLists.txt ]; then
	stage_fail prerequisites 2 "not an LLVM monorepo source root: $LLVM_PATH"
fi
if [ "$ARTIFACT_ROOT" = / ]; then
	stage_fail prerequisites 2 'ARTIFACT_ROOT must not be /'
fi
for build_dir in "$stage1" "$stage2" "$stage3" "$stage4" "$stage5"; do
	case "$RESULT_DIR"/ in
	"$build_dir"/*)
		stage_fail prerequisites 2 "RESULT_DIR must not be inside a stage directory: $build_dir"
		;;
	esac
done
if ! taskset -c "$BENCH_CPU" true >/dev/null 2>&1; then
	stage_fail prerequisites 2 "BENCH_CPU is unavailable: $BENCH_CPU"
fi
if [ "$BASIC" != 1 ]; then
	if ! taskset -c "$BENCH_CPU" perf stat -e cycles:u -- true \
		>/dev/null 2>&1; then
		stage_fail prerequisites 2 'unprivileged perf stat is unavailable'
	fi
	if [ "$FRONTEND_RUNS" -gt 0 ]; then
		frontend_event_list="$(IFS=,; printf '%s' "${frontend_events[*]}")"
		if ! taskset -c "$BENCH_CPU" perf stat -e "$frontend_event_list" -- true \
			>/dev/null 2>&1; then
			stage_fail prerequisites 2 'frontend perf events are unavailable'
		fi
	fi
fi
printf 'XXX I harness: Removing prior stage directories...\n' >&2
rm -rf -- "$stage1" "$stage2" "$stage3" "$stage4" "$stage5" ||
	stage_fail prerequisites 2 'failed to remove prior stage directories'
. ./source-bolt-flags.sh
stage_pass prerequisites

stage_begin stage1-build
if ! configure_stage "$stage1" "$stage0_cc" "$stage0_cxx" '' \
	> >(tee "$log_dir"/stage1-configure.stdout.log) \
	2> >(tee "$log_dir"/stage1-configure.stderr.log >&2); then
	stage_fail stage1-build 3 'CMake configure failed'
fi
if ! build_stage "$stage1" \
	> >(tee "$log_dir"/stage1-build.stdout.log) \
	2> >(tee "$log_dir"/stage1-build.stderr.log >&2); then
	stage_fail stage1-build 3 'Ninja build failed'
fi
for tool in clang clang++ llvm-bolt merge-fdata; do
	if [ ! -x "$stage1"/bin/"$tool" ]; then
		stage_fail stage1-build 3 "missing Stage 1 tool: $tool"
	fi
done
stage1_clang_real="$(realpath "$stage1"/bin/clang)"
if ! verify_relocations "$stage1_clang_real"; then
	stage_fail stage1-build 3 'Stage 1 Clang lacks .rela.text'
fi
record_artifact compiler stage1-vanilla "$stage1_clang_real"
stage_pass stage1-build

stage_begin stage1-check-bolt
if ! nice -n "$NICE_LEVEL" ninja -j "$BUILD_JOBS" -C "$stage1" check-bolt \
	> >(tee "$log_dir"/stage1-check-bolt.stdout.log) \
	2> >(tee "$log_dir"/stage1-check-bolt.stderr.log >&2); then
	stage_fail stage1-check-bolt 1 'check-bolt failed'
fi
stage_pass stage1-check-bolt

stage_begin stage2-build
if ! configure_stage "$stage2" "$stage1"/bin/clang "$stage1"/bin/clang++ '' \
	> >(tee "$log_dir"/stage2-configure.stdout.log) \
	2> >(tee "$log_dir"/stage2-configure.stderr.log >&2); then
	stage_fail stage2-build 3 'CMake configure failed'
fi
if ! build_stage "$stage2" \
	> >(tee "$log_dir"/stage2-build.stdout.log) \
	2> >(tee "$log_dir"/stage2-build.stderr.log >&2); then
	stage_fail stage2-build 3 'Ninja build failed'
fi
stage2_clang_real="$(realpath "$stage2"/bin/clang)"
cp --reflink=auto -- "$stage2_clang_real" "$stage2_clang_real".stage2-vanilla ||
	stage_fail stage2-build 3 'failed to preserve independently built Stage 2 Clang'
record_artifact compiler stage2-independent-vanilla "$stage2_clang_real".stage2-vanilla
stage_pass stage2-build

stage_begin stage4-vanilla-build
if ! configure_stage "$stage4" "$stage1"/bin/clang "$stage1"/bin/clang++ '' \
	> >(tee "$log_dir"/stage4-vanilla-configure.stdout.log) \
	2> >(tee "$log_dir"/stage4-vanilla-configure.stderr.log >&2); then
	stage_fail stage4-vanilla-build 3 'CMake configure failed'
fi
if ! build_stage "$stage4" \
	> >(tee "$log_dir"/stage4-vanilla-build.stdout.log) \
	2> >(tee "$log_dir"/stage4-vanilla-build.stderr.log >&2); then
	stage_fail stage4-vanilla-build 3 'Ninja build failed'
fi
stage4_clang_real="$(realpath "$stage4"/bin/clang)"
stage4_vanilla="$stage4_clang_real".vanilla
if ! verify_relocations "$stage4_clang_real"; then
	stage_fail stage4-vanilla-build 3 'Stage 4 vanilla Clang lacks .rela.text'
fi
cp --reflink=auto -- "$stage4_clang_real" "$stage4_vanilla" ||
	stage_fail stage4-vanilla-build 3 'failed to preserve Stage 4 vanilla Clang'
ln -sfn "$(basename "$stage4_vanilla")" "$stage4"/bin/clang++-stage4-vanilla ||
	stage_fail stage4-vanilla-build 3 'failed to create Stage 4 vanilla C++ driver'
profile_input="$stage2_clang_real".profile-input
cp --reflink=auto -- "$stage4_vanilla" "$profile_input" ||
	stage_fail stage4-vanilla-build 3 'failed to copy Stage 4 vanilla profile input'
if ! cmp -s "$stage4_vanilla" "$profile_input"; then
	stage_fail stage4-vanilla-build 3 'Stage 4 vanilla and profile input differ'
fi
record_artifact compiler stage4-vanilla "$stage4_vanilla"
record_artifact compiler stage2-profile-input "$profile_input"
stage_pass stage4-vanilla-build

stage_begin stage2-instrument
rm -rf -- "$profile_dir"
mkdir -p "$profile_dir" || stage_fail stage2-instrument 3 'failed to create profile directory'
instrumented_tmp="$stage2_clang_real".instrumented.tmp
rm -f -- "$instrumented_tmp"
if ! "$stage1"/bin/llvm-bolt "$profile_input" \
	"${BOLT_INSTRUMENT_FLAGS[@]}" \
	--instrumentation-file="$profile_dir"/clang.fdata \
	-o "$instrumented_tmp" \
	> >(tee "$log_dir"/stage2-instrument.stdout.log) \
	2> >(tee "$log_dir"/stage2-instrument.stderr.log >&2); then
	stage_fail stage2-instrument 1 'llvm-bolt instrumentation failed'
fi
if [ ! -s "$instrumented_tmp" ]; then
	stage_fail stage2-instrument 1 'instrumentation produced no output'
fi
mv -f -- "$instrumented_tmp" "$stage2_clang_real" ||
	stage_fail stage2-instrument 1 'failed to install instrumented Stage 2 Clang'
printf 'int main(void) { return 0; }\n' >"$raw_dir"/smoke.c
printf 'int main() { return 0; }\n' >"$raw_dir"/smoke.cpp
: >"$log_dir"/stage2-smoke.stdout.log
: >"$log_dir"/stage2-smoke.stderr.log
if ! "$stage2"/bin/clang -c "$raw_dir"/smoke.c -o "$raw_dir"/stage2-smoke.c.o \
	> >(tee -a "$log_dir"/stage2-smoke.stdout.log) \
	2> >(tee -a "$log_dir"/stage2-smoke.stderr.log >&2); then
	stage_fail stage2-instrument 1 'instrumented C smoke compilation failed'
fi
if ! "$stage2"/bin/clang++ -c "$raw_dir"/smoke.cpp -o "$raw_dir"/stage2-smoke.cpp.o \
	> >(tee -a "$log_dir"/stage2-smoke.stdout.log) \
	2> >(tee -a "$log_dir"/stage2-smoke.stderr.log >&2); then
	stage_fail stage2-instrument 1 'instrumented C++ smoke compilation failed'
fi
mapfile -d '' smoke_profiles < <(
	find "$profile_dir" -maxdepth 1 -type f -name 'clang.fdata.*.fdata' -print0 | sort -z
)
if [ "${#smoke_profiles[@]}" -eq 0 ]; then
	stage_fail stage2-instrument 1 'instrumented smoke tests produced no FDATA'
fi
find "$profile_dir" -maxdepth 1 -type f -delete
record_artifact compiler stage2-instrumented "$stage2_clang_real"
stage_pass stage2-instrument

stage_begin stage3-build
find "$profile_dir" -mindepth 1 -maxdepth 1 -type f -delete
if ! configure_stage "$stage3" "$stage2"/bin/clang "$stage2"/bin/clang++ '' \
	> >(tee "$log_dir"/stage3-configure.stdout.log) \
	2> >(tee "$log_dir"/stage3-configure.stderr.log >&2); then
	stage_fail stage3-build 3 'CMake configure failed'
fi
if ! build_stage "$stage3" \
	> >(tee "$log_dir"/stage3-build.stdout.log) \
	2> >(tee "$log_dir"/stage3-build.stderr.log >&2); then
	stage_fail stage3-build 3 'Ninja build failed'
fi
mapfile -d '' raw_profiles < <(
	find "$profile_dir" -maxdepth 1 -type f -name 'clang.fdata.*.fdata' -print0 | sort -z
)
if [ "${#raw_profiles[@]}" -eq 0 ]; then
	stage_fail stage3-build 1 'Stage 3 produced no raw profiles'
fi
raw_profile_bytes=0
for profile in "${raw_profiles[@]}"; do
	if [ ! -s "$profile" ]; then
		stage_fail stage3-build 1 "empty raw profile: $profile"
	fi
	raw_profile_bytes="$((raw_profile_bytes + $(stat -c %s "$profile")))"
done
record_profile raw "${#raw_profiles[@]}" "$raw_profile_bytes" '' '' "$profile_dir"
stage_pass stage3-build

stage_begin profile-merge
rm -rf -- "$merge_dir"
mkdir -p "$merge_dir" || stage_fail profile-merge 1 'failed to create merge directory'
: >"$log_dir"/profile-merge.stdout.log
: >"$log_dir"/profile-merge.stderr.log
partials=()
profile_index=0
batch_index=0
while [ "$profile_index" -lt "${#raw_profiles[@]}" ]; do
	batch_index="$((batch_index + 1))"
	partial="$merge_dir"/partial-"$(printf '%04d' "$batch_index")".fdata
	chunk=("${raw_profiles[@]:profile_index:MERGE_BATCH_SIZE}")
	if ! "$stage1"/bin/merge-fdata "${chunk[@]}" -o "$partial" \
		> >(tee -a "$log_dir"/profile-merge.stdout.log) \
		2> >(tee -a "$log_dir"/profile-merge.stderr.log >&2); then
		stage_fail profile-merge 1 "merge-fdata batch failed: $batch_index"
	fi
	if [ ! -s "$partial" ]; then
		stage_fail profile-merge 1 "empty partial profile: $partial"
	fi
	partials+=("$partial")
	profile_index="$((profile_index + ${#chunk[@]}))"
done
rm -f -- "$merged_profile"
if ! "$stage1"/bin/merge-fdata "${partials[@]}" -o "$merged_profile" \
	> >(tee -a "$log_dir"/profile-merge.stdout.log) \
	2> >(tee -a "$log_dir"/profile-merge.stderr.log >&2); then
	stage_fail profile-merge 1 'final merge-fdata failed'
fi
if [ ! -s "$merged_profile" ]; then
	stage_fail profile-merge 1 'final merged profile is empty'
fi
merged_bytes="$(stat -c %s "$merged_profile")"
merged_lines="$(wc -l <"$merged_profile")"
merged_hash="$(sha256sum "$merged_profile" | awk '{print $1}')"
record_profile merged 1 "$merged_bytes" "$merged_lines" "$merged_hash" "$merged_profile"
record_artifact profile merged-fdata "$merged_profile"
rm -f -- "${partials[@]}"
stage_pass profile-merge

stage_begin stage4-bolt
if ! cmp -s "$stage4_vanilla" "$profile_input"; then
	stage_fail stage4-bolt 1 'profile input no longer matches Stage 4 vanilla Clang'
fi
stage4_bolt_tmp="$stage4_clang_real".bolt.tmp
rm -f -- "$stage4_bolt_tmp"
if ! "$stage1"/bin/llvm-bolt "$stage4_vanilla" \
	-o "$stage4_bolt_tmp" --data "$merged_profile" \
	"${BOLT_FULL_FLAGS[@]}" \
	> >(tee "$log_dir"/stage4-bolt.stdout.log) \
	2> >(tee "$log_dir"/stage4-bolt.stderr.log >&2); then
	stage_fail stage4-bolt 1 'Stage 4 llvm-bolt application failed'
fi
if [ ! -s "$stage4_bolt_tmp" ] ||
	! file "$stage4_bolt_tmp" | grep -F ELF >/dev/null 2>&1; then
	stage_fail stage4-bolt 1 'Stage 4 BOLT output is not a nonempty ELF'
fi
if ! readelf -SW "$stage4_bolt_tmp" 2>/dev/null | grep -E '\.bolt|\.note\.bolt_info' >/dev/null; then
	stage_fail stage4-bolt 1 'Stage 4 BOLT output lacks BOLT metadata sections'
fi
mv -f -- "$stage4_bolt_tmp" "$stage4_clang_real" ||
	stage_fail stage4-bolt 1 'failed to install Stage 4 BOLT Clang'
record_artifact compiler stage4-bolt "$stage4_clang_real"
stage_pass stage4-bolt

stage_begin stage4-smoke
: >"$log_dir"/stage4-smoke.stdout.log
: >"$log_dir"/stage4-smoke.stderr.log
if ! "$stage4"/bin/clang -c "$raw_dir"/smoke.c -o "$raw_dir"/stage4-smoke.c.o \
	> >(tee -a "$log_dir"/stage4-smoke.stdout.log) \
	2> >(tee -a "$log_dir"/stage4-smoke.stderr.log >&2); then
	stage_fail stage4-smoke 1 'optimized Stage 4 C smoke compilation failed'
fi
if ! "$stage4"/bin/clang++ -c "$raw_dir"/smoke.cpp -o "$raw_dir"/stage4-smoke.cpp.o \
	> >(tee -a "$log_dir"/stage4-smoke.stdout.log) \
	2> >(tee -a "$log_dir"/stage4-smoke.stderr.log >&2); then
	stage_fail stage4-smoke 1 'optimized Stage 4 C++ smoke compilation failed'
fi
for ((smoke_index = 1; smoke_index <= SMOKE_RUNS; ++smoke_index)); do
	if ! "$stage4"/bin/clang++ --version \
		> >(tee -a "$log_dir"/stage4-smoke.stdout.log) \
		2> >(tee -a "$log_dir"/stage4-smoke.stderr.log >&2); then
		stage_fail stage4-smoke 1 "optimized Stage 4 smoke run failed: $smoke_index"
	fi
done
stage_pass stage4-smoke

bench_launcher="$command_dir"/clang-benchmark-selector.sh
cat >"$bench_launcher" <<'EOF'
#!/bin/bash
if [ -n "${CLANG_BENCHMARK_COMPILER:-}" ]; then
	compiler="$CLANG_BENCHMARK_COMPILER"
	shift
	exec "$compiler" "$@"
fi
exec "$@"
EOF
chmod +x "$bench_launcher" || exit 2

stage_begin stage5-build
if ! configure_stage \
	"$stage5" "$stage4"/bin/clang "$stage4"/bin/clang++ "$bench_launcher" \
	> >(tee "$log_dir"/stage5-configure.stdout.log) \
	2> >(tee "$log_dir"/stage5-configure.stderr.log >&2); then
	stage_fail stage5-build 3 'CMake configure failed'
fi
if ! build_stage "$stage5" \
	> >(tee "$log_dir"/stage5-build.stdout.log) \
	2> >(tee "$log_dir"/stage5-build.stderr.log >&2); then
	stage_fail stage5-build 3 'Ninja build failed'
fi
stage5_clang_real="$(realpath "$stage5"/bin/clang)"
if ! verify_relocations "$stage5_clang_real"; then
	stage_fail stage5-build 3 'Stage 5 Clang lacks .rela.text'
fi
record_artifact compiler stage5-validation "$stage5_clang_real"
stage_pass stage5-build

stage_begin stage5-check-llvm
if ! nice -n "$NICE_LEVEL" ninja -j "$BUILD_JOBS" -C "$stage5" check-llvm \
	> >(tee "$log_dir"/stage5-check-llvm.stdout.log) \
	2> >(tee "$log_dir"/stage5-check-llvm.stderr.log >&2); then
	stage_fail stage5-check-llvm 1 'check-llvm failed'
fi
stage_pass stage5-check-llvm

stage_begin stage5-check-bolt
if ! nice -n "$NICE_LEVEL" ninja -j "$BUILD_JOBS" -C "$stage5" check-bolt \
	> >(tee "$log_dir"/stage5-check-bolt.stdout.log) \
	2> >(tee "$log_dir"/stage5-check-bolt.stderr.log >&2); then
	stage_fail stage5-check-bolt 1 'check-bolt failed'
fi
stage_pass stage5-check-bolt

if [ "$KEEP_RAW_PROFILES" = 0 ]; then
	find "$profile_dir" -maxdepth 1 -type f -name 'clang.fdata.*.fdata' -delete
fi

compiler_path[stage1-vanilla]="$stage1"/bin/clang++
compiler_path[stage4-vanilla]="$stage4"/bin/clang++-stage4-vanilla
compiler_path[stage4-bolt]="$stage4"/bin/clang++
compiler_csv[stage1-vanilla]="$stage1_csv"
compiler_csv[stage4-vanilla]="$stage4_vanilla_csv"
compiler_csv[stage4-bolt]="$stage4_bolt_csv"
if [ "$BASIC" != 1 ]; then
	compiler_perf_csv[stage1-vanilla]="$stage1_perf_csv"
	compiler_perf_csv[stage4-vanilla]="$stage4_vanilla_perf_csv"
	compiler_perf_csv[stage4-bolt]="$stage4_bolt_perf_csv"
fi

hyperfine_runner="$command_dir"/hyperfine-runner.sh
cat >"$hyperfine_runner" <<'EOF'
#!/bin/bash
exec taskset -c "$HYPERFINE_BENCH_CPU" "$HYPERFINE_COMMAND_FILE" \
	>"$HYPERFINE_LOG_PREFIX-${HYPERFINE_ITERATION}.stdout.log" \
	2>"$HYPERFINE_LOG_PREFIX-${HYPERFINE_ITERATION}.stderr.log"
EOF
chmod +x "$hyperfine_runner" || exit 2

hyperfine_prepare="$command_dir"/hyperfine-prepare.sh
cat >"$hyperfine_prepare" <<'EOF'
#!/bin/bash
rm -f -- "$HYPERFINE_OUTPUT" "$HYPERFINE_OUTPUT.d"
EOF
chmod +x "$hyperfine_prepare" || exit 2

hyperfine_conclude="$command_dir"/hyperfine-conclude.sh
cat >"$hyperfine_conclude" <<'EOF'
#!/bin/bash
if [ ! -s "$HYPERFINE_OUTPUT" ]; then
	exit 1
fi
sha256sum "$HYPERFINE_OUTPUT" >>"$HYPERFINE_HASH_LOG"
EOF
chmod +x "$hyperfine_conclude" || exit 2

if [ "$BASIC" != 1 ]; then
	perf_runner="$command_dir"/perf-runner.sh
	cat >"$perf_runner" <<'EOF'
#!/bin/bash
exec "$PERF_COMMAND_FILE" >"$PERF_STDOUT_LOG" 2>"$PERF_STDERR_LOG"
EOF
	chmod +x "$perf_runner" || exit 2
fi

stage_begin benchmark-commands
for compiler_stage in stage1-vanilla stage4-vanilla stage4-bolt; do
	if [ ! -x "${compiler_path[$compiler_stage]}" ]; then
		stage_fail benchmark-commands 1 "missing benchmark compiler: ${compiler_path[$compiler_stage]}"
	fi
done
for spec in "${benchmark_specs[@]}"; do
	IFS='|' read -r source source_path target <<<"$spec"
	absolute_source="$LLVM_PATH"/"$source_path"
	command_list="$command_dir"/"$source".ninja-commands.txt
	command_error="$command_dir"/"$source".ninja-commands.stderr.log
	command_file="$command_dir"/"$source".command.sh
	benchmark_file="$command_dir"/"$source".benchmark.sh
	if ! ninja -C "$stage5" -t commands "$target" \
		>"$command_list" 2>"$command_error"; then
		stage_fail benchmark-commands 1 "failed to obtain Ninja commands for $target"
	fi
	command_line="$(tail -n 1 "$command_list")"
	if [ -z "$command_line" ]; then
		stage_fail benchmark-commands 1 "empty compiler command for $target"
	fi
	if [[ "$command_line" != *"$bench_launcher"* ]]; then
		stage_fail benchmark-commands 1 "compiler selector absent from command for $target"
	fi
	if [[ "$command_line" != *"$absolute_source"* ]]; then
		stage_fail benchmark-commands 1 "source absent from command for $target"
	fi
	if [[ "$command_line" != *"-o $target"* ]]; then
		stage_fail benchmark-commands 1 "output absent from command for $target"
	fi
	if [[ "$command_line" == *ccache* ]]; then
		stage_fail benchmark-commands 1 "ccache present in command for $target"
	fi
	printf '%s\n' "$command_line" >"$command_file"
	{
		printf '#!/bin/bash\n'
		printf '%s\n' "$command_line"
	} >"$benchmark_file"
	chmod +x "$benchmark_file" ||
		stage_fail benchmark-commands 1 "failed to create benchmark command for $source"
	source_command_file[$source]="$command_file"
	source_command_hash[$source]="$(sha256sum "$command_file" | awk '{print $1}')"
	source_benchmark_file[$source]="$benchmark_file"
	printf 'XXX I COMMAND: %s\n%s\n' "$source" "$command_line" >&2
done
stage_pass benchmark-commands

stage_begin benchmark-timing
source_index=0
for spec in "${benchmark_specs[@]}"; do
	IFS='|' read -r source source_path target <<<"$spec"
	absolute_source="$LLVM_PATH"/"$source_path"
	set_condition_order "$source_index" 1
	block_order=0
	for compiler_stage in "${order[@]}"; do
		block_order="$((block_order + 1))"
		run_hyperfine_block "$source" "$absolute_source" "$target" \
			"$compiler_stage" "$block_order"
		rc=$?
		case "$rc" in
		0)
			;;
		2)
			stage_fail benchmark-timing 1 "object hash mismatch for $source"
			;;
		*)
			stage_fail benchmark-timing 1 \
				"Hyperfine failed for $source/$compiler_stage"
			;;
		esac
	done
	source_index="$((source_index + 1))"
done
stage_pass benchmark-timing

if [ "$BASIC" = 1 ]; then
	stage_skip benchmark-primary 'BASIC=1'
	stage_skip benchmark-frontend 'BASIC=1'
else
	primary_event_list="$(IFS=,; printf '%s' "${primary_events[*]}")"
	stage_begin benchmark-primary
	source_index=0
	for spec in "${benchmark_specs[@]}"; do
		IFS='|' read -r source source_path target <<<"$spec"
		absolute_source="$LLVM_PATH"/"$source_path"
		set_condition_order "$source_index" 2
		block_order=0
		for compiler_stage in "${order[@]}"; do
			block_order="$((block_order + 1))"
			for ((run = 1; run <= BENCH_RUNS; ++run)); do
				printf 'XXX I PERF: set=primary source=%s compiler=%s block=%d run=%d\n' \
					"$source" "$compiler_stage" "$block_order" "$run" >&2
				run_perf_measurement primary "$source" "$absolute_source" "$target" \
					"$run" "$block_order" "$compiler_stage" "$primary_event_list"
				rc=$?
				case "$rc" in
				0)
					;;
				2)
					stage_fail benchmark-primary 1 "object hash mismatch for $source"
					;;
				*)
					stage_fail benchmark-primary 1 \
						"PMU measurement failed for $source/$compiler_stage"
					;;
				esac
			done
		done
		source_index="$((source_index + 1))"
	done
	stage_pass benchmark-primary

	if [ "$FRONTEND_RUNS" -eq 0 ]; then
		stage_skip benchmark-frontend 'FRONTEND_RUNS=0'
	else
		frontend_event_list="$(IFS=,; printf '%s' "${frontend_events[*]}")"
		stage_begin benchmark-frontend
		source_index=0
		for spec in "${benchmark_specs[@]}"; do
			IFS='|' read -r source source_path target <<<"$spec"
			absolute_source="$LLVM_PATH"/"$source_path"
			set_condition_order "$source_index" 3
			block_order=0
			for compiler_stage in "${order[@]}"; do
				block_order="$((block_order + 1))"
				for ((run = 1; run <= FRONTEND_RUNS; ++run)); do
					printf 'XXX I PERF: set=frontend source=%s compiler=%s block=%d run=%d\n' \
						"$source" "$compiler_stage" "$block_order" "$run" >&2
					run_perf_measurement frontend "$source" "$absolute_source" "$target" \
						"$run" "$block_order" "$compiler_stage" "$frontend_event_list"
					rc=$?
					case "$rc" in
					0)
						;;
					2)
						stage_fail benchmark-frontend 1 "object hash mismatch for $source"
						;;
					*)
						stage_fail benchmark-frontend 1 \
							"PMU measurement failed for $source/$compiler_stage"
						;;
					esac
				done
			done
			source_index="$((source_index + 1))"
		done
		stage_pass benchmark-frontend
	fi
fi

stage_begin output-identity
for spec in "${benchmark_specs[@]}"; do
	IFS='|' read -r source _ _ <<<"$spec"
	if [ -z "${expected_output_hash[$source]}" ]; then
		stage_fail output-identity 1 "no output hash recorded for $source"
	fi
done
stage_pass output-identity

report_results
exit 0
