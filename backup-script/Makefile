.PHONY: test check

test:
	bash tests/with-userns.sh

check:
	bash -n backup.sh tests/run.sh tests/with-userns.sh
	$(MAKE) test
