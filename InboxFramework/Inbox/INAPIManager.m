//
//  INAPIManager.m
//  BigSur
//
//  Created by Ben Gotow on 4/24/14.
//  Copyright (c) 2014 Inbox. All rights reserved.
//

#import "INAPIManager.h"
#import "INAPITask.h"
#import "INNamespace.h"
#import "INModelResponseSerializer.h"
#import "INDatabaseManager.h"
#import "FMResultSet+INModelQueries.h"

#if DEBUG
  #define API_URL		[NSURL URLWithString:@"http://localhost:5555/"]
#else
  #define API_URL		[NSURL URLWithString:@"http://localhost:5555/"]
#endif

#define OPERATIONS_FILE [@"~/Documents/operations.plist" stringByExpandingTildeInPath]
#define AUTH_TOKEN_KEY  @"inbox-auth-token"

__attribute__((constructor))
static void initialize_INAPIManager() {
    [INAPIManager shared];
}

@implementation INAPIManager

+ (INAPIManager *)shared
{
	static INAPIManager * sharedManager = nil;
	static dispatch_once_t onceToken;

	dispatch_once(&onceToken, ^{
		sharedManager = [[INAPIManager alloc] init];
	});
	return sharedManager;
}

- (id)init
{
	self = [super initWithBaseURL: API_URL];
	if (self) {
        [[self operationQueue] setMaxConcurrentOperationCount: 5];
		[self setResponseSerializer:[AFJSONResponseSerializer serializerWithReadingOptions:NSJSONReadingAllowFragments]];
		[self setRequestSerializer:[AFJSONRequestSerializer serializerWithWritingOptions:NSJSONWritingPrettyPrinted]];
		[self.requestSerializer setCachePolicy: NSURLRequestReloadRevalidatingCacheData];
		
        [[AFNetworkActivityIndicatorManager sharedManager] setEnabled:YES];

        typeof(self) __weak __self = self;
		self.reachabilityManager = [AFNetworkReachabilityManager managerForDomain: [API_URL host]];
		[self.reachabilityManager setReachabilityStatusChangeBlock:^(AFNetworkReachabilityStatus status) {
			BOOL hasConnection = (status == AFNetworkReachabilityStatusReachableViaWiFi) || (status == AFNetworkReachabilityStatusReachableViaWWAN);
			BOOL hasSuspended = __self.taskQueueSuspended;
            
			if (hasConnection && hasSuspended)
				[__self setTaskQueueSuspended: NO];
			else if (!hasConnection && !hasSuspended)
				[__self setTaskQueueSuspended: YES];
		}];
		[self.reachabilityManager startMonitoring];

        NSString * token = [[NSUserDefaults standardUserDefaults] objectForKey:AUTH_TOKEN_KEY];
        if (token) {
            // refresh the namespaces available to our token if we have one
            [self.requestSerializer setAuthorizationHeaderFieldWithUsername:token password:nil];
            [self fetchNamespaces: NULL];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [self loadTasks];
        });
    }
	return self;
}

- (void)loadTasks
{
    _taskQueue = [NSMutableArray array];
	@try {
		[_taskQueue addObjectsFromArray: [NSKeyedUnarchiver unarchiveObjectWithFile:OPERATIONS_FILE]];
	}
	@catch (NSException *exception) {
		NSLog(@"Unable to unserialize tasks: %@", [exception description]);
		[[NSFileManager defaultManager] removeItemAtPath:OPERATIONS_FILE error:NULL];
	}
    
    NSArray * toStart = [_taskQueue copy];
	for (INAPITask * task in toStart)
        [self tryStartTask: task];
	
    [[NSNotificationCenter defaultCenter] postNotificationName:INTaskQueueChangedNotification object:nil];
    [self describeTasks];
}

- (void)saveTasks
{
	if (![NSKeyedArchiver archiveRootObject:_taskQueue toFile:OPERATIONS_FILE])
		NSLog(@"Writing pending changes to disk failed? Path may be invalid.");
}

- (NSArray*)taskQueue
{
    return [_taskQueue copy];
}

- (void)setTaskQueueSuspended:(BOOL)suspended
{
    NSLog(@"Change processing is %@.", (suspended ? @"off" : @"on"));

    _taskQueueSuspended = suspended;
    [[NSNotificationCenter defaultCenter] postNotificationName:INTaskQueueChangedNotification object:nil];

	if (!suspended) {
        for (INAPITask * change in _taskQueue)
            [self tryStartTask: change];
    }
}

- (BOOL)queueTask:(INAPITask *)change
{
    NSAssert([NSThread isMainThread], @"Sorry, INAPIManager's change queue is not threadsafe. Please call this method on the main thread.");
    
    for (NSInteger ii = [_taskQueue count] - 1; ii >= 0; ii -- ) {
        INAPITask * a = [_taskQueue objectAtIndex: ii];

        // Can the change we're currently queuing obviate the need for A? If it
        // can, there's no need to make the API call for A.
        // Example: DeleteDraft cancels pending SaveDraft or SendDraft
        if (![a inProgress] && [change canCancelPendingTask: a]) {
            NSLog(@"%@ CANCELLING CHANGE %@", NSStringFromClass([change class]), NSStringFromClass([a class]));
            [a setState: INAPITaskStateCancelled];
            [_taskQueue removeObjectAtIndex: ii];
        }
        
        // Can the change we're currently queueing happen after A? We can't cancel
        // A since it's already started.
        // Example: DeleteDraft can't be queued if SendDraft has started.
        if ([a inProgress] && ![change canStartAfterTask: a]) {
            NSLog(@"%@ CANNOT BE QUEUED AFTER %@", NSStringFromClass([change class]), NSStringFromClass([a class]));
            return NO;
        }
    }

    // Local effects always take effect immediately
    [change applyLocally];

    // Queue the task, and try to start it after a short delay. The delay is purely for
    // asthethic purposes. Things almost always look better when they appear to take a
    // short amount of time, and lots of animations look like shit when they happen too
    // fast. This ensures that, for example, the "draft synced" passive reload doesn't
    // happen while the "draft saved!" animation is still playing, which results in the
    // animation being disrupted. Unless there's really a good reason to make developers
    // worry about stuff like that themselves, let's keep this here.
    [_taskQueue addObject: change];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self tryStartTask: change];
    });

    [[NSNotificationCenter defaultCenter] postNotificationName:INTaskQueueChangedNotification object:nil];
    [self describeTasks];
    [self saveTasks];

    return YES;
}

- (void)describeTasks
{
	NSMutableString * description = [NSMutableString string];
	[description appendFormat:@"\r---------- Tasks (%lu) Suspended: %d -----------", (unsigned long)_taskQueue.count, _taskQueueSuspended];

	for (INAPITask * change in _taskQueue) {
		NSString * dependencyIDs = [[[change dependenciesIn: _taskQueue] valueForKey: @"description"] componentsJoinedByString:@"\r          "];
        NSString * stateString = @[@"waiting", @"in progress", @"finished", @"server-unreachable", @"server-rejected"][[change state]];
		[description appendFormat:@"\r%@\r     - state: %@ \r     - error: %@ \r     - dependencies: %@", [change description], stateString, [change error], dependencyIDs];
	}
    [description appendFormat:@"\r-------- ------ ------ ------ ------ ---------"];

	NSLog(@"%@", description);
}

- (void)retryTasks
{
    for (INAPITask * task in _taskQueue) {
        if ([task state] == INAPITaskStateServerUnreachable)
            [task setState: INAPITaskStateWaiting];
        [self tryStartTask: task];
    }
}

- (BOOL)tryStartTask:(INAPITask *)change
{
    if ([change state] != INAPITaskStateWaiting)
        return NO;
    
    if (_changesInProgress > 5)
        return NO;
    
    if (_taskQueueSuspended)
        return NO;
    
    if ([[change dependenciesIn: _taskQueue] count] > 0)
        return NO;

    _changesInProgress += 1;
    [change applyRemotelyWithCallback: ^(INAPITask * change, BOOL finished) {
        _changesInProgress -= 1;
        
        if (finished) {
            [_taskQueue removeObject: change];
            for (INAPITask * change in _taskQueue)
                if ([self tryStartTask: change])
                    break;
        }

        [[NSNotificationCenter defaultCenter] postNotificationName:INTaskQueueChangedNotification object:nil];
        [self describeTasks];
        [self saveTasks];
    }];
    return YES;
}


#pragma Authentication

- (BOOL)isSignedIn
{
    return ([[NSUserDefaults standardUserDefaults] objectForKey:AUTH_TOKEN_KEY] != nil);
}

- (void)signIn:(ErrorBlock)completionBlock
{
    NSString * authToken = @"whatevs";
    
	[[self requestSerializer] setAuthorizationHeaderFieldWithUsername:authToken password:@""];
    [self fetchNamespaces:^(NSArray *namespaces, NSError *error) {
        if (error) {
            [[self requestSerializer] clearAuthorizationHeader];
            completionBlock(error);
        } else {
            [[NSUserDefaults standardUserDefaults] setObject:authToken forKey:AUTH_TOKEN_KEY];
            [[NSUserDefaults standardUserDefaults] synchronize];
            [[NSNotificationCenter defaultCenter] postNotificationName:INAuthenticationChangedNotification object:nil];
            completionBlock(nil);
        }
    }];
}

- (void)signOut
{
    [[NSUserDefaults standardUserDefaults] removeObjectForKey: AUTH_TOKEN_KEY];
    [[NSUserDefaults standardUserDefaults] synchronize];
    
	[_taskQueue removeAllObjects];
    [[self requestSerializer] clearAuthorizationHeader];
    [[INDatabaseManager shared] resetDatabase];
    _namespaces = nil;
    
    [[NSNotificationCenter defaultCenter] postNotificationName:INTaskQueueChangedNotification object:nil];
    [[NSNotificationCenter defaultCenter] postNotificationName:INNamespacesChangedNotification object:nil];
    [[NSNotificationCenter defaultCenter] postNotificationName:INAuthenticationChangedNotification object:nil];
}

- (void)fetchNamespaces:(AuthenticationBlock)completionBlock
{
    NSLog(@"Fetching Namespaces (/n/)");
    AFHTTPRequestOperation * operation = [self GET:@"/n/" parameters:nil success:^(AFHTTPRequestOperation *operation, id namespaces) {
        // broadcast a notification about this change
        _namespaces = namespaces;
        [[NSNotificationCenter defaultCenter] postNotificationName:INNamespacesChangedNotification object:nil];
        if (completionBlock)
            completionBlock(namespaces, nil);

	} failure:^(AFHTTPRequestOperation *operation, NSError *error) {
		if (completionBlock)
			completionBlock(nil, error);
	}];
    
    INModelResponseSerializer * serializer = [[INModelResponseSerializer alloc] initWithModelClass: [INNamespace class]];
    [operation setResponseSerializer: serializer];
}

- (NSArray*)namespaces
{
	if (!_namespaces) {
        [[INDatabaseManager shared] selectModelsOfClassSync:[INNamespace class] withQuery:@"SELECT * FROM INNamespace" andParameters:nil andCallback:^(NSArray *objects) {
            _namespaces = objects;
        }];
    }
    
    if ([_namespaces count] == 0)
        return nil;
    
	return _namespaces;
}

- (NSArray*)namespaceEmailAddresses
{
    return [[self namespaces] valueForKey:@"emailAddress"];
}

@end
