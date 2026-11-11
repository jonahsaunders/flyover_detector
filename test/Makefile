# SPDX-License-Identifier: Apache-2.0
PYTHON ?= python3

.PHONY: all clean
all:
	$(PYTHON) run.py $(if $(filter yes,$(GATES)),--gates)

clean:
	$(RM) -r sim_build results.xml
