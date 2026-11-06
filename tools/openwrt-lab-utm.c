/* Host-only entry point for UTM 4.7.5's bundled QEMU library. */
#include <dlfcn.h>
#include <stdio.h>

int main(int argc, const char **argv, const char **env) {
    if (argc < 3) return 2;
    void *lib = dlopen(argv[1], RTLD_LOCAL | RTLD_LAZY | RTLD_FIRST);
    if (!lib) { fprintf(stderr, "%s\n", dlerror()); return 1; }
    int (*init)(int, const char **, const char **) = dlsym(lib, "qemu_init");
    void (*run)(void) = dlsym(lib, "qemu_main_loop");
    void (*cleanup)(void) = dlsym(lib, "qemu_cleanup");
    if (!init || !run || !cleanup) return 1;
    init(argc - 1, argv + 1, env);
    run();
    cleanup();
    return 0;
}
