#!/bin/bash
# shellcheck disable=SC2034
# vim: set tabstop=8 shiftwidth=8 softtabstop=8 noexpandtab:

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
	printf 'Error: %s must be sourced, not executed.\n' "${BASH_SOURCE[0]}" >&2
	exit 2
fi

BOLT_SMOKE_FLAGS=(
	'-reorder-functions=hfsort'
	'-split-functions'
	'-split-all-cold'
)

BOLT_INSTRUMENT_FLAGS=(
	'--instrument'
	'--instrument-load-profiles'
	'--instrumentation-file-append-pid'
)

BOLT_FULL_FLAGS=(
	'--reorder-functions=cdsort'
	'--reorder-blocks=ext-tsp'
	'--split-strategy=profile2'
	'--split-functions'
	'--icp=all'
	'--icp-jump-tables-targets'
	'--plt=hot'
	'--simplify-rodata-loads'
	'--frame-opt=all'
	'--frame-opt-rm-stores'
	'--experimental-shrink-wrapping'
	'--peepholes=all'
	'--hugify'
	"--huge-page-size=$(numfmt --from=auto '32Mi')"
	'--icf=safe'
	'--dyno-stats'
)
