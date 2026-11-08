#ifndef MP_EMBEDDED_H
#define MP_EMBEDDED_H
typedef int (*MPCommandHandler)(const char *, const char *, const char *);
int mp_python_initialize(const char *home, const char *resources, const char *packages, const char *executable, MPCommandHandler handler);
int mp_python_run(const char *action, const char *directory, const char *job);
const char *mp_python_error(void);
#endif
