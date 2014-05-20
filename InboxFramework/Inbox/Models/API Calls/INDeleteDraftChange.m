//
//  INDeleteDraftChange.m
//  InboxFramework
//
//  Created by Ben Gotow on 5/20/14.
//  Copyright (c) 2014 Inbox. All rights reserved.
//

#import "INDeleteDraftChange.h"

@implementation INDeleteDraftChange

- (NSURLRequest *)buildRequest
{
    NSAssert(self.model, @"INDeleteDraftChange asked to buildRequest with no model!");
	NSAssert([self.model namespaceID], @"INDeleteDraftChange asked to buildRequest with no namespace!");
	
    NSError * error = nil;
    NSString * url = [[NSURL URLWithString:[self.model resourceAPIPath] relativeToURL:[INAPIManager shared].baseURL] absoluteString];
	return [[[INAPIManager shared] requestSerializer] requestWithMethod:@"DELETE" URLString:url parameters:[self.model resourceDictionary] error:&error];
}

- (void)handleSuccess:(AFHTTPRequestOperation *)operation withResponse:(id)responseObject
{
    INMessage * message = (INMessage *)[self model];
    INThread * oldThread = [message thread];
    
    if ([responseObject isKindOfClass: [NSDictionary class]])
        [message updateWithResourceDictionary: responseObject];
    
    // if we've orphaned a temporary thread object, go ahead and clean it up
    if ([[oldThread ID] isEqualToString: [[message thread] ID]] == NO) {
        if ([oldThread isUnsynced])
            [[INDatabaseManager shared] unpersistModel: oldThread];
    }
    
    // if we've created a new thread, fetch it so we have more than it's ID
    if ([[message thread] namespaceID] == nil)
        [[message thread] reload: NULL];
}

- (void)applyLocally
{
    INMessage * message = (INMessage *)[self model];
    INThread * thread = [message thread];
    [[INDatabaseManager shared] unpersistModel: message];
    
    if (thread) {
        NSMutableArray * messageIDs = [[thread messageIDs] mutableCopy];
        [messageIDs removeObject: [self.model ID]];
        
        if ([messageIDs count]) {
            [thread setMessageIDs: messageIDs];
            [[INDatabaseManager shared] persistModel: thread];
        } else {
            [[INDatabaseManager shared] unpersistModel: thread];

        }
    }
}

- (void)rollbackLocally
{
    INMessage * message = (INMessage *)[self model];
    [[INDatabaseManager shared] persistModel: message];
    
    INThread * thread = [message thread];

    if ([thread isUnsynced]) {
        [thread setSubject: [message subject]];
        [thread setParticipants: [message to]];
        [thread setTagIDs: @[INTagIDDraft]];
        [thread setSnippet: [message body]];
        [thread setMessageIDs: @[[message ID]]];
        [thread setUpdatedAt: [NSDate date]];
        [thread setLastMessageDate: [NSDate date]];
    }
    
    if (thread) {
        NSMutableArray * messageIDs = [[thread messageIDs] mutableCopy];
        [messageIDs addObject: [self.model ID]];
        [thread setMessageIDs: messageIDs];
        [[INDatabaseManager shared] persistModel: thread];
    }
}

@end
