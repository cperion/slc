# Runtime implementation

Runtime policy is ordinary SLC, built from [the runtime entry](scheduler.slc).

- [Scheduler words](scheduler.slc): replayable randomness, run queues, timer heaps,
  waiters, buffered/rendezvous transfers and pool free lists/generations.
- [Lifecycle](lifecycle.slc): scopes, owned-record vectors, registry chunk growth,
  mutex initialization, reuse, metadata linkage, retirement and teardown.
- [Protocol](protocol.slc): channel/slot validation and ownership, first-of
  scan/arm/withdraw/retry, blocking-operation preparation and resumption.
- [Bookkeeping](bookkeeping.slc): idler/task/job lists, timer firing and worker
  configuration.
- [I/O](io.slc) and [POSIX](posix.slc): operation construction/completion, syscall
  composition, retries, socket setup and failure cleanup.
- [Poll](poll.slc), [kqueue](kqueue.slc) and [io_uring](uring.slc): backend queue,
  deadline, submission and completion policy, including the event loops.
- [Tasks](tasks.slc): workers, plain-thread waits, wake transitions, scopes, the
  channel and pool registries, timers, blocking threads and the I/O accounting,
  under the scheduler lock, with the thread bodies passed to `pthread_create` as
  `fnptr` words. Its state is native globals (`global`, spec §42), thread-local
  where it belongs to a thread.
- [Process](process.slc): the data-stack set a thread uses (thread-local
  `slc_own_stacks` and `slc_cur_stacks`), store tokens and the hash key.
- [Backend](backend.slc): the poller thread and submission entry of the poll and
  kqueue backends.
- [Stacks](../lib/stacks.slc) and [storage layout](../lib/storage_layout.slc):
  data-stack growth/access/unwinding and Store, Grow, Id, Map and StrMap record
  access. The runtime entry exports both sets, so programs and the runtime share
  one implementation.

SLC modules call each other's words directly where no synchronization boundary
intervenes. Exports provide the native runtime ABI, not alternate algorithms.
The owning mutex stays held across each transaction. Unlock-before-trap,
claim-before-transfer, successful-path adoption, capture-next-before-wake and
atomic memory orders are preserved. Protocol words can explicitly lock, unlock
and wake; leaf queue/heap/transfer words rely on their caller's transaction.

C retains `slc_trap` and `slc_try` (`setjmp`/`longjmp` return twice) and `slc_gs_pin`
(SLC has no pointer subtraction), in [slc_rt.c](slc_rt.c). io_uring additionally
retains Linux setup/mmap and integer-address kernel ABI marshalling in
[slc_io_uring.c](slc_io_uring.c). The language deliberately offers no integer-pointer
conversion. Nothing else in the runtime is C: locks, parking, wake-ups, clock reads,
thread creation and the deadlock report are SLC calling libc and pthreads.

`make runtime` compiles the selected policy and prints its generated C path.
`SLC_IO=poll` (default), `uring` or `kqueue` selects the backend. External C builds
must link that generated unit with `runtime/slc_rt.c` (and `runtime/slc_io_uring.c` for
io_uring) and `-Iruntime -pthread`, plus the selected platform's headers/libraries. Generated C enables
POSIX feature declarations before system headers. It lives under `SLC_CACHE` or
`build/runtime`, never as checked-in source.

[The shared builder](../slc/runtime_build.lua) also accepts `source(backend)`.
It runs the frontend in a separate process, preserving an active compilation's
state, and caches independently per backend. Native cache identity includes the
generated policy and internal layout headers. There is no handwritten fallback.

`make test-scheduler` exercises C and libgccjit policy objects, recursive layouts,
independent queue/heap/channel/pool/lifecycle models and threaded/seeded channel
and poll-I/O integration. It requires libgccjit. The normal test suite also
exercises backend integrations and the existing sanitizer paths. Missing platform
headers or kernel support are limitations, not passing backend checks.

[The remaining architecture audit](../docs/helpers-audit.md) tracks compiler-side
library composition and external numeric conversion separately from this runtime
rewrite.
