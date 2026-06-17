EXTENSION   = pgtoon
EXTVERSION  = $(shell grep default_version $(EXTENSION).control | sed -e "s/default_version[[:space:]]*=[[:space:]]*'\([^']*\)'/\1/")
PG_CONFIG   = pg_config

# Set USE_PGTLE=1 to install as a Trusted Language Extension via pg_tle.
# Otherwise installs as a standard filesystem extension via PGXS.
USE_PGTLE   ?= 1

DATA        = $(wildcard *--*.sql)

ifeq (1,$(USE_PGTLE))
	# Generate and load the pg_tle install script.
	# Requires pg_tle to be installed in the target database.
	# Connection vars: PGDB, PGUSER, PGHOST, PGPORT (set via env or env.ini)
	PSQL := psql -d $(PGDB) -U $(PGUSER) -h $(PGHOST) -p $(PGPORT)

.PHONY: install uninstall clean

install:
	EXTENSION='$(EXTENSION)' ./create_pgtle_scripts.sh $(DATA)
	$(PSQL) -f .pgtle-$(EXTENSION).sql

uninstall:
	$(PSQL) -c "SELECT pgtle.uninstall_extension('$(EXTENSION)')"

clean:
	rm -rf .pgtle-$(EXTENSION).sql
else
	PGXS := $(shell $(PG_CONFIG) --pgxs)
	include $(PGXS)
endif
