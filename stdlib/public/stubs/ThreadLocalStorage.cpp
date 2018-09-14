//===--- ThreadLocalStorage.cpp -------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2018 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

#include <cstring>

#include "../SwiftShims/ThreadLocalStorage.h"
#include "../runtime/ThreadLocalStorage.h"
#include "swift/Basic/Lazy.h"
#include "swift/Runtime/Debug.h"

SWIFT_CC(swift) SWIFT_RUNTIME_STDLIB_API
void _stdlib_destroyTLS(void *);
SWIFT_CC(swift) SWIFT_RUNTIME_STDLIB_API
void *_stdlib_createTLS(void);

#if SWIFT_TLS_HAS_RESERVED_PTHREAD_SPECIFIC

SWIFT_RUNTIME_STDLIB_INTERNAL
void *
_swift_stdlib_threadLocalStorageGet(void) {
  void *value = SWIFT_THREAD_GETSPECIFIC(SWIFT_STDLIB_TLS_KEY);
  if (value)
    return value;
  
  static swift::OnceToken_t token;
  SWIFT_ONCE_F(token, [](void *) {
    int result = pthread_key_init_np(SWIFT_STDLIB_TLS_KEY, [](void *pointer) {
      _stdlib_destroyTLS(pointer);
    });
    if (result != 0)
      swift::fatalError(0, "couldn't create pthread key for stdlib TLS: %s\n",
                        std::strerror(result));
  }, nullptr);
  
  value = _stdlib_createTLS();
  SWIFT_THREAD_SETSPECIFIC(SWIFT_STDLIB_TLS_KEY, value);
  return value;
}

#else

SWIFT_RUNTIME_STDLIB_INTERNAL
void *
_swift_stdlib_threadLocalStorageGet(void) {
  static swift::OnceToken_t token;
  static pthread_key_t key;
  SWIFT_ONCE_F(token, [](void *) {
    int result = SWIFT_THREAD_KEY_CREATE(&key, [](void *pointer) {
      _stdlib_destroyTLS(pointer);
    });
    if (result != 0)
      swift::fatalError(0, "couldn't create pthread key for stdlib TLS: %s\n",
                        std::strerror(result));
  }, nullptr);
  
  void *value = SWIFT_THREAD_GETSPECIFIC(key);
  if (!value) {
    value = _stdlib_createTLS();
    int result = SWIFT_THREAD_SETSPECIFIC(key, value);
    if (result != 0)
      swift::fatalError(0, "pthread_setspecific failed: %s\n",
                        std::strerror(result));
  }
  return value;
}

#endif
