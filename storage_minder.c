#include <errno.h>
#include <stdlib.h>
#include <unistd.h>
#include <fcntl.h>
#include <time.h>
#include <math.h>
#include <sys/statvfs.h>

#if USE_FANOTIFY
  #include <sys/fanotify.h>
#endif

/* Error Codes */
#define ERROR_MISSING_THRESHOLD                1
#define ERROR_INVALID_THRESHOLD_PERCENT        2
#define ERROR_MISSING_COOLDOWN_TIME            3
#define ERROR_INVALID_COOLDOWN_TIME            4
#define ERROR_MISSING_DRIVE_SPEED              5
#define ERROR_INVALID_DRIVE_SPEED              6
#define ERROR_MISSING_PATH_TO_CHECK            7
#define ERROR_UNABLE_TO_OPEN_PATH_TO_CHECK     8
#define ERROR_NO_FANOTIFY                      9
#define ERROR_INITIALIZING_FANOITFY           10
#define ERROR_MARKING_FANOTIFY                11
#define ERROR_WAITING_FOR_FANOTIFY            12
#define ERROR_STOPPING_FANOTIFY               13
#define ERROR_GETTING_TIME                    14
#define ERROR_WAITING_FOR_COOLDOWN            15
#define ERROR_GETTING_FS_STATS                16
#define ERROR_MISSING_CLEANUP_SCRIPT_PATH     17
#define ERROR_FORK_FAILED                     18

/* Constants */
#define TIMESPEC_EPSILON (0.5e-9)
#define NSEC_IN_SEC (1000000000L)
#define BYTES_IN_A_MB (1048576L)
#define INVALID_FD (-1)

#ifndef O_LARGEFILE
  #define O_LARGEFILE 0
#endif

#if USE_FANOTIFY
  int start_watching(int watched_path_fd, int* fanotify_fd)
  {
    errno = 0;
    int fan_fd = fanotify_init(FAN_CLASS_NOTIF, O_RDONLY | O_LARGEFILE);
    if (fan_fd == -1)
    {
      if (errno == ENOSYS)
      {
        *fanotify_fd = INVALID_FD;
        return ERROR_NO_FANOTIFY;
      }
      return ERROR_INITIALIZING_FANOITFY;
    }
    errno = 0;
    int ret = fanotify_mark(fan_fd,
                            FAN_MARK_ADD | FAN_MARK_FILESYSTEM,
                            FAN_MODIFY | FAN_CREATE | FAN_MOVED_TO,
                            watched_path_fd,
                            NULL);
    if (ret == -1)
    {
      if (errno == EPERM)
      {
        close(fan_fd);
        *fanotify_fd = INVALID_FD;
        return ERROR_NO_FANOTIFY;
      }
      return ERROR_MARKING_FANOTIFY;
    }
    *fanotify_fd = fan_fd;
    return 0;
  }
#endif

int main()
{
  double threshold;
  struct timespec cooldown;
  double drive_speed;
  int watched_path_fd;
  #if USE_FANOTIFY
    int fanotify_fd = INVALID_FD;
  #endif

  {
    char* val = getenv("FREE_SPACE_PERCENT_THRESHOLD");
    if (val == NULL)
    {
      return ERROR_MISSING_THRESHOLD;
    }

    threshold = strtod(val, NULL);
    if ((threshold > 100) || (threshold <= 0))
    {
      return ERROR_INVALID_THRESHOLD_PERCENT;
    }
  }

  {
    char* val = getenv("COOLDOWN_TIME_IN_SEC");
    if (val == NULL)
    {
      return ERROR_MISSING_COOLDOWN_TIME;
    }

    double cooldown_in_sec = strtod(val, NULL);
    if (cooldown_in_sec < 0)
    {
      return ERROR_INVALID_COOLDOWN_TIME;
    }

    cooldown_in_sec += TIMESPEC_EPSILON;
    cooldown.tv_sec = (long) cooldown_in_sec;
    cooldown.tv_nsec = (cooldown_in_sec - cooldown.tv_sec) * NSEC_IN_SEC;
  }

  {
    char* val = getenv("DRIVE_SPEED_IN_MBPS");
    if (val == NULL)
    {
      return ERROR_MISSING_DRIVE_SPEED;
    }

    drive_speed = strtod(val, NULL);
    if (drive_speed < 0)
    {
      return ERROR_INVALID_DRIVE_SPEED;
    }
  }

  {
    char* val = getenv("PATH_TO_CHECK");
    if (val == NULL)
    {
      return ERROR_MISSING_PATH_TO_CHECK;
    }

    watched_path_fd = open(val, O_RDONLY);
    if (watched_path_fd == -1)
    {
      return ERROR_UNABLE_TO_OPEN_PATH_TO_CHECK;
    }
  }

  #if USE_FANOTIFY
  {
    int ret = start_watching(watched_path_fd, &fanotify_fd);
    if ((ret != 0) && (ret != ERROR_NO_FANOTIFY))
    {
      return ret;
    }
  }
  #endif

  struct timespec next_sleep = cooldown;

  while(1)
  {
    struct timespec last_check_time;
    if (clock_gettime(CLOCK_MONOTONIC, &last_check_time) != 0)
    {
      return ERROR_GETTING_TIME;
    }

    // Check if fanotify was available
    // fallback to using polling if fanotify isn't available or
    // we don't have permission to use FAN_MARK_FILESYSTEM
    #if USE_FANOTIFY
      if (fanotify_fd != INVALID_FD)
      {
        // Wait for fanotify to trigger
        char buf[sizeof(struct fanotify_event_metadata)];
        int read_in = 0;
        while(read_in < sizeof(buf))
        {
          ssize_t ret = read(fanotify_fd, buf, sizeof(buf));
          if (ret == -1)
          {
            return ERROR_WAITING_FOR_FANOTIFY;
          }
          read_in += ret;
        }

        // Temporarily unsubscribe from notifications
        if (close(fanotify_fd) != 0)
        {
          return ERROR_STOPPING_FANOTIFY;
        }
      }
    #endif

    // Wait for the cooldown time to elapse if we were recently signaled
    // or if fanotify isn't available
    {
      #if USE_FANOTIFY
        struct timespec now;
        if (clock_gettime(CLOCK_MONOTONIC, &now) != 0)
        {
          return ERROR_GETTING_TIME;
        }

        long delta_sec = now.tv_sec - last_check_time.tv_sec;
        long delta_nsec = now.tv_nsec - last_check_time.tv_nsec;
        if (delta_nsec < 0)
        {
          --delta_sec;
          delta_nsec += NSEC_IN_SEC;
        }

        if ((delta_sec < next_sleep.tv_sec) ||
            ((delta_sec == next_sleep.tv_sec) && (delta_nsec < cooldown.tv_nsec)))
      #endif
      {
        struct timespec target_time =
        {
          last_check_time.tv_sec + next_sleep.tv_sec,
          last_check_time.tv_nsec + next_sleep.tv_nsec
        };

        int ret = 1;
        while(ret != 0)
        {
          errno = 0;
          ret = clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &target_time, NULL);
          if (ret != 0 && errno != EINTR)
          {
            return ERROR_WAITING_FOR_COOLDOWN;
          }
        }
      }
    }

    {
      // Check free disk space
      struct statvfs stats;
      if (fstatvfs(watched_path_fd, &stats) != 0)
      {
        return ERROR_GETTING_FS_STATS;
      }

      // Resubscribe to notifications if fanotify is available
      #if USE_FANOTIFY
        if (fanotify_fd != INVALID_FD)
        {
          int ret = start_watching(watched_path_fd, &fanotify_fd);
          if (ret != 0)
          {
            return ret;
          }
        }
      #endif

      // Run the cleanup script if free disk space is below the threshold
      if ((100.0*stats.f_bfree/stats.f_blocks) <= threshold)
      {
        char* cleanup_script_path = getenv("CLEANUP_SCRIPT_PATH");
        if (cleanup_script_path == NULL)
        {
          return ERROR_MISSING_CLEANUP_SCRIPT_PATH;
        }

        int ret = vfork();

        if (ret == 0)
        {
          execl(cleanup_script_path, cleanup_script_path, (char*) NULL);
        }
        else if (ret == -1)
        {
          return ERROR_FORK_FAILED;
        }
      }

      // Set next_sleep to the worst case duration
      // i.e. based on drive_speed, threshold and how much free space we
      //      currently have, sleep for the shortest time we could possibly
      //      fill the drive to the threshold
      {
        unsigned long total_bytes = stats.f_frsize * stats.f_blocks;
        unsigned long total_bytes_free = stats.f_frsize * stats.f_bfree;
        unsigned long total_bytes_free_at_threshold = threshold*total_bytes_free/100;
        unsigned long delta = total_bytes_free - total_bytes_free_at_threshold;
        if (delta > 0)
        {
          double sec_to_sleep_fraction;
          double sec_to_sleep_integer = modf(delta / (drive_speed * BYTES_IN_A_MB), &sec_to_sleep_fraction);
          next_sleep.tv_sec = sec_to_sleep_integer;
          next_sleep.tv_nsec = NSEC_IN_SEC*sec_to_sleep_fraction;
          if ((next_sleep.tv_sec < cooldown.tv_sec) ||
              ((next_sleep.tv_sec == cooldown.tv_sec) && (next_sleep.tv_nsec < cooldown.tv_nsec)))
          {
            next_sleep = cooldown;
          }
        }
        else
        {
          next_sleep = cooldown;
        }
      }
    }
  }

  return 0;
}
