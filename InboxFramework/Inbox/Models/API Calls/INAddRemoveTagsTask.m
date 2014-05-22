//
//  INAddRemoveTagsChange.m
//  InboxFramework
//
//  Created by Ben Gotow on 5/16/14.
//  Copyright (c) 2014 Inbox. All rights reserved.
//

#import "INAddRemoveTagsTask.h"
#import "INThread.h"
#import "INMessage.h"
#import "INDatabaseManager.h"

@implementation INAddRemoveTagsTask


- (NSMutableArray *)tagIDsToAdd
{
    if (!self.data[@"tagIDsToAdd"])
        [self.data setObject: [NSMutableArray array] forKey:@"tagIDsToAdd"];
    return self.data[@"tagIDsToAdd"];
}

- (NSMutableArray *)tagIDsToRemove
{
    if (!self.data[@"tagIDsToRemove"])
        [self.data setObject: [NSMutableArray array] forKey:@"tagIDsToRemove"];
    return self.data[@"tagIDsToRemove"];
}

- (INThread*)thread
{
    if ([self.model isKindOfClass: [INThread class]])
        return (INThread*)self.model;
    if ([self.model isKindOfClass: [INMessage class]])
        return [(INMessage*)self.model thread];
    return nil;
}

- (NSURLRequest *)buildAPIRequest
{
    NSAssert([self thread], @"INSaveDraftChange asked to buildRequest with no access to a thread model!");
	NSAssert([[self thread] namespaceID], @"INSaveDraftChange asked to buildRequest with no namespace!");

	NSError * error = nil;
    NSString * path = [[self thread] resourceAPIPath];
    NSString * url = [[NSURL URLWithString:path relativeToURL:[INAPIManager shared].baseURL] absoluteString];
    
    NSMutableDictionary * params = [NSMutableDictionary dictionary];
    [params setObject:[self tagIDsToAdd] forKey:@"add_tags"];
    [params setObject:[self tagIDsToRemove] forKey:@"remove_tags"];
    
	return [[[INAPIManager shared] requestSerializer] requestWithMethod:@"POST" URLString:url parameters:params error:&error];
}

- (void)applyLocally
{
    NSMutableArray * newTagIDs = [NSMutableArray arrayWithArray: [[self thread] tagIDs]];
    [newTagIDs addObjectsFromArray: self.tagIDsToAdd];
    [newTagIDs removeObjectsInArray: self.tagIDsToRemove];
    [[self thread] setTagIDs: newTagIDs];
    [[INDatabaseManager shared] persistModel: [self thread]];
}

- (void)rollbackLocally
{
    NSMutableArray * newTagIDs = [NSMutableArray arrayWithArray: [[self thread] tagIDs]];
    [newTagIDs removeObjectsInArray: self.tagIDsToAdd];
    [newTagIDs addObjectsFromArray: self.tagIDsToRemove];
    [[self thread] setTagIDs: newTagIDs];
    [[INDatabaseManager shared] persistModel: [self thread]];
}

- (void)handleSuccess:(AFHTTPRequestOperation *)operation withResponse:(id)responseObject
{
    if ([responseObject isKindOfClass: [NSDictionary class]]) {
        [[self thread] updateWithResourceDictionary: responseObject];
        [[INDatabaseManager shared] persistModel: [self thread]];
    }
}

@end
