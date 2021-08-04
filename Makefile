NAME ?= cray-postgres-operator
CHART_PATH ?= kubernetes
CHART_VERSION ?= local

all : chart
chart: chart_setup chart_package


chart_setup:
		mkdir -p ${CHART_PATH}/.packaged

chart_package:
		helm package ${CHART_PATH}/${NAME} -d ${CHART_PATH}/.packaged --version ${CHART_VERSION}
