// Mac OS X 10.6 or higher only.
#include <dispatch/dispatch.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#import <CoreFoundation/CFBase.h>
#import <Foundation/NSObject.h>
#import <Foundation/NSURL.h>

// This is a (void*)(void*) function so it can be passed to pthread_create.
void *CFAllocatorDefaultDoubleFree(void *unused) {
  void *mem =  CFAllocatorAllocate(kCFAllocatorDefault, 5, 0);
  CFAllocatorDeallocate(kCFAllocatorDefault, mem);
  CFAllocatorDeallocate(kCFAllocatorDefault, mem);
  return 0;
}

void CFAllocatorSystemDefaultDoubleFree() {
  void *mem =  CFAllocatorAllocate(kCFAllocatorSystemDefault, 5, 0);
  CFAllocatorDeallocate(kCFAllocatorSystemDefault, mem);
  CFAllocatorDeallocate(kCFAllocatorSystemDefault, mem);
}

void CFAllocatorMallocDoubleFree() {
  void *mem =  CFAllocatorAllocate(kCFAllocatorMalloc, 5, 0);
  CFAllocatorDeallocate(kCFAllocatorMalloc, mem);
  CFAllocatorDeallocate(kCFAllocatorMalloc, mem);
}

void CFAllocatorMallocZoneDoubleFree() {
  void *mem =  CFAllocatorAllocate(kCFAllocatorMallocZone, 5, 0);
  CFAllocatorDeallocate(kCFAllocatorMallocZone, mem);
  CFAllocatorDeallocate(kCFAllocatorMallocZone, mem);
}

__attribute__((noinline))
void access_memory(char *a) {
  *a = 0;
}

// Test the +load instrumentation.
// Because the +load methods are invoked before anything else is initialized,
// it makes little sense to wrap the code below into a gTest test case.
// If AddressSanitizer doesn't instrument the +load method below correctly,
// everything will just crash.

char kStartupStr[] =
    "If your test didn't crash, AddressSanitizer is instrumenting "
    "the +load methods correctly.";

@interface LoadSomething : NSObject {
}
@end

@implementation LoadSomething

+(void) load {
  for (int i = 0; i < strlen(kStartupStr); i++) {
    access_memory(&kStartupStr[i]);  // make sure no optimizations occur.
  }
  // Don't print anything here not to interfere with the death tests.
}

@end

void worker_do_alloc(int size) {
  char * volatile mem = malloc(size);
  mem[0] = 0; // Ok
  free(mem);
}

void worker_do_crash(int size) {
  char * volatile mem = malloc(size);
  access_memory(&mem[size]);  // BOOM
  free(mem);
}

// Tests for the Grand Central Dispatch. See
// http://developer.apple.com/library/mac/#documentation/Performance/Reference/GCD_libdispatch_Ref/Reference/reference.html
// for the reference.

void TestGCDDispatchAsync() {
  dispatch_queue_t queue = dispatch_get_global_queue(0, 0);
  dispatch_block_t block = ^{ worker_do_crash(1024); };
  // dispatch_async() runs the task on a worker thread that does not go through
  // pthread_create(). We need to verify that AddressSanitizer notices that the
  // thread has started.
  dispatch_async(queue, block);
  // TODO(glider): this is hacky. Need to wait for the worker instead.
  sleep(1);
}

void TestGCDDispatchSync() {
  dispatch_queue_t queue = dispatch_get_global_queue(2, 0);
  dispatch_block_t block = ^{ worker_do_crash(1024); };
  // dispatch_sync() runs the task on a worker thread that does not go through
  // pthread_create(). We need to verify that AddressSanitizer notices that the
  // thread has started.
  dispatch_sync(queue, block);
  // TODO(glider): this is hacky. Need to wait for the worker instead.
  sleep(1);
}

// libdispatch spawns a rather small number of threads and reuses them. We need
// to make sure AddressSanitizer handles the reusing correctly.
void TestGCDReuseWqthreadsAsync() {
  dispatch_queue_t queue = dispatch_get_global_queue(0, 0);
  dispatch_block_t block_alloc = ^{ worker_do_alloc(1024); };
  dispatch_block_t block_crash = ^{ worker_do_crash(1024); };
  for (int i = 0; i < 100; i++) {
    dispatch_async(queue, block_alloc);
  }
  dispatch_async(queue, block_crash);
  // TODO(glider): this is hacky. Need to wait for the workers instead.
  sleep(1);
}

// Try to trigger abnormal behaviour of dispatch_sync() being unhandled by us.
void TestGCDReuseWqthreadsSync() {
  dispatch_queue_t queue[4];
  queue[0] = dispatch_get_global_queue(2, 0);
  queue[1] = dispatch_get_global_queue(0, 0);
  queue[2] = dispatch_get_global_queue(-2, 0);
  queue[3] = dispatch_queue_create("my_queue", NULL);
  dispatch_block_t block_alloc = ^{ worker_do_alloc(1024); };
  dispatch_block_t block_crash = ^{ worker_do_crash(1024); };
  for (int i = 0; i < 1000; i++) {
    dispatch_sync(queue[i % 4], block_alloc);
  }
  dispatch_sync(queue[3], block_crash);
  // TODO(glider): this is hacky. Need to wait for the workers instead.
  sleep(1);
}

void TestGCDDispatchAfter() {
  dispatch_queue_t queue = dispatch_get_global_queue(0, 0);
  dispatch_block_t block_crash = ^{ worker_do_crash(1024); };
  // Schedule the event one second from the current time.
  dispatch_time_t milestone =
      dispatch_time(DISPATCH_TIME_NOW, 1LL * NSEC_PER_SEC);
  dispatch_after(milestone, queue, block_crash);
  // Let's wait for a bit longer now.
  // TODO(glider): this is still hacky.
  sleep(2);
}

void worker_do_deallocate(void *ptr) {
  free(ptr);
}

void CallFreeOnWorkqueue(void *tsd) {
  dispatch_queue_t queue = dispatch_get_global_queue(0, 0);
  dispatch_block_t block_dealloc = ^{ worker_do_deallocate(tsd); };
  dispatch_async(queue, block_dealloc);
  // Do not wait for the worker to free the memory -- nobody is going to touch
  // it.
}

void TestGCDSourceEvent() {
  dispatch_queue_t queue = dispatch_get_global_queue(0, 0);
  dispatch_source_t timer =
      dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
  // Schedule the timer one second from the current time.
  dispatch_time_t milestone =
      dispatch_time(DISPATCH_TIME_NOW, 1LL * NSEC_PER_SEC);

  dispatch_source_set_timer(timer, milestone, DISPATCH_TIME_FOREVER, 0);
  char * volatile mem = malloc(10);
  dispatch_source_set_event_handler(timer, ^{
    access_memory(&mem[10]);
  });
  dispatch_resume(timer);
  sleep(2);
}

void TestGCDSourceCancel() {
  dispatch_queue_t queue = dispatch_get_global_queue(0, 0);
  dispatch_source_t timer =
      dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
  // Schedule the timer one second from the current time.
  dispatch_time_t milestone =
      dispatch_time(DISPATCH_TIME_NOW, 1LL * NSEC_PER_SEC);

  dispatch_source_set_timer(timer, milestone, DISPATCH_TIME_FOREVER, 0);
  char * volatile mem = malloc(10);
  // Both dispatch_source_set_cancel_handler() and
  // dispatch_source_set_event_handler() use dispatch_barrier_async_f().
  // It's tricky to test dispatch_source_set_cancel_handler() separately,
  // so we test both here.
  dispatch_source_set_event_handler(timer, ^{
    dispatch_source_cancel(timer);
  });
  dispatch_source_set_cancel_handler(timer, ^{
    access_memory(&mem[10]);
  });
  dispatch_resume(timer);
  sleep(2);
}

void TestGCDGroupAsync() {
  dispatch_queue_t queue = dispatch_get_global_queue(0, 0);
  dispatch_group_t group = dispatch_group_create(); 
  char * volatile mem = malloc(10);
  dispatch_group_async(group, queue, ^{
    access_memory(&mem[10]);
  });
  dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
}

@interface FixedArray : NSObject {
  int items[10];
}
@end

@implementation FixedArray
-(int) access: (int)index {
  return items[index];
}
@end

void TestOOBNSObjects() {
  id anObject = [FixedArray new];
  [anObject access:1];
  [anObject access:11];
  [anObject release];
}

void TestNSURLDeallocation() {
  NSURL *base =
      [[NSURL alloc] initWithString:@"file://localhost/Users/glider/Library/"];
  volatile NSURL *u =
      [[NSURL alloc] initWithString:@"Saved Application State"
                     relativeToURL:base];
  [u release];
}
