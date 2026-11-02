#include <unistd.h>
#include <stdlib.h>
#include <stdio.h>
#include <errno.h>
#include <string.h>
#include <fcntl.h>
#include <signal.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>

static int group_fd;
static volatile sig_atomic_t interrupted;

static void on_signal(int sig)
{
	interrupted = sig;
}

static long positive_number(const char *text, long maximum)
{
	char *end;
	errno = 0;
	long value = strtol(text, &end, 10);
	if (errno || end == text || *end || value < 1 || value > maximum) {
		fprintf(stderr, "Invalid number: %s\n", text);
		exit(EXIT_FAILURE);
	}
	return value;
}

static int write_control(const char *name, const char *value)
{
	int fd = openat(group_fd, name, O_WRONLY | O_CLOEXEC);
	if (fd < 0) {
		perror(name);
		return EXIT_FAILURE;
	}
	size_t length = strlen(value);
	ssize_t written = write(fd, value, length);
	if (written < 0)
		perror(name);
	else if (written != (ssize_t)length)
		fprintf(stderr, "%s: incomplete write\n", name);
	close(fd);
	return written == (ssize_t)length ? 0 : EXIT_FAILURE;
}

static int wait_for_command(pid_t child)
{
	int status;
	for (;;) {
		pid_t done = waitpid(child, &status, WNOHANG);
		if (done == child)
			break;
		if (done < 0 && errno != EINTR) {
			perror("waitpid");
			return EXIT_FAILURE;
		}
		if (interrupted) {
			kill(child, SIGKILL);
			write_control("cgroup.kill", "1");
		}
		usleep(10000);
	}
	if (interrupted)
		return 128 + interrupted;
	if (WIFEXITED(status))
		return WEXITSTATUS(status);
	return 128 + WTERMSIG(status);
}

int main(int argc, char **argv)
{
	if (argc < 5) {
		fprintf(stderr, "Usage: %s MEMORY_MIB CPU_CORES PIDS COMMAND [ARGS...]\n",
		        argv[0]);
		return EXIT_FAILURE;
	}
	long memory = positive_number(argv[1], 1048576);
	long pids = positive_number(argv[3], 1000000);
	char *end;
	errno = 0;
	double cpu = strtod(argv[2], &end);
	if (errno || end == argv[2] || *end || !(cpu >= 0.01 && cpu <= 1024)) {
		fprintf(stderr, "CPU must be between 0.01 and 1024 cores\n");
		return EXIT_FAILURE;
	}

	char path[128], value[64];
	snprintf(path, sizeof(path), "/sys/fs/cgroup/limit-run-%ld", (long)getpid());
	if (mkdir(path, 0700)) {
		perror(path);
		return EXIT_FAILURE;
	}
	int result = EXIT_FAILURE;
	group_fd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
	if (group_fd < 0) {
		perror(path);
		rmdir(path);
		return EXIT_FAILURE;
	}
	if (faccessat(group_fd, "cgroup.kill", W_OK, 0)) {
		perror("cgroup.kill (Linux 5.14+ required)");
		goto cleanup;
	}
	snprintf(value, sizeof(value), "%llu", (unsigned long long)memory * 1024 * 1024);
	if (write_control("memory.max", value) ||
	    write_control("memory.swap.max", "0") ||
	    write_control("memory.oom.group", "1"))
		goto cleanup;
	snprintf(value, sizeof(value), "%.0f 100000", cpu * 100000);
	if (write_control("cpu.max", value))
		goto cleanup;
	snprintf(value, sizeof(value), "%ld", pids);
	if (write_control("pids.max", value))
		goto cleanup;

	struct sigaction action = {.sa_handler = on_signal};
	sigemptyset(&action.sa_mask);
	if (sigaction(SIGINT, &action, NULL) || sigaction(SIGTERM, &action, NULL)) {
		perror("sigaction");
		goto cleanup;
	}
	signal(SIGCHLD, SIG_DFL);
	struct timespec start, finish;
	clock_gettime(CLOCK_MONOTONIC, &start);
	pid_t child = fork();
	if (child < 0) {
		perror("fork");
		goto cleanup;
	}
	if (child == 0) {
		signal(SIGINT, SIG_DFL);
		signal(SIGTERM, SIG_DFL);
		if (write_control("cgroup.procs", "0"))
			_exit(EXIT_FAILURE);
		close(group_fd);
		execvp(argv[4], argv + 4);
		perror(argv[4]);
		_exit(127);
	}

	result = wait_for_command(child);
	clock_gettime(CLOCK_MONOTONIC, &finish);
	double elapsed = finish.tv_sec - start.tv_sec +
	                 (finish.tv_nsec - start.tv_nsec) / 1e9;
	fprintf(stderr, "exit=%d elapsed=%.3f\n", result, elapsed);
	if (write_control("cgroup.kill", "1"))
		result = EXIT_FAILURE;
cleanup:
	close(group_fd);
	for (size_t i = 0; i < 100; i++) {
		if (!rmdir(path))
			return result;
		if (errno != EBUSY && errno != ENOTEMPTY)
			break;
		usleep(10000);
	}
	perror(path);
	return EXIT_FAILURE;
}
