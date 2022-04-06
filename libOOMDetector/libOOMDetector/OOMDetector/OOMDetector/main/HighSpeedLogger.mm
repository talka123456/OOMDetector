//
//  HighSpeedLogger.m
//  QQLeak
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

#import "HighSpeedLogger.h"
#import <sys/mman.h>

#if __has_feature(objc_arc)
#error This file must be compiled without ARC. Use -fno-objc-arc flag.
#endif

HighSpeedLogger::~HighSpeedLogger()
{
    if(mmap_ptr != NULL){
        munmap(mmap_ptr , mmap_size);
    }
}

HighSpeedLogger::HighSpeedLogger(malloc_zone_t *zone, NSString *path, size_t size)
{
    current_len = 0;
    mmap_size = size;
    memory_zone = zone;
    isFailed = false;
    FILE *fp = fopen ( [path fileSystemRepresentation] , "wb+" ) ;
    if(fp != NULL){
        int ret = ftruncate(fileno(fp), size);
        if(ret == -1){
            isFailed = true;
        }
        else {
            fseek(fp, 0, SEEK_SET);
            char *ptr = (char *)mmap(0, size, PROT_WRITE | PROT_READ, (MAP_FILE|MAP_SHARED), fileno(fp), 0);
            memset(ptr, '\0', size);
            if(ptr != NULL){
                mmap_ptr = ptr;
                mmap_fp = fp;
            }
            else {
                isFailed = true;
            }
        }
    }
    else {
        isFailed = true;
    }
}

BOOL HighSpeedLogger::memcpyLogger(const char *content, size_t length)
{
    BOOL result = NO;
    if(length + current_len <= mmap_size){
        memcpy(mmap_ptr + current_len, content, length);
        current_len += length;
        result = YES;
    }
    else {
        char *copy = (char *)memory_zone->malloc(memory_zone, mmap_size);
        memcpy(copy, mmap_ptr, mmap_size);
        size_t copy_size = mmap_size;
        munmap(mmap_ptr ,mmap_size);
        mmap_size = current_len + length;
        int ret = ftruncate(fileno(mmap_fp), mmap_size);
        if(ret == -1){
            memory_zone->free(memory_zone,copy);
            result = NO;
        }
        else {
            fseek(mmap_fp, 0, SEEK_SET);
            mmap_ptr = (char *)mmap(0, mmap_size, PROT_WRITE | PROT_READ, (MAP_FILE|MAP_SHARED), fileno(mmap_fp), 0);
            if(mmap_ptr == NULL){
                mmap_size = 0;
                current_len = 0;
                memory_zone->free(memory_zone,copy);
                result = NO;
            }
            else {
                memset(mmap_ptr, '\0', mmap_size);
                result = YES;
                memcpy(mmap_ptr, copy, copy_size);
                memcpy(mmap_ptr + current_len, content, length);
                current_len += length;
                memory_zone->free(memory_zone,copy);
            }
        }
    }
    return result;
}

/// 清空
void HighSpeedLogger::cleanLogger()
{
    current_len = 0;
    memset(mmap_ptr, '\0', mmap_size);
}

/// 同步虚拟内存到磁盘
void HighSpeedLogger::syncLogger()
{
    msync(mmap_ptr, mmap_size, MS_ASYNC);
}

/// 返回是否有效
bool HighSpeedLogger::isValid()
{
    return !isFailed;
}
