#include "include/MPEmbedded.h"
#include <Python/Python.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>

static MPCommandHandler command_handler;
static MPWebViewHandler webview_handler;
static char error_message[4096];
static pthread_mutex_t init_lock = PTHREAD_MUTEX_INITIALIZER;

static void remember_error(void) {
    PyObject *type = NULL, *value = NULL, *trace = NULL;
    PyErr_Fetch(&type, &value, &trace);
    PyErr_NormalizeException(&type, &value, &trace);
    PyObject *text = value ? PyObject_Str(value) : NULL;
    PyObject *name = type ? PyObject_GetAttrString(type, "__name__") : NULL;
    const char *detail = text ? PyUnicode_AsUTF8(text) : NULL;
    const char *kind = name ? PyUnicode_AsUTF8(name) : "Embedded Python error";
    snprintf(error_message, sizeof(error_message), "%s: %s", kind ? kind : "Python error", detail && detail[0] ? detail : "operation failed");
    Py_XDECREF(name);
    Py_XDECREF(text); Py_XDECREF(type); Py_XDECREF(value); Py_XDECREF(trace);
}

static PyObject *execute(PyObject *self, PyObject *arguments) {
    const char *command, *out, *err;
    if (!PyArg_ParseTuple(arguments, "sss", &command, &out, &err)) return NULL;
    int result;
    Py_BEGIN_ALLOW_THREADS
    result = command_handler ? command_handler(command, out, err) : -127;
    Py_END_ALLOW_THREADS
    return PyLong_FromLong(result);
}
static PyObject *configure_webview(PyObject *self, PyObject *arguments) {
    unsigned long address;
    if (!PyArg_ParseTuple(arguments, "k", &address)) return NULL;
    Py_BEGIN_ALLOW_THREADS
    if (webview_handler) webview_handler(address);
    Py_END_ALLOW_THREADS
    Py_RETURN_NONE;
}
static PyMethodDef methods[] = {
    {"execute", execute, METH_VARARGS, "Run the linked in-process FFmpeg engine."},
    {"configure_webview", configure_webview, METH_VARARGS, "Restrict resolver navigation and playback."},
    {NULL, NULL, 0, NULL}
};
static struct PyModuleDef module = {PyModuleDef_HEAD_INIT, "_mediapocket", NULL, -1, methods};
PyMODINIT_FUNC PyInit__mediapocket(void) { return PyModule_Create(&module); }

int mp_python_initialize(const char *home, const char *resources, const char *packages, const char *executable, MPCommandHandler handler, MPWebViewHandler view_handler) {
    pthread_mutex_lock(&init_lock);
    command_handler = handler;
    webview_handler = view_handler;
    if (Py_IsInitialized()) { pthread_mutex_unlock(&init_lock); return 0; }
    PyPreConfig preconfig;
    PyPreConfig_InitIsolatedConfig(&preconfig);
    preconfig.utf8_mode = 1;
    PyStatus prestatus = Py_PreInitialize(&preconfig);
    if (PyStatus_Exception(prestatus)) {
        snprintf(error_message, sizeof(error_message), "%s", prestatus.err_msg ? prestatus.err_msg : "Python preinitialization failed");
        pthread_mutex_unlock(&init_lock); return -1;
    }
    PyImport_AppendInittab("_mediapocket", PyInit__mediapocket);
    PyConfig config;
    PyConfig_InitIsolatedConfig(&config);
    config.write_bytecode = 0;
    config.buffered_stdio = 0;
    config.install_signal_handlers = 0;
    PyStatus status = PyConfig_SetBytesString(&config, &config.home, home);
    if (!PyStatus_Exception(status)) status = PyConfig_SetBytesString(&config, &config.executable, executable);
    if (!PyStatus_Exception(status)) status = Py_InitializeFromConfig(&config);
    if (PyStatus_Exception(status)) {
        snprintf(error_message, sizeof(error_message), "%s", status.err_msg ? status.err_msg : "Python initialization failed");
        PyConfig_Clear(&config); pthread_mutex_unlock(&init_lock); return -1;
    }
    PyConfig_Clear(&config);
    PyObject *path = PySys_GetObject("path");
    PyObject *resource_path = PyUnicode_FromString(resources);
    PyObject *package_path = PyUnicode_FromString(packages);
    PyList_Insert(path, 0, resource_path); PyList_Insert(path, 0, package_path);
    Py_DECREF(resource_path); Py_DECREF(package_path);
    PyEval_SaveThread();
    pthread_mutex_unlock(&init_lock);
    return 0;
}

int mp_python_run(const char *action, const char *directory, const char *job) {
    if (!Py_IsInitialized()) return -1;
    PyGILState_STATE state = PyGILState_Ensure();
    int result = -1;
    PyObject *runner = PyImport_ImportModule("embedded_runner");
    if (runner) {
        PyObject *fn = PyObject_GetAttrString(runner, "run");
        PyObject *args = Py_BuildValue("(sss)", action, directory, job ? job : "");
        PyObject *value = fn ? PyObject_CallObject(fn, args) : NULL;
        if (value) { result = (int)PyLong_AsLong(value); Py_DECREF(value); }
        Py_XDECREF(fn); Py_DECREF(args); Py_DECREF(runner);
    }
    if (PyErr_Occurred()) remember_error();
    PyGILState_Release(state);
    return result;
}
const char *mp_python_error(void) { return error_message; }
