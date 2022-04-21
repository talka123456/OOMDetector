//
//  CommonMallocLogger.h
//  QQLeakDemo
//
//  Tencent is pleased to support the open source community by making OOMDetector available.
//  Copyright (C) 2017 THL A29 Limited, a Tencent company. All rights reserved.
//  Licensed under the MIT License (the "License"); you may not use this file except
//  in compliance with the License. You may obtain a copy of the License at
//
//  http://opensource.org/licenses/MIT
//
//  Unless required by applicable law or agreed to in writing, software distributed under the
//  License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,
//  either express or implied. See the License for the specific language governing permissions
//  and limitations under the License.
//
//

#import <Foundation/Foundation.h>
#import <malloc/malloc.h>
#import "CStackHelper.h"

/// ifdef 可以用来避免重复定义。这里的作用是条件编译，如果是 cpp 环境，则执行 extern "C"
/// extern 'C' 是为了 C/C++混编调用。因为多态导致 Cpp 存在 name mangling, 所以实际互调时是无法找到对应符号的，所以需要告知编译器，这里的函数使用 c 语法规则参与编译和链接。
/// 参考： https://www.cnblogs.com/skynet/archive/2010/07/10/1774964.html
#ifdef __cplusplus
extern "C" {
#endif
    extern malloc_zone_t *global_memory_zone;
    
    typedef void (malloc_logger_t)(uint32_t type, uintptr_t arg1, uintptr_t arg2, uintptr_t arg3, uintptr_t result, uint32_t num_hot_frames_to_skip);
    
    extern malloc_logger_t* malloc_logger;
    
    void common_stack_logger(uint32_t type, uintptr_t arg1, uintptr_t arg2, uintptr_t arg3, uintptr_t result, uint32_t backtrace_to_skip);
    
#ifdef __cplusplus
    }
#endif
