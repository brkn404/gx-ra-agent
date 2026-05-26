#include <errno.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
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

static void write_state(
    const char *path,
    const char *label,
    double started_at,
    unsigned long counter,
    size_t blob_mb,
    const uint8_t *blob,
    size_t blob_len,
    int stopped) {
  FILE *f = fopen(path, "w");
  if (!f) {
    return;
  }

  size_t idx = blob_len ? (counter % blob_len) : 0;
  fprintf(f, "{\n");
  fprintf(f, "  \"label\": \"%s\",\n", label);
  fprintf(f, "  \"pid\": %d,\n", getpid());
  if (!stopped) {
    fprintf(f, "  \"started_at\": %.6f,\n", started_at);
    fprintf(f, "  \"updated_at\": %.6f,\n", now_seconds());
  } else {
    fprintf(f, "  \"stopped_at\": %.6f,\n", now_seconds());
  }
  fprintf(f, "  \"counter\": %lu,\n", counter);
  fprintf(f, "  \"blob_mb\": %zu,\n", blob_mb);
  if (!stopped) {
    fprintf(f, "  \"sample_hex\": \"");
    for (size_t i = 0; i < 16 && blob_len; i++) {
      fprintf(f, "%02x", blob[(idx + i) % blob_len]);
    }
    fprintf(f, "\"\n");
  } else {
    fprintf(f, "  \"status\": \"stopped\"\n");
  }
  fprintf(f, "}\n");
  fclose(f);
}

int main(int argc, char **argv) {
  const char *state_file = NULL;
  const char *label = "timewarp-demo-c";
  size_t blob_mb = 8;
  double tick_sec = 1.0;

  for (int i = 1; i < argc; i++) {
    if (strcmp(argv[i], "--state-file") == 0 && i + 1 < argc) {
      state_file = argv[++i];
    } else if (strcmp(argv[i], "--blob-mb") == 0 && i + 1 < argc) {
      blob_mb = (size_t)strtoul(argv[++i], NULL, 10);
    } else if (strcmp(argv[i], "--tick-sec") == 0 && i + 1 < argc) {
      tick_sec = atof(argv[++i]);
    } else if (strcmp(argv[i], "--label") == 0 && i + 1 < argc) {
      label = argv[++i];
    }
  }

  if (!state_file) {
    fprintf(stderr, "--state-file is required\n");
    return 2;
  }

  signal(SIGTERM, handle_stop);
  signal(SIGINT, handle_stop);

  size_t blob_len = blob_mb * 1024 * 1024;
  if (blob_len == 0) {
    blob_len = 1024 * 1024;
    blob_mb = 1;
  }

  uint8_t *blob = malloc(blob_len);
  if (!blob) {
    fprintf(stderr, "malloc(%zu) failed: %s\n", blob_len, strerror(errno));
    return 3;
  }

  for (size_t i = 0; i < blob_len; i++) {
    blob[i] = (uint8_t)((i * 131u + 17u) % 251u);
  }

  double started_at = now_seconds();
  unsigned long counter = 0;

  while (running) {
    size_t idx = counter % blob_len;
    blob[idx] = (uint8_t)((blob[idx] + counter + 1u) % 256u);
    write_state(state_file, label, started_at, counter, blob_mb, blob, blob_len, 0);
    counter++;
    usleep((useconds_t)(tick_sec * 1000000.0));
  }

  write_state(state_file, label, started_at, counter, blob_mb, blob, blob_len, 1);
  free(blob);
  return 0;
}
