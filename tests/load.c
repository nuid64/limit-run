#include <unistd.h>
#include <stdlib.h>
#include <stdio.h>
#include <errno.h>
#include <string.h>
#include <sys/wait.h>

static int cpu_load(void)
{
	const size_t n = 1024;
	size_t count = n * n;
	double *a = malloc(count * sizeof(*a));
	double *b = malloc(count * sizeof(*b));
	double *c = malloc(count * sizeof(*c));
	if (!a || !b || !c) {
		perror("malloc");
		free(a);
		free(b);
		free(c);
		return 1;
	}

	for (size_t i = 0; i < count; i++) {
		a[i] = i % 10;
		b[i] = (i * 3 + 1) % 10;
	}

	for (size_t i = 0; i < n; i++) {
		for (size_t j = 0; j < n; j++) {
			double sum = 0;
			for (size_t k = 0; k < n; k++)
				sum += a[i * n + k] * b[k * n + j];
			c[i * n + j] = sum;
		}
	}

	unsigned long long checksum = 0;
	for (size_t i = 0; i < count; i++)
		checksum += (unsigned long long)c[i];
	free(a);
	free(b);
	free(c);
	printf("checksum=%llu\n", checksum);
	return checksum != 21743194120ULL;
}

static int memory_load(void)
{
	size_t size = 96 * 1024 * 1024;
	volatile char *memory = malloc(size);
	if (!memory) {
		perror("malloc");
		return 1;
	}
	for (size_t i = 0; i < size; i += 4096)
		memory[i] = 1;
	puts("allocated=96MiB");
	free((void *)memory);
	return 0;
}

static int pids_load(void)
{
	int count = 0;
	int gate[2], fork_error = 0;
	pid_t children[8];

	if (pipe(gate)) {
		perror("pipe");
		return 1;
	}

	for (int i = 0; i < 8; i++) {
		pid_t pid = fork();
		if (pid < 0) {
			fork_error = errno;
			break;
		}
		if (pid == 0) {
			close(gate[1]);
			char byte;
			while (read(gate[0], &byte, 1) < 0 && errno == EINTR)
				;
			_exit(0);
		}
		children[count++] = pid;
	}

	printf("children=%d\n", count);
	if (fork_error == EAGAIN)
		puts("fork=EAGAIN");
	else if (fork_error) {
		errno = fork_error;
		perror("fork");
	} else
		puts("fork=ok");

	close(gate[0]);
	close(gate[1]);
	for (int i = 0; i < count; i++)
		while (waitpid(children[i], NULL, 0) < 0 && errno == EINTR)
			;

	return fork_error != 0;
}

int main(int argc, char **argv)
{
	if (argc == 2) {
		if (!strcmp(argv[1], "cpu"))
			return cpu_load();
		if (!strcmp(argv[1], "memory"))
			return memory_load();
		if (!strcmp(argv[1], "pids"))
			return pids_load();
	}
	fprintf(stderr, "Usage: %s cpu|memory|pids\n", argv[0]);
	return 1;
}
