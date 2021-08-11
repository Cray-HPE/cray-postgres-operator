current_dir := $(shell pwd)
tmp_dir := $(shell mktemp -d)

.SILENT: helmlint eval test unittest
.PHONY: helmlint eval test unittest

all: helmlint eval unittest test

lint: helmlint eval unittest

eval:
	helm template . > $(tmp_dir)/chart.yaml
	docker run -it -v $(tmp_dir):/chart garethr/kubeval:latest --ignore-missing-schemas /chart/chart.yaml

yamllint:
	docker run -it -v $(current_dir):/chart quay.io/helmpack/chart-testing:latest yamllint -c /etc/ct/lintconf.yaml /chart

yamale:
	docker run -it -v $(current_dir):/chart quay.io/helmpack/chart-testing:latest yamale -s /etc/ct/chart_schema.yaml /chart

helmlint:
	helm lint

test:
	kubectl kuttl test --kind-config kind.yaml --artifacts-dir /tmp/kuttl

unittest:
	docker run -ti --rm -v $(current_dir):/apps quintush/helm-unittest:latest -3 .
