#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

static volatile sig_atomic_t running = 1;

static void handle_stop(int signum) {
  (void)signum;
  running = 0;
}

static double now_seconds(void) {
  struct timeval tv;
  gettimeofday(&tv, NULL);
  return (double)tv.tv_sec + ((double)tv.tv_usec / 1000000.0);
}

static int write_all(int fd, const char *buf, size_t len) {
  size_t written = 0;
  while (written < len) {
    ssize_t rc = write(fd, buf + written, len - written);
    if (rc < 0) {
      if (errno == EINTR) {
        continue;
      }
      return -1;
    }
    written += (size_t)rc;
  }
  return 0;
}

static void write_state(
    const char *path,
    const char *label,
    double started_at,
    unsigned long counter,
    size_t blob_mb,
    const uint8_t *blob,
    size_t blob_len,
    int stopped) {
  int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
  if (fd < 0) {
    return;
  }

  char payload[1024];
  size_t used = 0;
  size_t idx = blob_len ? (counter % blob_len) : 0;
  int rc = snprintf(
      payload + used,
      sizeof(payload) - used,
      "{\n  \"label\": \"%s\",\n  \"pid\": %d,\n",
      label,
      getpid());
  if (rc < 0 || (size_t)rc >= sizeof(payload) - used) {
    close(fd);
    return;
  }
  used += (size_t)rc;

  if (!stopped) {
    rc = snprintf(
        payload + used,
        sizeof(payload) - used,
        "  \"started_at\": %.6f,\n  \"updated_at\": %.6f,\n",
        started_at,
        now_seconds());
  } else {
    rc = snprintf(
        payload + used,
        sizeof(payload) - used,
        "  \"stopped_at\": %.6f,\n",
        now_seconds());
  }
  if (rc < 0 || (size_t)rc >= sizeof(payload) - used) {
    close(fd);
    return;
  }
  used += (size_t)rc;

  rc = snprintf(
      payload + used,
      sizeof(payload) - used,
      "  \"counter\": %lu,\n  \"blob_mb\": %zu,\n",
      counter,
      blob_mb);
  if (rc < 0 || (size_t)rc >= sizeof(payload) - used) {
    close(fd);
    return;
  }
  used += (size_t)rc;

  if (!stopped) {
    rc = snprintf(payload + used, sizeof(payload) - used, "  \"sample_hex\": \"");
    if (rc < 0 || (size_t)rc >= sizeof(payload) - used) {
      close(fd);
      return;
    }
    used += (size_t)rc;
    for (size_t i = 0; i < 16 && blob_len; i++) {
      rc = snprintf(payload + used, sizeof(payload) - used, "%02x", blob[(idx + i) % blob_len]);
      if (rc < 0 || (size_t)rc >= sizeof(payload) - used) {
        close(fd);
        return;
      }
      used += (size_t)rc;
    }
    rc = snprintf(payload + used, sizeof(payload) - used, "\"\n}\n");
  } else {
    rc = snprintf(payload + used, sizeof(payload) - used, "  \"status\": \"stopped\"\n}\n");
  }
  if (rc < 0 || (size_t)rc >= sizeof(payload) - used) {
    close(fd);
    return;
  }
  used += (size_t)rc;

  (void)write_all(fd, payload, used);
  close(fd);
}

int main(int argc, char **argv) {
  const char *state_file = NULL;
  const char *label = "timewarp-demo-c";
  const char *profile = "default";
  size_t blob_mb = 8;
  double tick_sec = 1.0;
  unsigned long state_every = 1;
  int blob_mb_set = 0;
  int tick_sec_set = 0;

  for (int i = 1; i < argc; i++) {
    if (strcmp(argv[i], "--state-file") == 0 && i + 1 < argc) {
      state_file = argv[++i];
    } else if (strcmp(argv[i], "--blob-mb") == 0 && i + 1 < argc) {
      blob_mb = (size_t)strtoul(argv[++i], NULL, 10);
      blob_mb_set = 1;
    } else if (strcmp(argv[i], "--tick-sec") == 0 && i + 1 < argc) {
      tick_sec = atof(argv[++i]);
      tick_sec_set = 1;
    } else if (strcmp(argv[i], "--label") == 0 && i + 1 < argc) {
      label = argv[++i];
    } else if (strcmp(argv[i], "--profile") == 0 && i + 1 < argc) {
      profile = argv[++i];
    }
  }

  if (!state_file) {
    fprintf(stderr, "--state-file is required\n");
    return 2;
  }

  signal(SIGTERM, handle_stop);
  signal(SIGINT, handle_stop);

  if (strcmp(profile, "minimal") == 0) {
    if (!blob_mb_set) {
      blob_mb = 1;
    }
    if (!tick_sec_set) {
      tick_sec = 0.5;
    }
    state_every = 16;
  }

  size_t blob_len = blob_mb * 1024 * 1024;
  if (blob_len == 0) {
    blob_len = 1024 * 1024;
    blob_mb = 1;
  }

  uint8_t *blob = mmap(NULL, blob_len, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
  if (blob == MAP_FAILED) {
    fprintf(stderr, "mmap(%zu) failed: %s\n", blob_len, strerror(errno));
    return 3;
  }

  for (size_t i = 0; i < blob_len; i++) {
    blob[i] = (uint8_t)((i * 131u + 17u) % 251u);
  }

  double started_at = now_seconds();
  unsigned long counter = 0;

  write_state(state_file, label, started_at, counter, blob_mb, blob, blob_len, 0);
  while (running) {
    size_t idx = counter % blob_len;
    blob[idx] = (uint8_t)((blob[idx] + counter + 1u) % 256u);
    if ((counter % state_every) == 0) {
      write_state(state_file, label, started_at, counter, blob_mb, blob, blob_len, 0);
    }
    counter++;
    struct timespec req;
    req.tv_sec = (time_t)tick_sec;
    req.tv_nsec = (long)((tick_sec - (double)req.tv_sec) * 1000000000.0);
    if (req.tv_nsec < 0) {
      req.tv_nsec = 0;
    }
    nanosleep(&req, NULL);
  }

  write_state(state_file, label, started_at, counter, blob_mb, blob, blob_len, 1);
  munmap(blob, blob_len);
  return 0;
}
