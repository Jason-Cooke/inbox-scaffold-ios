//
//  NSError+InboxErrors.m
//  InboxFramework
//
//  Created by Ben Gotow on 5/27/14.
//  Copyright (c) 2014 Inbox. All rights reserved.
//

#import "NSError+InboxErrors.h"

@implementation NSError (InboxErrors)

+ (NSError*)inboxErrorWithDescription:(NSString *)format, ...
{
    va_list args;
    va_start(args, format);
    NSString * description = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    return [NSError errorWithDomain:@"Inbox" code:-1 userInfo:@{NSLocalizedDescriptionKey: description}];
}

@end
