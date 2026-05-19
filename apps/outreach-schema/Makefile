.PHONY: migrate rollback status test clean

migrate:
	dbmate up

rollback:
	dbmate rollback

status:
	dbmate status

test:
	./db/tests/run_tests.sh

clean:
	rm -f db/schema.sql
