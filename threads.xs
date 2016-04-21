#define PERL_NO_GET_CONTEXT
#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"
/* Workaround for XSUB.h bug under WIN32 */
#ifdef WIN32
#  undef setjmp
#  if !defined(__BORLANDC__)
#    define setjmp(x) _setjmp(x)
#  endif
#endif
#ifdef HAS_PPPORT_H
#  define NEED_PL_signals
#  define NEED_newRV_noinc
#  define NEED_sv_2pv_nolen
#  include "ppport.h"
#  include "threads.h"
#endif

#ifdef USE_ITHREADS

#ifdef WIN32
#  include <windows.h>
   /* Supposed to be in Winbase.h */
#  ifndef STACK_SIZE_PARAM_IS_A_RESERVATION
#    define STACK_SIZE_PARAM_IS_A_RESERVATION 0x00010000
#  endif
#  include <win32thread.h>
#else
#  ifdef OS2
typedef perl_os_thread pthread_t;
#  else
#    include <pthread.h>
#  endif
#  include <thread.h>
#  define PERL_THREAD_SETSPECIFIC(k,v) pthread_setspecific(k,v)
#  ifdef OLD_PTHREADS_API
#    define PERL_THREAD_DETACH(t) pthread_detach(&(t))
#  else
#    define PERL_THREAD_DETACH(t) pthread_detach((t))
#  endif
#endif
#if !defined(HAS_GETPAGESIZE) && defined(I_SYS_PARAM)
#  include <sys/param.h>
#endif

/* Values for 'state' member */
#define PERL_ITHR_DETACHED              1
#define PERL_ITHR_JOINED                2
#define PERL_ITHR_FINISHED              4
#define PERL_ITHR_THREAD_EXIT_ONLY      8
#define PERL_ITHR_NONVIABLE             16
#define PERL_ITHR_DESTROYED             32

typedef struct _ithread {
    struct _ithread *next;      /* Next thread in the list */
    struct _ithread *prev;      /* Prev thread in the list */
    PerlInterpreter *interp;    /* The threads interpreter */
    UV tid;                     /* Threads module's thread id */
    perl_mutex mutex;           /* Mutex for updating things in this struct */
    int count;                  /* How many SVs have a reference to us */
    int state;                  /* Detached, joined, finished, etc. */
    int gimme;                  /* Context of create */
    SV *init_function;          /* Code to run */
    SV *params;                 /* Args to pass function */
#ifdef WIN32
    DWORD  thr;                 /* OS's idea if thread id */
    HANDLE handle;              /* OS's waitable handle */
#else
    pthread_t thr;              /* OS's handle for the thread */
#endif
    IV stack_size;
} ithread;


#define MY_CXT_KEY "threads::_cxt" XS_VERSION

typedef struct {
    /* Used by Perl interpreter for thread context switching */
    ithread *context;
} my_cxt_t;

START_MY_CXT


#define MY_POOL_KEY "threads::_pool" XS_VERSION

typedef struct {
    /* Structure for 'main' thread
     * Also forms the 'base' for the doubly-linked list of threads */
    ithread main_thread;

    /* Protects the creation and destruction of threads*/
    perl_mutex create_destruct_mutex;

    UV tid_counter;
    IV joinable_threads;
    IV running_threads;
    IV detached_threads;
    IV default_stack_size;
    IV page_size;
} my_pool_t;

#define dMY_POOL \
    SV *my_pool_sv = *hv_fetch(PL_modglobal, MY_POOL_KEY,               \
                               sizeof(MY_POOL_KEY)-1, TRUE);            \
    my_pool_t *my_poolp = INT2PTR(my_pool_t*, SvUV(my_pool_sv))

#define MY_POOL (*my_poolp)


/* Used by Perl interpreter for thread context switching */
STATIC void
S_ithread_set(pTHX_ ithread *thread)
{
    dMY_CXT;
    MY_CXT.context = thread;
}

STATIC ithread *
S_ithread_get(pTHX)
{
    dMY_CXT;
    return (MY_CXT.context);
}


/* Free any data (such as the Perl interpreter) attached to an ithread
 * structure.  This is a bit like undef on SVs, where the SV isn't freed,
 * but the PVX is.  Must be called with thread->mutex already held.
 */
STATIC void
S_ithread_clear(pTHX_ ithread *thread)
{
    PerlInterpreter *interp;

    assert(((thread->state & PERL_ITHR_FINISHED) &&
            (thread->state & (PERL_ITHR_DETACHED|PERL_ITHR_JOINED)))
                ||
           (thread->state & PERL_ITHR_NONVIABLE));

    interp = thread->interp;
    if (interp) {
        dTHXa(interp);

        PERL_SET_CONTEXT(interp);
        S_ithread_set(aTHX_ thread);

        SvREFCNT_dec(thread->params);
        thread->params = Nullsv;

        perl_destruct(interp);
        perl_free(interp);
        thread->interp = NULL;
    }

    PERL_SET_CONTEXT(aTHX);
}


/* Free an ithread structure and any attached data if its count == 0 */
STATIC void
S_ithread_destruct(pTHX_ ithread *thread)
{
    int destroy = 0;
#ifdef WIN32
    HANDLE handle;
#endif
    dMY_POOL;

    /* Determine if thread can be destroyed now */
    MUTEX_LOCK(&thread->mutex);
    if (thread->count != 0) {
        destroy = 0;
    } else if (thread->state & PERL_ITHR_DESTROYED) {
        destroy = 0;
    } else if (thread->state & PERL_ITHR_NONVIABLE) {
        thread->state |= PERL_ITHR_DESTROYED;
        destroy = 1;
    } else if (! (thread->state & PERL_ITHR_FINISHED)) {
        destroy = 0;
    } else if (! (thread->state & (PERL_ITHR_DETACHED|PERL_ITHR_JOINED))) {
        destroy = 0;
    } else {
        thread->state |= PERL_ITHR_DESTROYED;
        destroy = 1;
    }
    MUTEX_UNLOCK(&thread->mutex);
    if (! destroy) return;

    /* Main thread (0) is immortal and should never get here */
    assert(thread->tid != 0);

    /* Remove from circular list of threads */
    MUTEX_LOCK(&MY_POOL.create_destruct_mutex);
    assert(thread->prev && thread->next);
    thread->next->prev = thread->prev;
    thread->prev->next = thread->next;
    thread->next = NULL;
    thread->prev = NULL;
    MUTEX_UNLOCK(&MY_POOL.create_destruct_mutex);

    /* Thread is now disowned */
    MUTEX_LOCK(&thread->mutex);
    S_ithread_clear(aTHX_ thread);

#ifdef WIN32
    handle = thread->handle;
    thread->handle = NULL;
#endif
    MUTEX_UNLOCK(&thread->mutex);
    MUTEX_DESTROY(&thread->mutex);

#ifdef WIN32
    if (handle) {
        CloseHandle(handle);
    }
#endif

    /* Call PerlMemShared_free() in the context of the "first" interpreter
     * per http://www.nntp.perl.org/group/perl.perl5.porters/110772
     */
    aTHX = MY_POOL.main_thread.interp;
    PerlMemShared_free(thread);
}


/* Warn if exiting with any unjoined threads */
STATIC int
S_exit_warning(pTHX)
{
    int veto_cleanup;
    dMY_POOL;

    MUTEX_LOCK(&MY_POOL.create_destruct_mutex);
    veto_cleanup = (MY_POOL.running_threads || MY_POOL.joinable_threads);
    MUTEX_UNLOCK(&MY_POOL.create_destruct_mutex);

    if (veto_cleanup) {
        if (ckWARN_d(WARN_THREADS)) {
            Perl_warn(aTHX_ "Perl exited with active threads:\n\t%"
                            IVdf " running and unjoined\n\t%"
                            IVdf " finished and unjoined\n\t%"
                            IVdf " running and detached\n",
                            MY_POOL.running_threads,
                            MY_POOL.joinable_threads,
                            MY_POOL.detached_threads);
        }
    }

    return (veto_cleanup);
}

/* Called on exit from main thread */
int
Perl_ithread_hook(pTHX)
{
    dMY_POOL;
    return ((aTHX == MY_POOL.main_thread.interp) ? S_exit_warning(aTHX) : 0);
}


/* MAGIC (in mg.h sense) hooks */

int
ithread_mg_get(pTHX_ SV *sv, MAGIC *mg)
{
    ithread *thread = (ithread *)mg->mg_ptr;
    SvIV_set(sv, PTR2IV(thread));
    SvIOK_on(sv);
    return (0);
}

int
ithread_mg_free(pTHX_ SV *sv, MAGIC *mg)
{
    ithread *thread = (ithread *)mg->mg_ptr;

    MUTEX_LOCK(&thread->mutex);
    thread->count--;
    MUTEX_UNLOCK(&thread->mutex);

    /* Try to clean up thread */
    S_ithread_destruct(aTHX_ thread);

    return (0);
}

int
ithread_mg_dup(pTHX_ MAGIC *mg, CLONE_PARAMS *param)
{
    ithread *thread = (ithread *)mg->mg_ptr;
    MUTEX_LOCK(&thread->mutex);
    thread->count++;
    MUTEX_UNLOCK(&thread->mutex);
    return (0);
}

MGVTBL ithread_vtbl = {
    ithread_mg_get,     /* get */
    0,                  /* set */
    0,                  /* len */
    0,                  /* clear */
    ithread_mg_free,    /* free */
    0,                  /* copy */
    ithread_mg_dup      /* dup */
};


/* Provided default, minimum and rational stack sizes */
STATIC IV
S_good_stack_size(pTHX_ IV stack_size)
{
    dMY_POOL;

    /* Use default stack size if no stack size specified */
    if (! stack_size) {
        return (MY_POOL.default_stack_size);
    }

#ifdef PTHREAD_STACK_MIN
    /* Can't use less than minimum */
    if (stack_size < PTHREAD_STACK_MIN) {
        if (ckWARN(WARN_THREADS)) {
            Perl_warn(aTHX_ "Using minimum thread stack size of %" IVdf, (IV)PTHREAD_STACK_MIN);
        }
        return (PTHREAD_STACK_MIN);
    }
#endif

    /* Round up to page size boundary */
    if (MY_POOL.page_size <= 0) {
#if defined(HAS_SYSCONF) && (defined(_SC_PAGESIZE) || defined(_SC_MMAP_PAGE_SIZE))
        SETERRNO(0, SS_NORMAL);
#  ifdef _SC_PAGESIZE
        MY_POOL.page_size = sysconf(_SC_PAGESIZE);
#  else
        MY_POOL.page_size = sysconf(_SC_MMAP_PAGE_SIZE);
#  endif
        if ((long)MY_POOL.page_size < 0) {
            if (errno) {
                SV * const error = get_sv("@", FALSE);
                (void)SvUPGRADE(error, SVt_PV);
                Perl_croak(aTHX_ "PANIC: sysconf: %s", SvPV_nolen(error));
            } else {
                Perl_croak(aTHX_ "PANIC: sysconf: pagesize unknown");
            }
        }
#else
#  ifdef HAS_GETPAGESIZE
        MY_POOL.page_size = getpagesize();
#  else
#    if defined(I_SYS_PARAM) && defined(PAGESIZE)
        MY_POOL.page_size = PAGESIZE;
#    else
        MY_POOL.page_size = 8192;   /* A conservative default */
#    endif
#  endif
        if (MY_POOL.page_size <= 0) {
            Perl_croak(aTHX_ "PANIC: bad pagesize %" IVdf, (IV)MY_POOL.page_size);
        }
#endif
    }
    stack_size = ((stack_size + (MY_POOL.page_size - 1)) / MY_POOL.page_size) * MY_POOL.page_size;

    return (stack_size);
}


/* Starts executing the thread.
 * Passed as the C level function to run in the new thread.
 */
#ifdef WIN32
STATIC THREAD_RET_TYPE
S_ithread_run(LPVOID arg)
#else
STATIC void *
S_ithread_run(void * arg)
#endif
{
    ithread *thread = (ithread *)arg;
    int jmp_rc = 0;
    I32 oldscope;
    int exit_app = 0;
    int exit_code = 0;

    dJMPENV;

    dTHXa(thread->interp);

    dMY_POOL;

    /* Blocked until ->create() call finishes */
    MUTEX_LOCK(&thread->mutex);
    MUTEX_UNLOCK(&thread->mutex);

    PERL_SET_CONTEXT(thread->interp);
    S_ithread_set(aTHX_ thread);

    PL_perl_destruct_level = 2;

    {
        AV *params = (AV *)SvRV(thread->params);
        int len = (int)av_len(params)+1;
        int ii;

        dSP;
        ENTER;
        SAVETMPS;

        /* Put args on the stack */
        PUSHMARK(SP);
        for (ii=0; ii < len; ii++) {
            XPUSHs(av_shift(params));
        }
        PUTBACK;

        oldscope = PL_scopestack_ix;
        JMPENV_PUSH(jmp_rc);
        if (jmp_rc == 0) {
            /* Run the specified function */
            len = (int)call_sv(thread->init_function, thread->gimme|G_EVAL);
        } else if (jmp_rc == 2) {
            /* Thread exited */
            exit_app = 1;
            exit_code = STATUS_CURRENT;
            while (PL_scopestack_ix > oldscope) {
                LEAVE;
            }
        }
        JMPENV_POP;

        /* Remove args from stack and put back in params array */
        SPAGAIN;
        for (ii=len-1; ii >= 0; ii--) {
            SV *sv = POPs;
            if (jmp_rc == 0) {
                av_store(params, ii, SvREFCNT_inc(sv));
            }
        }

        FREETMPS;
        LEAVE;

        /* Check for failure */
        if (SvTRUE(ERRSV) && ckWARN_d(WARN_THREADS)) {
            oldscope = PL_scopestack_ix;
            JMPENV_PUSH(jmp_rc);
            if (jmp_rc == 0) {
                /* Warn that thread died */
                Perl_warn(aTHX_ "Thread %" UVuf " terminated abnormally: %" SVf, thread->tid, ERRSV);
            } else if (jmp_rc == 2) {
                /* Warn handler exited */
                exit_app = 1;
                exit_code = STATUS_CURRENT;
                while (PL_scopestack_ix > oldscope) {
                    LEAVE;
                }
            }
            JMPENV_POP;
        }

        /* Release function ref */
        SvREFCNT_dec(thread->init_function);
        thread->init_function = Nullsv;
    }

    PerlIO_flush((PerlIO *)NULL);

    MUTEX_LOCK(&MY_POOL.create_destruct_mutex);
    MUTEX_LOCK(&thread->mutex);
    /* Mark as finished */
    thread->state |= PERL_ITHR_FINISHED;
    /* Clear exit flag if required */
    if (thread->state & PERL_ITHR_THREAD_EXIT_ONLY) {
        exit_app = 0;
    }

    /* Adjust thread status counts */
    if (thread->state & PERL_ITHR_DETACHED) {
        MY_POOL.detached_threads--;
    } else {
        MY_POOL.running_threads--;
        MY_POOL.joinable_threads++;
    }
    MUTEX_UNLOCK(&thread->mutex);
    MUTEX_UNLOCK(&MY_POOL.create_destruct_mutex);

    /* Exit application if required */
    if (exit_app) {
        oldscope = PL_scopestack_ix;
        JMPENV_PUSH(jmp_rc);
        if (jmp_rc == 0) {
            /* Warn if there are unjoined threads */
            S_exit_warning(aTHX);
        } else if (jmp_rc == 2) {
            /* Warn handler exited */
            exit_code = STATUS_CURRENT;
            while (PL_scopestack_ix > oldscope) {
                LEAVE;
            }
        }
        JMPENV_POP;

        my_exit(exit_code);
    }

    /* Try to clean up thread */
    S_ithread_destruct(aTHX_ thread);

#ifdef WIN32
    return ((DWORD)0);
#else
    return (0);
#endif
}


/* Type conversion helper functions */

STATIC SV *
S_ithread_to_SV(pTHX_ SV *obj, ithread *thread, char *classname, bool inc)
{
    SV *sv;
    MAGIC *mg;

    /* If incrementing thread ref count, then call within mutex lock */
    if (inc) {
        MUTEX_LOCK(&thread->mutex);
        thread->count++;
        MUTEX_UNLOCK(&thread->mutex);
    }

    if (! obj) {
        obj = newSV(0);
    }

    sv = newSVrv(obj, classname);
    sv_setiv(sv, PTR2IV(thread));
    mg = sv_magicext(sv, Nullsv, PERL_MAGIC_shared_scalar, &ithread_vtbl, (char *)thread, 0);
    mg->mg_flags |= MGf_DUP;
    SvREADONLY_on(sv);

    return (obj);
}

STATIC ithread *
S_SV_to_ithread(pTHX_ SV *sv)
{
    /* Argument is a thread */
    if (SvROK(sv)) {
      return (INT2PTR(ithread *, SvIV(SvRV(sv))));
    }
    /* Argument is classname, therefore return current thread */
    return (S_ithread_get(aTHX));
}


/* threads->create()
 * Called in context of parent thread.
 * Called with MY_POOL.create_destruct_mutex locked.  (Unlocked on error.)
 */
STATIC ithread *
S_ithread_create(
        pTHX_ SV *init_function,
        IV        stack_size,
        int       gimme,
        int       exit_opt,
        SV       *params)
{
    ithread     *thread;
    CLONE_PARAMS clone_param;
    ithread     *current_thread = S_ithread_get(aTHX);

    SV         **tmps_tmp = PL_tmps_stack;
    IV           tmps_ix  = PL_tmps_ix;
#ifndef WIN32
    int          rc_stack_size = 0;
    int          rc_thread_create = 0;
#endif
    dMY_POOL;

    /* Allocate thread structure in context of the main thread's interpreter */
    {
        PERL_SET_CONTEXT(MY_POOL.main_thread.interp);
        thread = (ithread *)PerlMemShared_malloc(sizeof(ithread));
    }
    PERL_SET_CONTEXT(aTHX);
    if (!thread) {
        MUTEX_UNLOCK(&MY_POOL.create_destruct_mutex);
        PerlLIO_write(PerlIO_fileno(Perl_error_log), PL_no_mem, strlen(PL_no_mem));
        my_exit(1);
    }
    Zero(thread, 1, ithread);

    /* Add to threads list */
    thread->next = &MY_POOL.main_thread;
    thread->prev = MY_POOL.main_thread.prev;
    MY_POOL.main_thread.prev = thread;
    thread->prev->next = thread;

    /* Set count to 1 immediately in case thread exits before
     * we return to caller!
     */
    thread->count = 1;

    /* Block new thread until ->create() call finishes */
    MUTEX_INIT(&thread->mutex);
    MUTEX_LOCK(&thread->mutex);

    thread->tid = MY_POOL.tid_counter++;
    thread->stack_size = S_good_stack_size(aTHX_ stack_size);
    thread->gimme = gimme;
    thread->state = exit_opt;

    /* "Clone" our interpreter into the thread's interpreter.
     * This gives thread access to "static data" and code.
     */
    PerlIO_flush((PerlIO *)NULL);
    S_ithread_set(aTHX_ thread);

    SAVEBOOL(PL_srand_called); /* Save this so it becomes the correct value */
    PL_srand_called = FALSE;   /* Set it to false so we can detect if it gets
                                  set during the clone */

#ifdef WIN32
    thread->interp = perl_clone(aTHX, CLONEf_KEEP_PTR_TABLE | CLONEf_CLONE_HOST);
#else
    thread->interp = perl_clone(aTHX, CLONEf_KEEP_PTR_TABLE);
#endif

    /* perl_clone() leaves us in new interpreter's context.  As it is tricky
     * to spot an implicit aTHX, create a new scope with aTHX matching the
     * context for the duration of our work for new interpreter.
     */
    {
        dTHXa(thread->interp);

        MY_CXT_CLONE;

        /* Here we remove END blocks since they should only run in the thread
         * they are created
         */
        SvREFCNT_dec(PL_endav);
        PL_endav = newAV();

        if (SvPOK(init_function)) {
            thread->init_function = newSV(0);
            sv_copypv(thread->init_function, init_function);
        } else {
            clone_param.flags = 0;
            thread->init_function = sv_dup(init_function, &clone_param);
            if (SvREFCNT(thread->init_function) == 0) {
                SvREFCNT_inc_void(thread->init_function);
            }
        }

        thread->params = sv_dup(params, &clone_param);
        SvREFCNT_inc_void(thread->params);

        /* The code below checks that anything living on the tmps stack and
         * has been cloned (so it lives in the ptr_table) has a refcount
         * higher than 0.
         *
         * If the refcount is 0 it means that a something on the stack/context
         * was holding a reference to it and since we init_stacks() in
         * perl_clone that won't get cleaned and we will get a leaked scalar.
         * The reason it was cloned was that it lived on the @_ stack.
         *
         * Example of this can be found in bugreport 15837 where calls in the
         * parameter list end up as a temp.
         *
         * One could argue that this fix should be in perl_clone.
         */
        while (tmps_ix > 0) {
            SV* sv = (SV*)ptr_table_fetch(PL_ptr_table, tmps_tmp[tmps_ix]);
            tmps_ix--;
            if (sv && SvREFCNT(sv) == 0) {
                SvREFCNT_inc_void(sv);
                SvREFCNT_dec(sv);
            }
        }

        SvTEMP_off(thread->init_function);
        ptr_table_free(PL_ptr_table);
        PL_ptr_table = NULL;
        PL_exit_flags |= PERL_EXIT_DESTRUCT_END;
    }
    S_ithread_set(aTHX_ current_thread);
    PERL_SET_CONTEXT(aTHX);

    /* Create/start the thread */
#ifdef WIN32
    thread->handle = CreateThread(NULL,
                                  (DWORD)thread->stack_size,
                                  S_ithread_run,
                                  (LPVOID)thread,
                                  STACK_SIZE_PARAM_IS_A_RESERVATION,
                                  &thread->thr);
#else
    {
        STATIC pthread_attr_t attr;
        STATIC int attr_inited = 0;
        STATIC int attr_joinable = PTHREAD_CREATE_JOINABLE;
        if (! attr_inited) {
            pthread_attr_init(&attr);
            attr_inited = 1;
        }

#  ifdef PTHREAD_ATTR_SETDETACHSTATE
        /* Threads start out joinable */
        PTHREAD_ATTR_SETDETACHSTATE(&attr, attr_joinable);
#  endif

#  ifdef _POSIX_THREAD_ATTR_STACKSIZE
        /* Set thread's stack size */
        if (thread->stack_size > 0) {
            rc_stack_size = pthread_attr_setstacksize(&attr, (size_t)thread->stack_size);
        }
#  endif

        /* Create the thread */
        if (! rc_stack_size) {
#  ifdef OLD_PTHREADS_API
            rc_thread_create = pthread_create(&thread->thr,
                                              attr,
                                              S_ithread_run,
                                              (void *)thread);
#  else
#    if defined(HAS_PTHREAD_ATTR_SETSCOPE) && defined(PTHREAD_SCOPE_SYSTEM)
            pthread_attr_setscope(&attr, PTHREAD_SCOPE_SYSTEM);
#    endif
            rc_thread_create = pthread_create(&thread->thr,
                                              &attr,
                                              S_ithread_run,
                                              (void *)thread);
#  endif
        }

#  ifdef _POSIX_THREAD_ATTR_STACKSIZE
        /* Try to get thread's actual stack size */
        {
            size_t stacksize;
#ifdef HPUX1020
            stacksize = pthread_attr_getstacksize(attr);
#else
            if (! pthread_attr_getstacksize(&attr, &stacksize))
#endif
                if (stacksize > 0) {
                    thread->stack_size = (IV)stacksize;
                }
        }
#  endif
    }
#endif

    /* Check for errors */
#ifdef WIN32
    if (thread->handle == NULL) {
#else
    if (rc_stack_size || rc_thread_create) {
#endif
        /* Must unlock mutex for destruct call */
        MUTEX_UNLOCK(&MY_POOL.create_destruct_mutex);
        sv_2mortal(params);
        thread->state |= PERL_ITHR_NONVIABLE;
        S_ithread_destruct(aTHX_ thread);
#ifndef WIN32
        if (ckWARN_d(WARN_THREADS)) {
            if (rc_stack_size) {
                Perl_warn(aTHX_ "Thread creation failed: pthread_attr_setstacksize(%" IVdf ") returned %d", thread->stack_size, rc_stack_size);
            } else {
                Perl_warn(aTHX_ "Thread creation failed: pthread_create returned %d", rc_thread_create);
            }
        }
#endif
        return (NULL);
    }

    MY_POOL.running_threads++;
    sv_2mortal(params);
    return (thread);
}

#endif /* USE_ITHREADS */


MODULE = threads    PACKAGE = threads    PREFIX = ithread_
PROTOTYPES: DISABLE

#ifdef USE_ITHREADS

void
ithread_create(...)
    PREINIT:
        char *classname;
        ithread *thread;
        SV *function_to_call;
        AV *params;
        HV *specs;
        IV stack_size;
        int context;
        int exit_opt;
        SV *thread_exit_only;
        char *str;
        int idx;
        int ii;
        dMY_POOL;
    CODE:
        if ((items >= 2) && SvROK(ST(1)) && SvTYPE(SvRV(ST(1)))==SVt_PVHV) {
            if (--items < 2) {
                Perl_croak(aTHX_ "Usage: threads->create(\\%specs, function, ...)");
            }
            specs = (HV*)SvRV(ST(1));
            idx = 1;
        } else {
            if (items < 2) {
                Perl_croak(aTHX_ "Usage: threads->create(function, ...)");
            }
            specs = NULL;
            idx = 0;
        }

        if (sv_isobject(ST(0))) {
            /* $thr->create() */
            classname = HvNAME(SvSTASH(SvRV(ST(0))));
            thread = INT2PTR(ithread *, SvIV(SvRV(ST(0))));
            stack_size = thread->stack_size;
            exit_opt = thread->state & PERL_ITHR_THREAD_EXIT_ONLY;
        } else {
            /* threads->create() */
            classname = (char *)SvPV_nolen(ST(0));
            stack_size = MY_POOL.default_stack_size;
            thread_exit_only = get_sv("threads::thread_exit_only", TRUE);
            exit_opt = (SvTRUE(thread_exit_only))
                                    ? PERL_ITHR_THREAD_EXIT_ONLY : 0;
        }

        function_to_call = ST(idx+1);

        context = -1;
        if (specs) {
            /* stack_size */
            if (hv_exists(specs, "stack", 5)) {
                stack_size = SvIV(*hv_fetch(specs, "stack", 5, 0));
            } else if (hv_exists(specs, "stacksize", 9)) {
                stack_size = SvIV(*hv_fetch(specs, "stacksize", 9, 0));
            } else if (hv_exists(specs, "stack_size", 10)) {
                stack_size = SvIV(*hv_fetch(specs, "stack_size", 10, 0));
            }

            /* context */
            if (hv_exists(specs, "context", 7)) {
                str = (char *)SvPV_nolen(*hv_fetch(specs, "context", 7, 0));
                switch (*str) {
                    case 'a':
                    case 'A':
                        context = G_ARRAY;
                        break;
                    case 's':
                    case 'S':
                        context = G_SCALAR;
                        break;
                    case 'v':
                    case 'V':
                        context = G_VOID;
                        break;
                    default:
                        Perl_croak(aTHX_ "Invalid context: %s", str);
                }
            } else if (hv_exists(specs, "array", 5)) {
                if (SvTRUE(*hv_fetch(specs, "array", 5, 0))) {
                    context = G_ARRAY;
                }
            } else if (hv_exists(specs, "scalar", 6)) {
                if (SvTRUE(*hv_fetch(specs, "scalar", 6, 0))) {
                    context = G_SCALAR;
                }
            } else if (hv_exists(specs, "void", 4)) {
                if (SvTRUE(*hv_fetch(specs, "void", 4, 0))) {
                    context = G_VOID;
                }
            }

            /* exit => thread_only */
            if (hv_exists(specs, "exit", 4)) {
                str = (char *)SvPV_nolen(*hv_fetch(specs, "exit", 4, 0));
                exit_opt = (*str == 't' || *str == 'T')
                                    ? PERL_ITHR_THREAD_EXIT_ONLY : 0;
            }
        }
        if (context == -1) {
            context = GIMME_V;  /* Implicit context */
        } else {
            context |= (GIMME_V & (~(G_ARRAY|G_SCALAR|G_VOID)));
        }

        /* Function args */
        params = newAV();
        if (items > 2) {
            for (ii=2; ii < items ; ii++) {
                av_push(params, SvREFCNT_inc(ST(idx+ii)));
            }
        }

        /* Create thread */
        MUTEX_LOCK(&MY_POOL.create_destruct_mutex);
        thread = S_ithread_create(aTHX_ function_to_call,
                                        stack_size,
                                        context,
                                        exit_opt,
                                        newRV_noinc((SV*)params));
        if (! thread) {
            XSRETURN_UNDEF;     /* Mutex already unlocked */
        }
        ST(0) = sv_2mortal(S_ithread_to_SV(aTHX_ Nullsv, thread, classname, FALSE));
        MUTEX_UNLOCK(&MY_POOL.create_destruct_mutex);

        /* Let thread run */
        MUTEX_UNLOCK(&thread->mutex);

        /* XSRETURN(1); - implied */


void
ithread_list(...)
    PREINIT:
        char *classname;
        ithread *thread;
        int list_context;
        IV count = 0;
        int want_running = 0;
        dMY_POOL;
    PPCODE:
        /* Class method only */
        if (SvROK(ST(0))) {
            Perl_croak(aTHX_ "Usage: threads->list(...)");
        }
        classname = (char *)SvPV_nolen(ST(0));

        /* Calling context */
        list_context = (GIMME_V == G_ARRAY);

        /* Running or joinable parameter */
        if (items > 1) {
            want_running = SvTRUE(ST(1));
        }

        /* Walk through threads list */
        MUTEX_LOCK(&MY_POOL.create_destruct_mutex);
        for (thread = MY_POOL.main_thread.next;
             thread != &MY_POOL.main_thread;
             thread = thread->next)
        {
            /* Ignore detached or joined threads */
            if (thread->state & (PERL_ITHR_DETACHED|PERL_ITHR_JOINED)) {
                continue;
            }

            /* Filter per parameter */
            if (items > 1) {
                if (want_running) {
                    if (thread->state & PERL_ITHR_FINISHED) {
                        continue;   /* Not running */
                    }
                } else {
                    if (! (thread->state & PERL_ITHR_FINISHED)) {
                        continue;   /* Still running - not joinable yet */
                    }
                }
            }

            /* Push object on stack if list context */
            if (list_context) {
                XPUSHs(sv_2mortal(S_ithread_to_SV(aTHX_ Nullsv, thread, classname, TRUE)));
            }
            count++;
        }
        MUTEX_UNLOCK(&MY_POOL.create_destruct_mutex);
        /* If scalar context, send back count */
        if (! list_context) {
            XSRETURN_IV(count);
        }


void
ithread_self(...)
    PREINIT:
        char *classname;
        ithread *thread;
    CODE:
        /* Class method only */
        if (SvROK(ST(0))) {
            Perl_croak(aTHX_ "Usage: threads->self()");
        }
        classname = (char *)SvPV_nolen(ST(0));

        thread = S_ithread_get(aTHX);

        ST(0) = sv_2mortal(S_ithread_to_SV(aTHX_ Nullsv, thread, classname, TRUE));
        /* XSRETURN(1); - implied */


void
ithread_tid(...)
    PREINIT:
        ithread *thread;
    CODE:
        thread = S_SV_to_ithread(aTHX_ ST(0));
        XST_mUV(0, thread->tid);
        /* XSRETURN(1); - implied */


void
ithread_join(...)
    PREINIT:
        ithread *thread;
        int join_err;
        AV *params;
        int len;
        int ii;
#ifdef WIN32
        DWORD waitcode;
#else
        void *retval;
#endif
        dMY_POOL;
    PPCODE:
        /* Object method only */
        if (! sv_isobject(ST(0))) {
            Perl_croak(aTHX_ "Usage: $thr->join()");
        }

        /* Check if the thread is joinable */
        thread = S_SV_to_ithread(aTHX_ ST(0));
        join_err = (thread->state & (PERL_ITHR_DETACHED|PERL_ITHR_JOINED));
        if (join_err) {
            if (join_err & PERL_ITHR_DETACHED) {
                Perl_croak(aTHX_ "Cannot join a detached thread");
            } else {
                Perl_croak(aTHX_ "Thread already joined");
            }
        }

        /* Join the thread */
#ifdef WIN32
        waitcode = WaitForSingleObject(thread->handle, INFINITE);
#else
        pthread_join(thread->thr, &retval);
#endif

        MUTEX_LOCK(&thread->mutex);
        /* Mark as joined */
        thread->state |= PERL_ITHR_JOINED;

        /* Get the return value from the call_sv */
        {
            AV *params_copy;
            PerlInterpreter *other_perl;
            CLONE_PARAMS clone_params;
            ithread *current_thread;

            params_copy = (AV *)SvRV(thread->params);
            other_perl = thread->interp;
            clone_params.stashes = newAV();
            clone_params.flags = CLONEf_JOIN_IN;
            PL_ptr_table = ptr_table_new();
            current_thread = S_ithread_get(aTHX);
            S_ithread_set(aTHX_ thread);
            /* Ensure 'meaningful' addresses retain their meaning */
            ptr_table_store(PL_ptr_table, &other_perl->Isv_undef, &PL_sv_undef);
            ptr_table_store(PL_ptr_table, &other_perl->Isv_no, &PL_sv_no);
            ptr_table_store(PL_ptr_table, &other_perl->Isv_yes, &PL_sv_yes);
            params = (AV *)sv_dup((SV*)params_copy, &clone_params);
            S_ithread_set(aTHX_ current_thread);
            SvREFCNT_dec(clone_params.stashes);
            SvREFCNT_inc_void(params);
            ptr_table_free(PL_ptr_table);
            PL_ptr_table = NULL;
        }

        /* We are finished with the thread */
        S_ithread_clear(aTHX_ thread);
        MUTEX_UNLOCK(&thread->mutex);

        MUTEX_LOCK(&MY_POOL.create_destruct_mutex);
        if (! (thread->state & PERL_ITHR_DETACHED)) {
            MY_POOL.joinable_threads--;
        }
        MUTEX_UNLOCK(&MY_POOL.create_destruct_mutex);

        /* If no return values, then just return */
        if (! params) {
            XSRETURN_UNDEF;
        }

        /* Put return values on stack */
        len = (int)AvFILL(params);
        for (ii=0; ii <= len; ii++) {
            SV* param = av_shift(params);
            XPUSHs(sv_2mortal(param));
        }

        /* Free return value array */
        SvREFCNT_dec(params);


void
ithread_yield(...)
    CODE:
        YIELD;


void
ithread_detach(...)
    PREINIT:
        ithread *thread;
        int detach_err;
        dMY_POOL;
    CODE:
        /* Check if the thread is detachable */
        thread = S_SV_to_ithread(aTHX_ ST(0));
        if ((detach_err = (thread->state & (PERL_ITHR_DETACHED|PERL_ITHR_JOINED)))) {
            if (detach_err & PERL_ITHR_DETACHED) {
                Perl_croak(aTHX_ "Thread already detached");
            } else {
                Perl_croak(aTHX_ "Cannot detach a joined thread");
            }
        }

        /* Detach the thread */
        MUTEX_LOCK(&MY_POOL.create_destruct_mutex);
        MUTEX_LOCK(&thread->mutex);
        thread->state |= PERL_ITHR_DETACHED;
#ifdef WIN32
        /* Windows has no 'detach thread' function */
#else
        PERL_THREAD_DETACH(thread->thr);
#endif

        if (thread->state & PERL_ITHR_FINISHED) {
            MY_POOL.joinable_threads--;
        } else {
            MY_POOL.running_threads--;
            MY_POOL.detached_threads++;
        }
        MUTEX_UNLOCK(&thread->mutex);
        MUTEX_UNLOCK(&MY_POOL.create_destruct_mutex);

        /* Try to cleanup thread */
        S_ithread_destruct(aTHX_ thread);


void
ithread_kill(...)
    PREINIT:
        ithread *thread;
        char *sig_name;
        IV signal;
    CODE:
        /* Must have safe signals */
        if (PL_signals & PERL_SIGNALS_UNSAFE_FLAG) {
            Perl_croak(aTHX_ "Cannot signal threads without safe signals");
        }

        /* Object method only */
        if (! sv_isobject(ST(0))) {
            Perl_croak(aTHX_ "Usage: $thr->kill('SIG...')");
        }

        /* Get signal */
        sig_name = SvPV_nolen(ST(1));
        if (isALPHA(*sig_name)) {
            if (*sig_name == 'S' && sig_name[1] == 'I' && sig_name[2] == 'G') {
                sig_name += 3;
            }
            if ((signal = whichsig(sig_name)) < 0) {
                Perl_croak(aTHX_ "Unrecognized signal name: %s", sig_name);
            }
        } else {
            signal = SvIV(ST(1));
        }

        /* Set the signal for the thread */
        thread = S_SV_to_ithread(aTHX_ ST(0));
        MUTEX_LOCK(&thread->mutex);
        if (thread->interp) {
            dTHXa(thread->interp);
            PL_psig_pend[signal]++;
            PL_sig_pending = 1;
        }
        MUTEX_UNLOCK(&thread->mutex);

        /* Return the thread to allow for method chaining */
        ST(0) = ST(0);
        /* XSRETURN(1); - implied */


void
ithread_DESTROY(...)
    CODE:
        sv_unmagic(SvRV(ST(0)), PERL_MAGIC_shared_scalar);


void
ithread_equal(...)
    PREINIT:
        int are_equal = 0;
    CODE:
        /* Compares TIDs to determine thread equality */
        if (sv_isobject(ST(0)) && sv_isobject(ST(1))) {
            ithread *thr1 = INT2PTR(ithread *, SvIV(SvRV(ST(0))));
            ithread *thr2 = INT2PTR(ithread *, SvIV(SvRV(ST(1))));
            are_equal = (thr1->tid == thr2->tid);
        }
        if (are_equal) {
            XST_mYES(0);
        } else {
            /* Return 0 on false for backward compatibility */
            XST_mIV(0, 0);
        }
        /* XSRETURN(1); - implied */


void
ithread_object(...)
    PREINIT:
        char *classname;
        UV tid;
        ithread *thread;
        int have_obj = 0;
        dMY_POOL;
    CODE:
        /* Class method only */
        if (SvROK(ST(0))) {
            Perl_croak(aTHX_ "Usage: threads->object($tid)");
        }
        classname = (char *)SvPV_nolen(ST(0));

        if ((items < 2) || ! SvOK(ST(1))) {
            XSRETURN_UNDEF;
        }

        /* threads->object($tid) */
        tid = SvUV(ST(1));

        /* Walk through threads list */
        MUTEX_LOCK(&MY_POOL.create_destruct_mutex);
        for (thread = MY_POOL.main_thread.next;
             thread != &MY_POOL.main_thread;
             thread = thread->next)
        {
            /* Look for TID */
            if (thread->tid == tid) {
                /* Ignore if detached or joined */
                if (! (thread->state & (PERL_ITHR_DETACHED|PERL_ITHR_JOINED))) {
                    /* Put object on stack */
                    ST(0) = sv_2mortal(S_ithread_to_SV(aTHX_ Nullsv, thread, classname, TRUE));
                    have_obj = 1;
                }
                break;
            }
        }
        MUTEX_UNLOCK(&MY_POOL.create_destruct_mutex);

        if (! have_obj) {
            XSRETURN_UNDEF;
        }
        /* XSRETURN(1); - implied */


void
ithread__handle(...);
    PREINIT:
        ithread *thread;
    CODE:
        thread = S_SV_to_ithread(aTHX_ ST(0));
#ifdef WIN32
        XST_mUV(0, PTR2UV(&thread->handle));
#else
        XST_mUV(0, PTR2UV(&thread->thr));
#endif
        /* XSRETURN(1); - implied */


void
ithread_get_stack_size(...)
    PREINIT:
        IV stack_size;
        dMY_POOL;
    CODE:
        if (sv_isobject(ST(0))) {
            /* $thr->get_stack_size() */
            ithread *thread = INT2PTR(ithread *, SvIV(SvRV(ST(0))));
            stack_size = thread->stack_size;
        } else {
            /* threads->get_stack_size() */
            stack_size = MY_POOL.default_stack_size;
        }
        XST_mIV(0, stack_size);
        /* XSRETURN(1); - implied */


void
ithread_set_stack_size(...)
    PREINIT:
        IV old_size;
        dMY_POOL;
    CODE:
        if (items != 2) {
            Perl_croak(aTHX_ "Usage: threads->set_stack_size($size)");
        }
        if (sv_isobject(ST(0))) {
            Perl_croak(aTHX_ "Cannot change stack size of an existing thread");
        }

        old_size = MY_POOL.default_stack_size;
        MY_POOL.default_stack_size = S_good_stack_size(aTHX_ SvIV(ST(1)));
        XST_mIV(0, old_size);
        /* XSRETURN(1); - implied */


void
ithread_is_running(...)
    PREINIT:
        ithread *thread;
    CODE:
        /* Object method only */
        if (! sv_isobject(ST(0))) {
            Perl_croak(aTHX_ "Usage: $thr->is_running()");
        }

        thread = INT2PTR(ithread *, SvIV(SvRV(ST(0))));
        ST(0) = (thread->state & PERL_ITHR_FINISHED) ? &PL_sv_no : &PL_sv_yes;
        /* XSRETURN(1); - implied */


void
ithread_is_detached(...)
    PREINIT:
        ithread *thread;
    CODE:
        thread = S_SV_to_ithread(aTHX_ ST(0));
        ST(0) = (thread->state & PERL_ITHR_DETACHED) ? &PL_sv_yes : &PL_sv_no;
        /* XSRETURN(1); - implied */


void
ithread_is_joinable(...)
    PREINIT:
        ithread *thread;
    CODE:
        /* Object method only */
        if (! sv_isobject(ST(0))) {
            Perl_croak(aTHX_ "Usage: $thr->is_joinable()");
        }

        thread = INT2PTR(ithread *, SvIV(SvRV(ST(0))));
        MUTEX_LOCK(&thread->mutex);
        ST(0) = ((thread->state & PERL_ITHR_FINISHED) &&
                 ! (thread->state & (PERL_ITHR_DETACHED|PERL_ITHR_JOINED)))
            ? &PL_sv_yes : &PL_sv_no;
        MUTEX_UNLOCK(&thread->mutex);
        /* XSRETURN(1); - implied */


void
ithread_wantarray(...)
    PREINIT:
        ithread *thread;
    CODE:
        thread = S_SV_to_ithread(aTHX_ ST(0));
        ST(0) = (thread->gimme & G_ARRAY) ? &PL_sv_yes :
                (thread->gimme & G_VOID)  ? &PL_sv_undef
                           /* G_SCALAR */ : &PL_sv_no;
        /* XSRETURN(1); - implied */


void
ithread_set_thread_exit_only(...)
    PREINIT:
        ithread *thread;
    CODE:
        if (items != 2) {
            Perl_croak(aTHX_ "Usage: ->set_thread_exit_only(boolean)");
        }
        thread = S_SV_to_ithread(aTHX_ ST(0));
        MUTEX_LOCK(&thread->mutex);
        if (SvTRUE(ST(1))) {
            thread->state |= PERL_ITHR_THREAD_EXIT_ONLY;
        } else {
            thread->state &= ~PERL_ITHR_THREAD_EXIT_ONLY;
        }
        MUTEX_UNLOCK(&thread->mutex);

#endif /* USE_ITHREADS */


BOOT:
{
#ifdef USE_ITHREADS
    SV *my_pool_sv = *hv_fetch(PL_modglobal, MY_POOL_KEY,
                               sizeof(MY_POOL_KEY)-1, TRUE);
    my_pool_t *my_poolp = (my_pool_t*)SvPVX(newSV(sizeof(my_pool_t)-1));

    MY_CXT_INIT;

    Zero(my_poolp, 1, my_pool_t);
    sv_setuv(my_pool_sv, PTR2UV(my_poolp));

    PL_perl_destruct_level = 2;
    MUTEX_INIT(&MY_POOL.create_destruct_mutex);
    MUTEX_LOCK(&MY_POOL.create_destruct_mutex);

    PL_threadhook = &Perl_ithread_hook;

    MY_POOL.tid_counter = 1;
#  ifdef THREAD_CREATE_NEEDS_STACK
    MY_POOL.default_stack_size = THREAD_CREATE_NEEDS_STACK;
#  endif

    /* The 'main' thread is thread 0.
     * It is detached (unjoinable) and immortal.
     */

    MUTEX_INIT(&MY_POOL.main_thread.mutex);

    /* Head of the threads list */
    MY_POOL.main_thread.next = &MY_POOL.main_thread;
    MY_POOL.main_thread.prev = &MY_POOL.main_thread;

    MY_POOL.main_thread.count = 1;                  /* Immortal */

    MY_POOL.main_thread.interp = aTHX;
    MY_POOL.main_thread.state = PERL_ITHR_DETACHED; /* Detached */
    MY_POOL.main_thread.stack_size = MY_POOL.default_stack_size;
#  ifdef WIN32
    MY_POOL.main_thread.thr = GetCurrentThreadId();
#  else
    MY_POOL.main_thread.thr = pthread_self();
#  endif

    S_ithread_set(aTHX_ &MY_POOL.main_thread);
    MUTEX_UNLOCK(&MY_POOL.create_destruct_mutex);
#endif /* USE_ITHREADS */
}
