.PHONY: test check

test:
	bash tests/run.sh

check:
	bash -n backup.sh tests/run.sh
	$(MAKE) test
