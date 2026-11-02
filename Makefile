CC = clang
CFLAGS = -O2 -g -std=gnu23 -Wall -Wextra

.PHONY: all test clean

all: build/limit-run build/load

build:
	mkdir -p build

build/limit-run: src/limit_run.c | build
	$(CC) $(CFLAGS) $< -o $@

build/load: tests/load.c | build
	$(CC) $(CFLAGS) $< -o $@

test: all
	sh tests/check.sh

clean:
	rm -rf build
