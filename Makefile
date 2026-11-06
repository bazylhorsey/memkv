MODULES = memkv
EXTENSION = memkv
DATA = memkv--0.1.sql
PGFILEDESC = "memkv - key-value store in shared memory"

PG_CONFIG ?= pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
