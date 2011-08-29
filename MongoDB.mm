//
//  Mongo.mm
//  MongoHub
//
//  Created by Syd on 10-4-25.
//  Copyright 2010 MusicPeace.ORG. All rights reserved.
//

#import "MongoDB.h"
#import "NSString+Extras.h"
#import <RegexKit/RegexKit.h>
#import <mongo/client/dbclient.h>
#import <mongo/util/sock.h>

extern "C" {
    void MongoDB_enableIPv6(BOOL flag)
    {
        mongo::enableIPv6((flag == YES)?true:false);
    }
}

@interface MongoDB()

@property(nonatomic, readwrite, assign, getter=isConnected) BOOL connected;

- (BOOL)authenticateSynchronouslyWithDatabaseName:(NSString *)databaseName userName:(NSString *)user password:(NSString *)password errorMessage:(NSString **)errorMessage;
- (BOOL)authUser:(NSString *)user 
            pass:(NSString *)pass 
        database:(NSString *)db;

@end

@implementation MongoDB

@synthesize connected = _connected, delegate = _delegate, serverStatus = _serverStatus;

- (id)init
{
    if ((self = [super init]) != nil) {
        _operationQueue = [[NSOperationQueue alloc] init];
        [_operationQueue setMaxConcurrentOperationCount:1];
        _serverStatus = [[NSMutableArray alloc] init];
        _databaseList = [[NSMutableDictionary alloc] init];
    }
    return self;
}

- (void)dealloc
{
    if (conn) {
        delete conn;
    }
    if (repl_conn) {
        delete repl_conn;
    }
    [_operationQueue release];
    [_serverStatus release];
    [_databaseList release];
    [super dealloc];
}

- (BOOL)authenticateSynchronouslyWithDatabaseName:(NSString *)databaseName userName:(NSString *)user password:(NSString *)password errorMessage:(NSString **)errorMessage
{
    BOOL result = YES;
    
    if ([user length] > 0 && [password length] > 0) {
        if (*errorMessage != NULL) {
            *errorMessage = nil;
        }
        try {
            std::string errmsg;
            std::string dbname;
            
            if ([databaseName length] == 0) {
                dbname = [databaseName UTF8String];
            }else {
                dbname = "admin";
            }
            if (repl_conn) {
                result = repl_conn->auth(dbname, std::string([user UTF8String]), std::string([password UTF8String]), errmsg) == true;
            } else {
                result = conn->auth(dbname, std::string([user UTF8String]), std::string([password UTF8String]), errmsg) == true;
            }
            
            if (result && *errorMessage != NULL) {
                *errorMessage = [NSString stringWithUTF8String:errmsg.c_str()];
            }
        } catch (mongo::DBException &e) {
            if (*errorMessage) {
                *errorMessage = [NSString stringWithUTF8String:e.what()];
            }
            result = NO;
        }
    }
    return result;
}

- (void)connectCallback:(NSString *)errorMessage
{
    if (errorMessage && [_delegate respondsToSelector:@selector(mongoDBConnectionFailed:withErrorMessage:)]) {
        [_delegate mongoDBConnectionFailed:self withErrorMessage:errorMessage];
    } else if (errorMessage == nil && [_delegate respondsToSelector:@selector(mongoDBConnectionSucceded:)]) {
        [_delegate mongoDBConnectionSucceded:self];
    }
    self.connected = (errorMessage == nil);
}

- (NSOperation *)connectWithHostName:(NSString *)host databaseName:(NSString *)databaseName userName:(NSString *)userName password:(NSString *)password
{
    NSBlockOperation *operation;
    NSAssert(conn == NULL, @"already connected");
    NSAssert(repl_conn == NULL, @"already connected");
    
    conn = new mongo::DBClientConnection;
    operation = [NSBlockOperation blockOperationWithBlock:^{
        std::string error;
        NSString *errorMessage = nil;
        
        if (conn->connect([host UTF8String], error) == false) {
            errorMessage = [NSString stringWithUTF8String:error.c_str()];
        } else if ([userName length] > 0) {
            [self authenticateSynchronouslyWithDatabaseName:databaseName userName:userName password:password errorMessage:&errorMessage];
        }
        [self performSelectorOnMainThread:@selector(connectCallback:) withObject:errorMessage waitUntilDone:NO];
    }];
    [_operationQueue addOperation:operation];
    return operation;
}

- (NSOperation *)connectWithReplicaName:(NSString *)name hosts:(NSArray *)hosts databaseName:(NSString *)databaseName userName:(NSString *)userName password:(NSString *)password
{
    NSBlockOperation *operation;
    NSAssert(conn == NULL, @"already connected");
    NSAssert(repl_conn == NULL, @"already connected");
    
    std::vector<mongo::HostAndPort> servers;
    for (NSString *h in hosts) {
        mongo::HostAndPort server([h UTF8String]);
        servers.push_back(server);
    }
    repl_conn = new mongo::DBClientReplicaSet::DBClientReplicaSet([name UTF8String], servers);
    operation = [NSBlockOperation blockOperationWithBlock:^{
        NSString *errorMessage = nil;
        
        if (repl_conn->connect() == false) {
            errorMessage = @"Connection Failed";
        } else if ([userName length] > 0) {
            [self authenticateSynchronouslyWithDatabaseName:databaseName userName:userName password:password errorMessage:&errorMessage];
        }
        [self performSelectorOnMainThread:@selector(connectCallback:) withObject:errorMessage waitUntilDone:NO];
    }];
    [_operationQueue addOperation:operation];
    return operation;
}

- (BOOL)authUser:(NSString *)user 
            pass:(NSString *)pass 
        database:(NSString *)db
{
    try {
        std::string errmsg;
        std::string dbname;
        if ([db isPresent]) {
            dbname = [db UTF8String];
        }else {
            dbname = "admin";
        }
        BOOL ok;
        if (repl_conn) {
            ok = repl_conn->auth(dbname, std::string([user UTF8String]), std::string([pass UTF8String]), errmsg);
        }else {
            ok = conn->auth(dbname, std::string([user UTF8String]), std::string([pass UTF8String]), errmsg);
        }
        
        if (!ok) {
            NSRunAlertPanel(@"Error", [NSString stringWithUTF8String:errmsg.c_str()], @"OK", nil, nil);
        }
        return ok;
    }catch (mongo::DBException &e) {
        NSRunAlertPanel(@"Error", [NSString stringWithUTF8String:e.what()], @"OK", nil, nil);
    }
    return false;
}

- (void)fetchDatabaseListCallback:(NSDictionary *)info
{
    NSArray *list;
    
    list = [info objectForKey:@"databaseList"];
    [self willChangeValueForKey:@"databaseList"];
    if (list) {
        for (NSString *databaseName in list) {
            if (![_databaseList objectForKey:databaseName]) {
                [_databaseList setObject:[NSMutableDictionary dictionary] forKey:databaseName];
            }
        }
        for (NSString *databaseName in [_databaseList allKeys]) {
            if (![list containsObject:databaseName]) {
                [_databaseList removeObjectForKey:databaseName];
            }
        }
    } else {
        [_databaseList removeAllObjects];
    }
    [self didChangeValueForKey:@"databaseList"];
    if ([_delegate respondsToSelector:@selector(mongoDB:databaseListFetched:withErrorMessage:)]) {
        [_delegate mongoDB:self databaseListFetched:list withErrorMessage:[info objectForKey:@"errorMessage"]];
    }
}

- (NSOperation *)fetchDatabaseList
{
    NSBlockOperation *operation;
    
    operation = [NSBlockOperation blockOperationWithBlock:^{
        try {
            std::list<std::string> dbs;
            if (repl_conn) {
                dbs = repl_conn->getDatabaseNames();
            } else {
                dbs = conn->getDatabaseNames();
            }
            NSMutableArray *dblist = [[NSMutableArray alloc] initWithCapacity:dbs.size()];
            for (std::list<std::string>::iterator it=dbs.begin();it!=dbs.end();++it) {
                NSString *db = [[NSString alloc] initWithUTF8String:(*it).c_str()];
                [dblist addObject:db];
                [db release];
            }
            [self performSelectorOnMainThread:@selector(fetchDatabaseListCallback:) withObject:[NSMutableDictionary dictionaryWithObjectsAndKeys:dblist, @"databaseList", nil] waitUntilDone:NO];
            [dblist release];
        } catch( mongo::DBException &e ) {
            [self performSelectorOnMainThread:@selector(fetchDatabaseListCallback:) withObject:[NSMutableDictionary dictionaryWithObjectsAndKeys:[NSString stringWithUTF8String:e.what()], @"errorMessage", nil] waitUntilDone:NO];
        }
    }];
    [_operationQueue addOperation:operation];
    return operation;
}

- (void)fetchServerStatusCallback:(NSDictionary *)result
{
    NSArray *serverStatus;
    
    serverStatus = [result objectForKey:@"serverStatus"];
    [self willChangeValueForKey:@"serverStatus"];
    [_serverStatus removeAllObjects];
    [_serverStatus addObjectsFromArray:serverStatus];
    [self didChangeValueForKey:@"serverStatus"];
    if ([_delegate respondsToSelector:@selector(mongoDB:serverStatusFetched:withErrorMessage:)]) {
        [_delegate mongoDB:self serverStatusFetched:serverStatus withErrorMessage:[result objectForKey:@"errorMessage"]];
    }
}

- (NSOperation *)fetchServerStatus
{
    NSBlockOperation *operation;
    
    operation = [NSBlockOperation blockOperationWithBlock:^{
        try {
            mongo::BSONObj retval;
            if (repl_conn) {
                repl_conn->runCommand("admin", BSON("serverStatus"<<1), retval);
            }else {
                conn->runCommand("admin", BSON("serverStatus"<<1), retval);
            }
            [self performSelectorOnMainThread:@selector(fetchServerStatusCallback:) withObject:[NSMutableDictionary dictionaryWithObjectsAndKeys:[[self class] bsonDictWrapper:retval], @"serverStatus", nil] waitUntilDone:NO];
        } catch (mongo::DBException &e) {
            [self performSelectorOnMainThread:@selector(fetchServerStatusCallback:) withObject:[NSMutableDictionary dictionaryWithObjectsAndKeys:[NSString stringWithUTF8String:e.what()], @"errorMessage", nil] waitUntilDone:NO];
        }
    }];
    [_operationQueue addOperation:operation];
    return operation;
}

- (void)fetchCollectionListCallback:(NSDictionary *)info
{
    NSArray *collectionList;
    NSString *databaseName;
    
    databaseName = [info objectForKey:@"databaseName"];
    collectionList = [info objectForKey:@"collectionList"];
    [self willChangeValueForKey:@"databaseList"];
    if (![_databaseList objectForKey:databaseName]) {
        [_databaseList setObject:[NSMutableDictionary dictionary] forKey:databaseName];
    }
    [[_databaseList objectForKey:databaseName] setObject:collectionList forKey:@"collectionList"];
    [self didChangeValueForKey:@"databaseList"];
    if ([_delegate respondsToSelector:@selector(mongoDB:collectionListFetched:withDatabaseName:errorMessage:)]) {
        [_delegate mongoDB:self collectionListFetched:collectionList withDatabaseName:databaseName errorMessage:[info objectForKey:@"errorMessage"]];
    }
}

- (NSOperation *)fetchCollectionListWithDatabaseName:(NSString *)databaseName userName:(NSString *)user password:(NSString *)password
{
    NSBlockOperation *operation;
    
    operation = [NSBlockOperation blockOperationWithBlock:^{
        try {
            NSString *errorMessage = nil;
            
            if (![self authenticateSynchronouslyWithDatabaseName:databaseName userName:user password:password errorMessage:&errorMessage]) {
                [self performSelectorOnMainThread:@selector(fetchCollectionListCallback:) withObject:[NSMutableDictionary dictionaryWithObjectsAndKeys:databaseName, @"databaseName", errorMessage, @"errorMessage", nil] waitUntilDone:NO];
            } else {
                std::list<std::string> collections;
                if (repl_conn) {
                    collections = repl_conn->getCollectionNames([databaseName UTF8String]);
                }else {
                    collections = conn->getCollectionNames([databaseName UTF8String]);
                }
                
                NSMutableArray *collectionList = [[NSMutableArray alloc] initWithCapacity:collections.size() ];
                unsigned int istartp = [databaseName length] + 1;
                for (std::list<std::string>::iterator it=collections.begin();it!=collections.end();++it) {
                    NSString *collection = [[NSString alloc] initWithUTF8String:(*it).c_str()];
                    [collectionList addObject:[collection substringWithRange:NSMakeRange( istartp, [collection length]-istartp )] ];
                    [collection release];
                }
                [self performSelectorOnMainThread:@selector(fetchCollectionListCallback:) withObject:[NSMutableDictionary dictionaryWithObjectsAndKeys:databaseName, @"databaseName", collectionList, @"collectionList", nil] waitUntilDone:NO];
                [collectionList release];
            }
        } catch (mongo::DBException &e) {
            [self performSelectorOnMainThread:@selector(fetchCollectionListCallback:) withObject:[NSMutableDictionary dictionaryWithObjectsAndKeys:databaseName, @"databaseName", [NSString stringWithUTF8String:e.what()], @"errorMessage", nil] waitUntilDone:NO];
        }
    }];
    [_operationQueue addOperation:operation];
    return operation;
}

- (void)fetchDatabaseStatsCallback:(NSDictionary *)info
{
    NSArray *databaseStats;
    NSString *databaseName;
    
    databaseName = [info objectForKey:@"databaseName"];
    databaseStats = [info objectForKey:@"databaseStats"];
    [self willChangeValueForKey:@"databaseList"];
    if (![_databaseList objectForKey:databaseName]) {
        [_databaseList setObject:[NSMutableDictionary dictionary] forKey:databaseName];
    }
    [[_databaseList objectForKey:databaseName] setObject:databaseStats forKey:@"databaseStats"];
    [self didChangeValueForKey:@"databaseList"];
    if ([_delegate respondsToSelector:@selector(mongoDB:databaseStatsFetched:withDatabaseName:errorMessage:)]) {
        [_delegate mongoDB:self databaseStatsFetched:databaseStats withDatabaseName:databaseName errorMessage:[info objectForKey:@"errorMessage"]];
    }
}

- (NSOperation *)fetchDatabaseStatsWithDatabaseName:(NSString *)databaseName userName:(NSString *)user password:(NSString *)password
{
    NSBlockOperation *operation;
    
    operation = [NSBlockOperation blockOperationWithBlock:^{
        try {
            NSString *errorMessage = nil;
            
            if (![self authenticateSynchronouslyWithDatabaseName:databaseName userName:user password:password errorMessage:&errorMessage]) {
                [self performSelectorOnMainThread:@selector(fetchDatabaseStatsCallback:) withObject:[NSMutableDictionary dictionaryWithObjectsAndKeys:databaseName, @"databaseName", errorMessage, @"errorMessage", nil] waitUntilDone:NO];
            } else {
                mongo::BSONObj retval;
                if (repl_conn) {
                    repl_conn->runCommand([databaseName UTF8String], BSON("dbstats"<<1), retval);
                }else {
                    conn->runCommand([databaseName UTF8String], BSON("dbstats"<<1), retval);
                }
                [self performSelectorOnMainThread:@selector(fetchDatabaseStatsCallback:) withObject:[NSMutableDictionary dictionaryWithObjectsAndKeys:databaseName, @"databaseName", [[self class] bsonDictWrapper:retval], @"databaseStats", nil] waitUntilDone:NO];
            }
        }catch (mongo::DBException &e) {
            [self performSelectorOnMainThread:@selector(fetchDatabaseStatsCallback:) withObject:[NSMutableDictionary dictionaryWithObjectsAndKeys:databaseName, @"databaseName", [NSString stringWithUTF8String:e.what()], @"errorMessage", nil] waitUntilDone:NO];
        }
    }];
    [_operationQueue addOperation:operation];
    return operation;
}

- (void) dropDB:(NSString *)dbname 
                        user:(NSString *)user 
                    password:(NSString *)password 
{
    try {
        if ([user length]>0 && [password length]>0) {
            BOOL ok = [self authUser:user pass:password database:dbname];
            if (!ok) {
                return;
            }
        }
        if (repl_conn) {
            repl_conn->dropDatabase([dbname UTF8String]);
        }else {
            conn->dropDatabase([dbname UTF8String]);
        }
        NSLog(@"Drop DB: %@", dbname);
    }catch (mongo::DBException &e) {
        NSRunAlertPanel(@"Error", [NSString stringWithUTF8String:e.what()], @"OK", nil, nil);
    }
}

- (void)fetchCollectionStatsCallback:(NSDictionary *)info
{
    NSArray *collectionStats;
    NSString *databaseName;
    NSString *collectionName;
    
    databaseName = [info objectForKey:@"databaseName"];
    collectionName = [info objectForKey:@"collectionName"];
    collectionStats = [info objectForKey:@"collectionStats"];
    if ([_delegate respondsToSelector:@selector(mongoDB:collectionStatsFetched:withDatabaseName:collectionName:errorMessage:)]) {
        [_delegate mongoDB:self collectionStatsFetched:collectionStats withDatabaseName:databaseName collectionName:collectionName errorMessage:[info objectForKey:@"errorMessage"]];
    }
}

- (NSOperation *)fetchCollectionStatsWithCollectionName:(NSString *)collectionName databaseName:(NSString *)databaseName userName:(NSString *)user password:(NSString *)password
{
    NSBlockOperation *operation;
    
    operation = [NSBlockOperation blockOperationWithBlock:^{
        try {
            NSString *errorMessage = nil;
            
            if (![self authenticateSynchronouslyWithDatabaseName:databaseName userName:user password:password errorMessage:&errorMessage]) {
                [self performSelectorOnMainThread:@selector(fetchCollectionListCallback:) withObject:[NSMutableDictionary dictionaryWithObjectsAndKeys:databaseName, @"databaseName", collectionName, @"collectionName", errorMessage, @"errorMessage", nil] waitUntilDone:NO];
            } else {
                mongo::BSONObj retval;
                
                if (repl_conn) {
                    repl_conn->runCommand([databaseName UTF8String], BSON("collstats"<<[collectionName UTF8String]), retval);
                }else {
                    conn->runCommand([databaseName UTF8String], BSON("collstats"<<[collectionName UTF8String]), retval);
                }
                
                [self performSelectorOnMainThread:@selector(fetchCollectionStatsCallback:) withObject:[NSMutableDictionary dictionaryWithObjectsAndKeys:databaseName, @"databaseName", collectionName, @"collectionName", [[self class] bsonDictWrapper:retval], @"collectionStats", nil] waitUntilDone:NO];
            }
        } catch (mongo::DBException &e) {
            [self performSelectorOnMainThread:@selector(fetchCollectionStatsCallback:) withObject:[NSMutableDictionary dictionaryWithObjectsAndKeys:databaseName, @"databaseName", collectionName, @"collectionName", [NSString stringWithUTF8String:e.what()], @"errorMessage", nil] waitUntilDone:NO];
        }
    }];
    [_operationQueue addOperation:operation];
    return operation;
}


- (void)dropDatabaseCallback:(NSDictionary *)info
{
    NSString *databaseName;
    NSString *errorMessage;
    
    databaseName = [info objectForKey:@"databaseName"];
    errorMessage = [info objectForKey:@"errorMessage"];
    if ([_delegate respondsToSelector:@selector(mongoDB:databaseDropedWithName:errorMessage:)]) {
        [_delegate mongoDB:self databaseDropedWithName:databaseName errorMessage:errorMessage];
    }
}

- (NSOperation *)dropDatabaseWithName:(NSString *)databaseName userName:(NSString *)user password:(NSString *)password
{
    NSBlockOperation *operation;
    
    operation = [NSBlockOperation blockOperationWithBlock:^{
        try {
            NSString *errorMessage = nil;
            
            if (![self authenticateSynchronouslyWithDatabaseName:databaseName userName:user password:password errorMessage:&errorMessage]) {
                [self performSelectorOnMainThread:@selector(dropDatabaseCallback:) withObject:[NSMutableDictionary dictionaryWithObjectsAndKeys:databaseName, @"databaseName", errorMessage, @"errorMessage", nil] waitUntilDone:NO];
            } else {
                if (repl_conn) {
                    repl_conn->dropDatabase([databaseName UTF8String]);
                }else {
                    conn->dropDatabase([databaseName UTF8String]);
                }
                [self performSelectorOnMainThread:@selector(dropDatabaseCallback:) withObject:[NSMutableDictionary dictionaryWithObjectsAndKeys:databaseName, @"databaseName", nil] waitUntilDone:NO];
            }
        } catch (mongo::DBException &e) {
            [self performSelectorOnMainThread:@selector(dropDatabaseCallback:) withObject:[NSMutableDictionary dictionaryWithObjectsAndKeys:databaseName, @"databaseName", [NSString stringWithUTF8String:e.what()], @"errorMessage", nil] waitUntilDone:NO];
        }
    }];
    [_operationQueue addOperation:operation];
    return operation;
}

- (void)createCollectionCallback:(NSDictionary *)info
{
    NSString *collectionName;
    NSString *databaseName;
    NSString *errorMessage;
    
    collectionName = [info objectForKey:@"collectionName"];
    databaseName = [info objectForKey:@"databaseName"];
    errorMessage = [info objectForKey:@"errorMessage"];
    if ([_delegate respondsToSelector:@selector(mongoDB:collectionCreatedWithName:databaseName:errorMessage:)]) {
        [_delegate mongoDB:self collectionCreatedWithName:collectionName databaseName:databaseName errorMessage:errorMessage];
    }
}

- (NSOperation *)createCollectionWithName:(NSString *)collectionName databaseName:(NSString *)databaseName userName:(NSString *)user password:(NSString *)password
{
    NSBlockOperation *operation;
    
    operation = [NSBlockOperation blockOperationWithBlock:^{
        try {
            NSString *errorMessage = nil;
            
            if (![self authenticateSynchronouslyWithDatabaseName:databaseName userName:user password:password errorMessage:&errorMessage]) {
                [self performSelectorOnMainThread:@selector(createCollectionCallback:) withObject:[NSMutableDictionary dictionaryWithObjectsAndKeys:collectionName, @"collectionName", databaseName, @"databaseName", errorMessage, @"errorMessage", nil] waitUntilDone:NO];
            } else {
                NSString *col = [NSString stringWithFormat:@"%@.%@", databaseName, collectionName];
                if (repl_conn) {
                    repl_conn->createCollection([col UTF8String]);
                } else {
                    conn->createCollection([col UTF8String]);
                }
                [self performSelectorOnMainThread:@selector(createCollectionCallback:) withObject:[NSMutableDictionary dictionaryWithObjectsAndKeys:collectionName, @"collectionName", databaseName, @"databaseName", nil] waitUntilDone:NO];
            }
        } catch (mongo::DBException &e) {
            [self performSelectorOnMainThread:@selector(createCollectionCallback:) withObject:[NSMutableDictionary dictionaryWithObjectsAndKeys:collectionName, @"collectionName", databaseName, @"databaseName", [NSString stringWithUTF8String:e.what()], @"errorMessage", nil] waitUntilDone:NO];
        }
    }];
    [_operationQueue addOperation:operation];
    return operation;
}

- (void)dropCollectionCallback:(NSDictionary *)info
{
    NSString *collectionName;
    NSString *databaseName;
    NSString *errorMessage;
    
    collectionName = [info objectForKey:@"collectionName"];
    databaseName = [info objectForKey:@"databaseName"];
    errorMessage = [info objectForKey:@"errorMessage"];
    if ([_delegate respondsToSelector:@selector(mongoDB:collectionDropedWithName:databaseName:errorMessage:)]) {
        [_delegate mongoDB:self collectionDropedWithName:collectionName databaseName:databaseName errorMessage:errorMessage];
    }
}

- (NSOperation *)dropCollectionWithName:(NSString *)collectionName databaseName:(NSString *)databaseName userName:(NSString *)user password:(NSString *)password
{
    NSBlockOperation *operation;
    
    operation = [NSBlockOperation blockOperationWithBlock:^{
        try {
            NSString *errorMessage = nil;
            
            if (![self authenticateSynchronouslyWithDatabaseName:databaseName userName:user password:password errorMessage:&errorMessage]) {
                [self performSelectorOnMainThread:@selector(dropCollectionCallback:) withObject:[NSMutableDictionary dictionaryWithObjectsAndKeys:collectionName, @"collectionName", databaseName, @"databaseName", errorMessage, @"errorMessage", nil] waitUntilDone:NO];
            } else {
                NSString *col = [NSString stringWithFormat:@"%@.%@", databaseName, collectionName];
                if (repl_conn) {
                    repl_conn->dropCollection([col UTF8String]);
                } else {
                    conn->dropCollection([col UTF8String]);
                }
                [self performSelectorOnMainThread:@selector(dropCollectionCallback:) withObject:[NSMutableDictionary dictionaryWithObjectsAndKeys:collectionName, @"collectionName", databaseName, @"databaseName", nil] waitUntilDone:NO];
            }
        } catch (mongo::DBException &e) {
            [self performSelectorOnMainThread:@selector(dropCollectionCallback:) withObject:[NSMutableDictionary dictionaryWithObjectsAndKeys:collectionName, @"collectionName", databaseName, @"databaseName", [NSString stringWithUTF8String:e.what()], @"errorMessage", nil] waitUntilDone:NO];
        }
    }];
    [_operationQueue addOperation:operation];
    return operation;
}

- (NSArray *) findInDB:(NSString *)dbname 
                   collection:(NSString *)collectionname 
                         user:(NSString *)user 
                     password:(NSString *)password 
                     critical:(NSString *)critical 
                       fields:(NSString *)fields 
                         skip:(NSNumber *)skip 
                        limit:(NSNumber *)limit 
                         sort:(NSString *)sort
{
    try {
        if ([user length]>0 && [password length]>0) {
            BOOL ok = [self authUser:user pass:password database:dbname];
            if (!ok) {
                return nil;
            }
        }
        NSString *col = [NSString stringWithFormat:@"%@.%@", dbname, collectionname];
        mongo::BSONObj criticalBSON = mongo::fromjson([critical UTF8String]);
        mongo::BSONObj sortBSON = mongo::fromjson([sort UTF8String]);
        mongo::BSONObj fieldsToReturn;
        if ([fields isPresent]) {
            NSArray *keys = [[NSArray alloc] initWithArray:[fields componentsSeparatedByString:@","]];
            mongo::BSONObjBuilder builder;
            for (NSString *str in keys) {
                builder.append([str UTF8String], 1);
            }
            fieldsToReturn = builder.obj();
            /*try{
                fieldsToReturn = mongo::fromjson([jsFields UTF8String]);
            }catch (mongo::MsgAssertionException &e) {
                [keys release];
                NSRunAlertPanel(@"Error", [NSString stringWithUTF8String:e.what()], @"OK", nil, nil);
                return nil;
            }*/
            [keys release];
        }
        
        std::auto_ptr<mongo::DBClientCursor> cursor;
        if (repl_conn) {
            cursor = repl_conn->query(std::string([col UTF8String]), mongo::Query(criticalBSON).sort(sortBSON), [limit intValue], [skip intValue], &fieldsToReturn);
        }else {
            cursor = conn->query(std::string([col UTF8String]), mongo::Query(criticalBSON).sort(sortBSON), [limit intValue], [skip intValue], &fieldsToReturn);
        }
        NSMutableArray *response = [[NSMutableArray alloc] initWithCapacity:[limit intValue]];
        while( cursor->more() )
        {
            mongo::BSONObj b = cursor->next();
            mongo::BSONElement e;
            b.getObjectID (e);
            NSString *oid;
            NSString *oidType;
            if (e.type() == mongo::jstOID)
            {
                oidType = [[NSString alloc] initWithString:@"ObjectId"];
                oid = [[NSString alloc] initWithUTF8String:e.__oid().str().c_str()];
            }else {
                oidType = [[NSString alloc] initWithString:@"String"];
                oid = [[NSString alloc] initWithUTF8String:e.str().c_str()];
            }
            NSString *jsonString = [[NSString alloc] initWithUTF8String:b.jsonString(mongo::TenGen).c_str()];
            NSMutableString *jsonStringb = [[[NSMutableString alloc] initWithUTF8String:b.jsonString(mongo::TenGen, 1).c_str()] autorelease];
            if (jsonString == nil) {
                jsonString = @"";
            }
            if (jsonStringb == nil) {
                jsonStringb = [NSMutableString stringWithString:@""];
            }
            NSMutableArray *repArr = [[NSMutableArray alloc] initWithCapacity:4];
            id regx2 = [RKRegex regexWithRegexString:@"(Date\\(\\s\\d+\\s\\))" options:RKCompileCaseless];
            RKEnumerator *matchEnumerator2 = [jsonString matchEnumeratorWithRegex:regx2];
            while([matchEnumerator2 nextRanges] != NULL) {
                NSString *enumeratedStr=NULL;
                [matchEnumerator2 getCapturesWithReferences:@"$1", &enumeratedStr, nil];
                [repArr addObject:enumeratedStr];
            }
            NSMutableArray *oriArr = [[NSMutableArray alloc] initWithCapacity:4];
            id regx = [RKRegex regexWithRegexString:@"(Date\\(\\s+\"[^^]*?\"\\s+\\))" options:RKCompileCaseless];
            RKEnumerator *matchEnumerator = [jsonStringb matchEnumeratorWithRegex:regx];
            while([matchEnumerator nextRanges] != NULL) {
                NSString *enumeratedStr=NULL;
                [matchEnumerator getCapturesWithReferences:@"$1", &enumeratedStr, nil];
                [oriArr addObject:enumeratedStr];
            }
            for (unsigned int i=0; i<[repArr count]; i++) {
                jsonStringb = [NSMutableString stringWithString:[jsonStringb stringByReplacingOccurrencesOfString:[oriArr objectAtIndex:i] withString:[repArr objectAtIndex:i]]];
            }
            [oriArr release];
            [repArr release];
            NSMutableDictionary *item = [[NSMutableDictionary alloc] initWithCapacity:4];
            [item setObject:@"_id" forKey:@"name"];
            [item setObject:oidType forKey:@"type"];
            [item setObject:oid forKey:@"value"];
            [item setObject:jsonString forKey:@"raw"];
            [item setObject:jsonStringb forKey:@"beautified"];
            [item setObject:[[self class] bsonDictWrapper:b] forKey:@"child"];
            [response addObject:item];
            [jsonString release];
            [oid release];
            [oidType release];
            [item release];
        }
        NSLog(@"Find in db: %@.%@", dbname, collectionname);
        return [response autorelease];
    }catch (mongo::DBException &e) {
        NSRunAlertPanel(@"Error", [NSString stringWithUTF8String:e.what()], @"OK", nil, nil);
    }
    return nil;
}

- (void) saveInDB:(NSString *)dbname 
       collection:(NSString *)collectionname 
             user:(NSString *)user 
         password:(NSString *)password 
       jsonString:(NSString *)jsonString 
              _id:(NSString *)_id
{
    try {
        if ([user length]>0 && [password length]>0) {
            BOOL ok = [self authUser:user pass:password database:dbname];
            if (!ok) {
                return;
            }
        }
        NSString *col = [NSString stringWithFormat:@"%@.%@", dbname, collectionname];NSLog(@"%@", jsonString);NSLog(@"%@", _id);
        mongo::BSONObj fields = mongo::fromjson([jsonString UTF8String]);
        mongo::BSONObj critical = mongo::fromjson([[NSString stringWithFormat:@"{\"_id\":%@}", _id] UTF8String]);
        
        if (repl_conn) {
            repl_conn->update(std::string([col UTF8String]), critical, fields, false);
        }else {
            conn->update(std::string([col UTF8String]), critical, fields, false);
        }
        NSLog(@"save in db: %@.%@", dbname, collectionname);
    }catch (mongo::DBException &e) {
        NSRunAlertPanel(@"Error", [NSString stringWithUTF8String:e.what()], @"OK", nil, nil);
    }
}

- (void) updateInDB:(NSString *)dbname 
         collection:(NSString *)collectionname 
               user:(NSString *)user 
           password:(NSString *)password 
           critical:(NSString *)critical 
             fields:(NSString *)fields 
              upset:(NSNumber *)upset
{
    try {
        if ([user length]>0 && [password length]>0) {
            BOOL ok = [self authUser:user pass:password database:dbname];
            if (!ok) {
                return;
            }
        }
        NSString *col = [NSString stringWithFormat:@"%@.%@", dbname, collectionname];
        mongo::BSONObj criticalBSON = mongo::fromjson([critical UTF8String]);
        mongo::BSONObj fieldsBSON = mongo::fromjson([[NSString stringWithFormat:@"{$set:%@}", fields] UTF8String]);
        if (repl_conn) {
            repl_conn->update(std::string([col UTF8String]), criticalBSON, fieldsBSON, (bool)[upset intValue]);
        }else {
            conn->update(std::string([col UTF8String]), criticalBSON, fieldsBSON, (bool)[upset intValue]);
        }
        NSLog(@"Update in db: %@.%@", dbname, collectionname);
    }catch (mongo::DBException &e) {
        NSRunAlertPanel(@"Error", [NSString stringWithUTF8String:e.what()], @"OK", nil, nil);
    }
}

- (void) removeInDB:(NSString *)dbname 
         collection:(NSString *)collectionname 
               user:(NSString *)user 
           password:(NSString *)password 
           critical:(NSString *)critical
{
    try {
        if ([user length]>0 && [password length]>0) {
            BOOL ok = [self authUser:user pass:password database:dbname];
            if (!ok) {
                return;
            }
        }
        NSString *col = [NSString stringWithFormat:@"%@.%@", dbname, collectionname];
        mongo::BSONObj criticalBSON;
        if ([critical isPresent]) {
            try{
                criticalBSON = mongo::fromjson([critical UTF8String]);
            }catch (mongo::MsgAssertionException &e) {
                NSRunAlertPanel(@"Error", [NSString stringWithUTF8String:e.what()], @"OK", nil, nil);
                return;
            }
            if (repl_conn) {
                repl_conn->remove(std::string([col UTF8String]), criticalBSON);
            }else {
                conn->remove(std::string([col UTF8String]), criticalBSON);
            }

        }
        NSLog(@"Remove in db: %@.%@", dbname, collectionname);
    }catch (mongo::DBException &e) {
        NSRunAlertPanel(@"Error", [NSString stringWithUTF8String:e.what()], @"OK", nil, nil);
    }
}

- (void) insertInDB:(NSString *)dbname 
         collection:(NSString *)collectionname 
               user:(NSString *)user 
           password:(NSString *)password 
           insertData:(NSString *)insertData
{
    try {
        if ([user length]>0 && [password length]>0) {
            BOOL ok = [self authUser:user pass:password database:dbname];
            if (!ok) {
                return;
            }
        }
        NSString *col = [NSString stringWithFormat:@"%@.%@", dbname, collectionname];
        mongo::BSONObj insertDataBSON;
        if ([insertData isPresent]) {
            try{
                insertDataBSON = mongo::fromjson([insertData UTF8String]);
            }catch (mongo::MsgAssertionException &e) {
                NSRunAlertPanel(@"Error", [NSString stringWithUTF8String:e.what()], @"OK", nil, nil);
                return;
            }
            if (repl_conn) {
                repl_conn->insert(std::string([col UTF8String]), insertDataBSON);
            }else {
                conn->insert(std::string([col UTF8String]), insertDataBSON);
            }

        }
        NSLog(@"Insert into db: %@.%@", dbname, collectionname);
    }catch (mongo::DBException &e) {
        NSRunAlertPanel(@"Error", [NSString stringWithUTF8String:e.what()], @"OK", nil, nil);
    }
}

- (void) insertInDB:(NSString *)dbname 
         collection:(NSString *)collectionname 
               user:(NSString *)user 
           password:(NSString *)password 
               data:(NSDictionary *)insertData 
             fields:(NSArray *)fields 
         fieldTypes:(NSDictionary *)fieldTypes 
{
    try {
        if ([user length]>0 && [password length]>0) {
            BOOL ok = [self authUser:user pass:password database:dbname];
            if (!ok) {
                return;
            }
        }
        NSString *col = [NSString stringWithFormat:@"%@.%@", dbname, collectionname];
        mongo::BSONObjBuilder b;
        NSDateFormatter *dateFormatter = [[NSDateFormatter alloc] init];
        for (int i=0; i<[fields count]; i++) {
            NSString *fieldName = [fields objectAtIndex:i];
            NSString *ft = [fieldTypes objectForKey:fieldName];
            id aValue = [insertData objectForKey:fieldName];
            if (aValue == [NSString nullValue])
                b.appendNull([fieldName UTF8String]);
            else if ([ft isEqualToString:@"varstring"] || [ft isEqualToString:@"string"])
                b.append([fieldName UTF8String], [aValue UTF8String]);
            else if ([ft isEqualToString:@"float"])
                b.append([fieldName UTF8String], [aValue floatValue]);
            else if ([ft isEqualToString:@"double"] || [ft isEqualToString:@"decimal"])
                b.append([fieldName UTF8String], [aValue doubleValue]);
            else if ([ft isEqualToString:@"longlong"])
                b.append([fieldName UTF8String], [aValue longLongValue]);
            else if ([ft isEqualToString:@"bool"])
                b.append([fieldName UTF8String], [aValue boolValue]);
            else if ([ft isEqualToString:@"int24"] || [ft isEqualToString:@"long"])
                b.append([fieldName UTF8String], [aValue intValue]);
            else if ([ft isEqualToString:@"tiny"] || [ft isEqualToString:@"short"])
                b.append([fieldName UTF8String], [aValue shortValue]);
            else if ([ft isEqualToString:@"date"]) {
                time_t timestamp = [aValue timeIntervalSince1970];
                b.appendDate([fieldName UTF8String], timestamp);
            }else if ([ft isEqualToString:@"datetime"] || [ft isEqualToString:@"timestamp"] || [ft isEqualToString:@"year"]) {
                time_t timestamp = [aValue timeIntervalSince1970];
                b.appendTimeT([fieldName UTF8String], timestamp);
            }else if ([ft isEqualToString:@"time"]) {
                [dateFormatter setDateFormat:@"HH:mm:ss"];
                NSDate *dateFromString = [dateFormatter dateFromString:aValue];
                time_t timestamp = [dateFromString timeIntervalSince1970];
                b.appendTimeT([fieldName UTF8String], timestamp);
            }else if ([ft isEqualToString:@"blob"]) {
                if ([aValue isKindOfClass:[NSString class]]) {
                    b.append([fieldName UTF8String], [aValue UTF8String]);
                }else {
                    int bLen = [aValue length];
                    mongo::BinDataType binType = (mongo::BinDataType)0;
                    const char *bData = (char *)[aValue bytes];
                    b.appendBinData([fieldName UTF8String], bLen, binType, bData);
                }
            }
        }
        [dateFormatter release];
        mongo::BSONObj insertDataBSON = b.obj();
        mongo::BSONObj emptyBSON;
        if (insertDataBSON == emptyBSON) {
            return;
        }
        if (repl_conn) {
            repl_conn->insert(std::string([col UTF8String]), insertDataBSON);
        }else {
            conn->insert(std::string([col UTF8String]), insertDataBSON);
        }
        NSLog(@"Find in db with filetype: %@.%@", dbname, collectionname);
    }catch (mongo::DBException &e) {
        NSRunAlertPanel(@"Error", [NSString stringWithUTF8String:e.what()], @"OK", nil, nil);
    }
}

- (NSArray *) indexInDB:(NSString *)dbname 
         collection:(NSString *)collectionname 
               user:(NSString *)user 
           password:(NSString *)password
{
    try {
        if ([user length]>0 && [password length]>0) {
            BOOL ok = [self authUser:user pass:password database:dbname];
            if (!ok) {
                return nil;
            }
        }
        NSString *col = [NSString stringWithFormat:@"%@.%@", dbname, collectionname];
        std::auto_ptr<mongo::DBClientCursor> cursor;
        if (repl_conn) {
            cursor = repl_conn->getIndexes(std::string([col UTF8String]));
        }else {
            cursor = conn->getIndexes(std::string([col UTF8String]));
        }
        NSMutableArray *response = [[NSMutableArray alloc] init];
        while( cursor->more() )
        {
            mongo::BSONObj b = cursor->next();
            NSString *name = [[NSString alloc] initWithUTF8String:b.getStringField("name")];
            NSMutableDictionary *item = [[NSMutableDictionary alloc] initWithCapacity:4];
            [item setObject:@"name" forKey:@"name"];
            [item setObject:@"String" forKey:@"type"];
            [item setObject:name forKey:@"value"];
            [item setObject:[[self class] bsonDictWrapper:b] forKey:@"child"];
            [response addObject:item];
            [name release];
            [item release];
        }
        NSLog(@"Show indexes in db: %@.%@", dbname, collectionname);
        return [response autorelease];
    }catch (mongo::DBException &e) {
        NSRunAlertPanel(@"Error", [NSString stringWithUTF8String:e.what()], @"OK", nil, nil);
    }
    return nil;
}

- (void) ensureIndexInDB:(NSString *)dbname 
         collection:(NSString *)collectionname 
               user:(NSString *)user 
           password:(NSString *)password 
         indexData:(NSString *)indexData
{
    try {
        if ([user length]>0 && [password length]>0) {
            BOOL ok = [self authUser:user pass:password database:dbname];
            if (!ok) {
                return;
            }
        }
        NSString *col = [NSString stringWithFormat:@"%@.%@", dbname, collectionname];
        mongo::BSONObj indexDataBSON;
        if ([indexData isPresent]) {
            try{
                indexDataBSON = mongo::fromjson([indexData UTF8String]);
            }catch (mongo::MsgAssertionException &e) {
                NSRunAlertPanel(@"Error", [NSString stringWithUTF8String:e.what()], @"OK", nil, nil);
                return;
            }
        }
        if (repl_conn) {
            repl_conn->ensureIndex(std::string([col UTF8String]), indexDataBSON);
        }else {
            conn->ensureIndex(std::string([col UTF8String]), indexDataBSON);
        }
        NSLog(@"Ensure index in db: %@.%@", dbname, collectionname);
    }catch (mongo::DBException &e) {
        NSRunAlertPanel(@"Error", [NSString stringWithUTF8String:e.what()], @"OK", nil, nil);
    }
}

- (void) reIndexInDB:(NSString *)dbname 
              collection:(NSString *)collectionname 
                    user:(NSString *)user 
                password:(NSString *)password
{
    try {
        if ([user length]>0 && [password length]>0) {
            BOOL ok = [self authUser:user pass:password database:dbname];
            if (!ok) {
                return;
            }
        }
        NSString *col = [NSString stringWithFormat:@"%@.%@", dbname, collectionname];
        if (repl_conn) {
            repl_conn->reIndex(std::string([col UTF8String]));
        }else {
            conn->reIndex(std::string([col UTF8String]));
        }
        NSLog(@"Reindex in db: %@.%@", dbname, collectionname);
    }catch (mongo::DBException &e) {
        NSRunAlertPanel(@"Error", [NSString stringWithUTF8String:e.what()], @"OK", nil, nil);
    }
}

- (void) dropIndexInDB:(NSString *)dbname 
              collection:(NSString *)collectionname 
                    user:(NSString *)user 
                password:(NSString *)password 
               indexName:(NSString *)indexName
{
    try {
        if ([user length]>0 && [password length]>0) {
            BOOL ok = [self authUser:user pass:password database:dbname];
            if (!ok) {
                return;
            }
        }
        NSString *col = [NSString stringWithFormat:@"%@.%@", dbname, collectionname];
        if (repl_conn) {
            repl_conn->dropIndex(std::string([col UTF8String]), [indexName UTF8String]);
        }else {
            conn->dropIndex(std::string([col UTF8String]), [indexName UTF8String]);
        }
        NSLog(@"Drop index in db: %@.%@", dbname, collectionname);
    }catch (mongo::DBException &e) {
        NSRunAlertPanel(@"Error", [NSString stringWithUTF8String:e.what()], @"OK", nil, nil);
    }
}

- (long long int) countInDB:(NSString *)dbname 
                   collection:(NSString *)collectionname 
                         user:(NSString *)user 
                     password:(NSString *)password 
                     critical:(NSString *)critical 
{
    try {
        if ([user length]>0 && [password length]>0) {
            BOOL ok = [self authUser:user pass:password database:dbname];
            if (!ok) {
                return 0;
            }
        }
        NSString *col = [NSString stringWithFormat:@"%@.%@", dbname, collectionname];
        mongo::BSONObj criticalBSON = mongo::fromjson([critical UTF8String]);
        long long int counter;
        if (repl_conn) {
            counter = repl_conn->count(std::string([col UTF8String]), criticalBSON);
        }else {
            counter = conn->count(std::string([col UTF8String]), criticalBSON);
        }
        NSLog(@"Count in db: %@.%@", dbname, collectionname);
        return counter;
    }catch (mongo::DBException &e) {
        NSRunAlertPanel(@"Error", [NSString stringWithUTF8String:e.what()], @"OK", nil, nil);
    }
    return 0;
}

- (NSArray *)mapReduceInDB:dbname 
                       collection:collectionname 
                             user:user 
                         password:password 
                            mapJs:mapJs 
                         reduceJs:reduceJs 
                         critical:critical 
                           output:output
{
    try {
        if ([user length]>0 && [password length]>0) {
            BOOL ok = [self authUser:user pass:password database:dbname];
            if (!ok) {
                return nil;
            }
        }
        if (![mapJs isPresent] || ![reduceJs isPresent]) {
            return nil;
        }
        NSString *col = [NSString stringWithFormat:@"%@.%@", dbname, collectionname];
        mongo::BSONObj criticalBSON = mongo::fromjson([critical UTF8String]);
        mongo::BSONObj retval;
        if (repl_conn) {
            retval = repl_conn->mapreduce(std::string([col UTF8String]), std::string([mapJs UTF8String]), std::string([reduceJs UTF8String]), criticalBSON, std::string([output UTF8String]));
        }else {
            retval = conn->mapreduce(std::string([col UTF8String]), std::string([mapJs UTF8String]), std::string([reduceJs UTF8String]), criticalBSON, std::string([output UTF8String]));
        }
        NSLog(@"Map reduce in db: %@.%@", dbname, collectionname);
        return [[self class] bsonDictWrapper:retval];
    }catch (mongo::DBException &e) {
        NSRunAlertPanel(@"Error", [NSString stringWithUTF8String:e.what()], @"OK", nil, nil);
    }
    return nil;
}

+ (double) diff:(NSString *)aName first:(mongo::BSONObj)a second:(mongo::BSONObj)b timeInterval:(NSTimeInterval)interval{
    std::string name = std::string([aName UTF8String]);
    mongo::BSONElement x = a.getFieldDotted( name.c_str() );
    mongo::BSONElement y = b.getFieldDotted( name.c_str() );
    if ( ! x.isNumber() || ! y.isNumber() )
        return -1;
    return ( y.number() - x.number() ) / interval;
}

+ (double) percent:(NSString *)aOut value:(NSString *)aVal first:(mongo::BSONObj)a second:(mongo::BSONObj)b {
    const char * outof = [aOut UTF8String];
    const char * val = [aVal UTF8String];
    double x = ( b.getFieldDotted( val ).number() - a.getFieldDotted( val ).number() );
    double y = ( b.getFieldDotted( outof ).number() - a.getFieldDotted( outof ).number() );
    if ( y == 0 )
        return 0;
    double p = x / y;
    p = (double)((int)(p * 1000)) / 10;
    return p;
}

+ (NSDictionary *) serverMonitor:(mongo::BSONObj)a second:(mongo::BSONObj)b currentDate:(NSDate *)now previousDate:(NSDate *)previous
{
    NSMutableDictionary *res = [[NSMutableDictionary alloc] initWithCapacity:14];
    [res setObject:now forKey:@"time"];
    NSTimeInterval interval = [now timeIntervalSinceDate:previous];
    if ( b["opcounters"].type() == mongo::Object ) {
        mongo::BSONObj ax = a["opcounters"].embeddedObject();
        mongo::BSONObj bx = b["opcounters"].embeddedObject();
        mongo::BSONObjIterator i( bx );
        while ( i.more() ){
            mongo::BSONElement e = i.next();
            NSString *key = [NSString stringWithUTF8String:e.fieldName()];
            [res setObject:[NSNumber numberWithInt:[self diff:key first:ax second:bx timeInterval:interval]] forKey:key];
        }
    }
    if ( b["backgroundFlushing"].type() == mongo::Object ){
        mongo::BSONObj ax = a["backgroundFlushing"].embeddedObject();
        mongo::BSONObj bx = b["backgroundFlushing"].embeddedObject();
        [res setObject:[NSNumber numberWithInt:[self diff:@"flushes" first:ax second:bx timeInterval:interval]] forKey:@"flushes"];
    }
    if ( b.getFieldDotted("mem.supported").trueValue() ){
        mongo::BSONObj bx = b["mem"].embeddedObject();
        [res setObject:[NSNumber numberWithInt:bx["mapped"].numberInt()] forKey:@"mapped"];
        [res setObject:[NSNumber numberWithInt:bx["virtual"].numberInt()] forKey:@"vsize"];
        [res setObject:[NSNumber numberWithInt:bx["resident"].numberInt()] forKey:@"res"];
    }
    if ( b["extra_info"].type() == mongo::Object ){
        mongo::BSONObj ax = a["extra_info"].embeddedObject();
        mongo::BSONObj bx = b["extra_info"].embeddedObject();
        if ( ax["page_faults"].type() || ax["page_faults"].type() )
            [res setObject:[NSNumber numberWithInt:[self diff:@"page_faults" first:ax second:bx timeInterval:interval]] forKey:@"faults"];
    }
    [res setObject:[NSNumber numberWithInt:[self percent:@"globalLock.totalTime" value:@"globalLock.lockTime" first:a second:b]] forKey:@"locked"];
    [res setObject:[NSNumber numberWithInt:[self percent:@"indexCounters.btree.accesses" value:@"indexCounters.btree.misses" first:a second:b]] forKey:@"misses"];
    [res setObject:[NSNumber numberWithInt:b.getFieldDotted( "connections.current" ).numberInt()] forKey:@"conn"];
    return (NSDictionary *)res;
}

- (void)fetchServerStatusDeltaCallback:(NSDictionary *)info
{
    NSDictionary *serverStatusDelta;
    
    serverStatusDelta = [info objectForKey:@"serverStatusDelta"];
    if ([_delegate respondsToSelector:@selector(mongoDB:serverStatusDeltaFetched:withErrorMessage:)]) {
        [_delegate mongoDB:self serverStatusDeltaFetched:serverStatusDelta withErrorMessage:[info objectForKey:@"errorMessage"]];
    }
}

- (NSOperation *)fetchServerStatusDelta
{
    NSBlockOperation *operation;
    
    operation = [NSBlockOperation blockOperationWithBlock:^{
        try {
            mongo::BSONObj currentStats;
            NSDate *currentDate;
            NSDictionary *serverStatusDelta = nil;
            
            if (repl_conn) {
                repl_conn->runCommand("admin", BSON("serverStatus"<<1), currentStats);
            }else {
                conn->runCommand("admin", BSON("serverStatus"<<1), currentStats);
            }
            currentDate = [[NSDate alloc] init];
            if (_dateForDelta) {
                serverStatusDelta = [[self class] serverMonitor:_serverStatusForDelta second:currentStats currentDate:currentDate previousDate:_dateForDelta];
            }
            [_dateForDelta release];
            _dateForDelta = currentDate;
            _serverStatusForDelta = currentStats;
            
            if (serverStatusDelta) {
                [self performSelectorOnMainThread:@selector(fetchServerStatusDeltaCallback:) withObject:[NSMutableDictionary dictionaryWithObjectsAndKeys:serverStatusDelta, @"serverStatusDelta", nil] waitUntilDone:NO];
            }
        } catch (mongo::DBException &e) {
            [self performSelectorOnMainThread:@selector(fetchServerStatusDeltaCallback:) withObject:[NSMutableDictionary dictionaryWithObjectsAndKeys:[NSString stringWithUTF8String:e.what()], @"errorMessage", nil] waitUntilDone:NO];
        }
    }];
    [_operationQueue addOperation:operation];
    return operation;
}

#pragma mark BSON to NSMutableArray
+ (NSArray *) bsonDictWrapper:(mongo::BSONObj)retval
{
    if (!retval.isEmpty())
    {
        std::set<std::string> fieldNames;
        retval.getFieldNames(fieldNames);
        NSMutableArray *arr = [[NSMutableArray alloc] initWithCapacity:fieldNames.size()];
        for(std::set<std::string>::iterator it=fieldNames.begin();it!=fieldNames.end();++it)
        {
            mongo::BSONElement e = retval.getField((*it));
            NSString *fieldName = [[NSString alloc] initWithUTF8String:(*it).c_str()];
            NSMutableArray *child = [[NSMutableArray alloc] init];
            NSString *value;
            NSString *fieldType;
            if (e.type() == mongo::Array) {
                mongo::BSONObj b = e.embeddedObject();
                NSMutableArray *tmp = [[self bsonArrayWrapper:b] mutableCopy];
                if (tmp!=nil) {
                    [child release];
                    child = [tmp retain];
                    value = @"";
                }else {
                    value = @"[ ]";
                }

                fieldType = @"Array";
                [tmp release];
            }else if (e.type() == mongo::Object) {
                mongo::BSONObj b = e.embeddedObject();
                NSMutableArray *tmp = [[self bsonDictWrapper:b] mutableCopy];
                if (tmp!=nil) {
                    [child release];
                    child = [tmp retain];
                    value = @"";
                }else {
                    value = @"{ }";
                }

                fieldType = @"Object";
                [tmp release];
            }else{
                if (e.type() == mongo::jstNULL) {
                    fieldType = @"NULL";
                    value = @"NULL";
                }else if (e.type() == mongo::Bool) {
                    fieldType = @"Bool";
                    if (e.boolean()) {
                        value = @"YES";
                    }else {
                        value = @"NO";
                    }
                }else if (e.type() == mongo::NumberDouble) {
                    fieldType = @"Double";
                    value = [NSString stringWithFormat:@"%f", e.numberDouble()];
                }else if (e.type() == mongo::NumberInt) {
                    fieldType = @"Int";
                    value = [NSString stringWithFormat:@"%d", (int)(e.numberInt())];
                }else if (e.type() == mongo::Date) {
                    fieldType = @"Date";
                    mongo::Date_t dt = (time_t)e.date();
                    time_t timestamp = dt / 1000;
                    NSDate *someDate = [NSDate dateWithTimeIntervalSince1970:timestamp];
                    value = [someDate description];
                }else if (e.type() == mongo::Timestamp) {
                    fieldType = @"Timestamp";
                    time_t timestamp = (time_t)e.timestampTime();
                    NSDate *someDate = [NSDate dateWithTimeIntervalSince1970:timestamp];
                    value = [someDate description];
                }else if (e.type() == mongo::BinData) {
                    //int binlen;
                    fieldType = @"BinData";
                    //value = [NSString stringWithUTF8String:e.binData(binlen)];
                    value = @"binary";
                }else if (e.type() == mongo::NumberLong) {
                    fieldType = @"Long";
                    value = [NSString stringWithFormat:@"%qi", e.numberLong()];
                }else if ([fieldName isEqualToString:@"_id" ]) {
                    if (e.type() == mongo::jstOID)
                    {
                        fieldType = @"ObjectId";
                        value = [NSString stringWithUTF8String:e.__oid().str().c_str()];
                    }else {
                        fieldType = @"String";
                        value = [NSString stringWithUTF8String:e.str().c_str()];
                    }
                }else if (e.type() == mongo::jstOID) {
                    fieldType = @"ObjectId";
                    value = [NSString stringWithUTF8String:e.__oid().str().c_str()];
                }else {
                    fieldType = @"String";
                    value = [NSString stringWithUTF8String:e.str().c_str()];
                }
            }
            NSMutableDictionary *dict = [[NSMutableDictionary alloc] initWithCapacity:4];
            [dict setObject:fieldName forKey:@"name"];
            [dict setObject:fieldType forKey:@"type"];
            [dict setObject:value forKey:@"value"];
            [dict setObject:child forKey:@"child"];
            [arr addObject:dict];
            [dict release];
            [fieldName release];
            [child release];
        }
        return [arr autorelease];
    }
    return nil;
}

+ (NSArray *) bsonArrayWrapper:(mongo::BSONObj)retval
{
    if (!retval.isEmpty())
    {
        NSMutableArray *arr = [[NSMutableArray alloc] init];
        mongo::BSONElement idElm;
        BOOL hasId = retval.getObjectID(idElm);
        mongo::BSONObjIterator it (retval);
        unsigned int i=0;
        while(it.more())
        {
            mongo::BSONElement e = it.next();
            NSString *fieldName = [[NSString alloc] initWithFormat:@"%d", i];
            NSString *value;
            NSString *fieldType;
            NSMutableArray *child = [[NSMutableArray alloc] init];
            if (e.type() == mongo::Array) {
                mongo::BSONObj b = e.embeddedObject();
                NSMutableArray *tmp = [[self bsonArrayWrapper:b] mutableCopy];
                if (tmp == nil) {
                    value = @"[ ]";
                    if (hasId) {
                        [arr addObject:@"[ ]"];
                    }
                }else {
                    [child release];
                    child = [tmp retain];
                    value = @"";
                    if (hasId) {
                        [arr addObject:tmp];
                    }
                }
                fieldType = @"Array";
                [tmp release];
            }else if (e.type() == mongo::Object) {
                mongo::BSONObj b = e.embeddedObject();
                NSMutableArray *tmp = [[self bsonDictWrapper:b] mutableCopy];
                if (tmp == nil) {
                    value = @"";
                    if (hasId) {
                        [arr addObject:@"{ }"];
                    }
                }else {
                    [child release];
                    child = [tmp retain];
                    value = @"{ }";
                    if (hasId) {
                        [arr addObject:tmp];
                    }
                }
                fieldType = @"Object";
                [tmp release];
            }else{
                if (e.type() == mongo::jstNULL) {
                    fieldType = @"NULL";
                    value = @"NULL";
                }else if (e.type() == mongo::Bool) {
                    fieldType = @"Bool";
                    if (e.boolean()) {
                        value = @"YES";
                    }else {
                        value = @"NO";
                    }
                    if (hasId) {
                        [arr addObject:[NSNumber numberWithBool:e.boolean()]];
                    }
                }else if (e.type() == mongo::NumberDouble) {
                    fieldType = @"Double";
                    value = [NSString stringWithFormat:@"%f", e.numberDouble()];
                    if (hasId) {
                        [arr addObject:[NSNumber numberWithDouble:e.numberDouble()]];
                    }
                }else if (e.type() == mongo::NumberInt) {
                    fieldType = @"Int";
                    value = [NSString stringWithFormat:@"%d", (int)(e.numberInt())];
                    if (hasId) {
                        [arr addObject:[NSNumber numberWithInt:e.numberInt()]];
                    }
                }else if (e.type() == mongo::Date) {
                    fieldType = @"Date";
                    mongo::Date_t dt = (time_t)e.date();
                    time_t timestamp = dt / 1000;
                    NSDate *someDate = [NSDate dateWithTimeIntervalSince1970:timestamp];
                    value = [someDate description];
                    if (hasId) {
                        [arr addObject:[someDate description]];
                    }
                }else if (e.type() == mongo::Timestamp) {
                    fieldType = @"Timestamp";
                    time_t timestamp = (time_t)e.timestampTime();
                    NSDate *someDate = [NSDate dateWithTimeIntervalSince1970:timestamp];
                    value = [someDate description];
                    if (hasId) {
                        [arr addObject:[someDate description]];
                    }
                }else if (e.type() == mongo::BinData) {
                    fieldType = @"BinData";
                    //int binlen;
                    //value = [NSString stringWithUTF8String:e.binData(binlen)];
                    value = @"binary";
                    if (hasId) {
                        //[arr addObject:[NSString stringWithUTF8String:e.binData(binlen)]];
                        [arr addObject:@"binary"];
                    }
                }else if (e.type() == mongo::NumberLong) {
                    fieldType = @"Long";
                    value = [NSString stringWithFormat:@"%qi", e.numberLong()];
                    if (hasId) {
                        [arr addObject:[NSString stringWithFormat:@"%qi", e.numberLong()]];
                    }
                }else if (e.type() == mongo::jstOID) {
                    fieldType = @"ObjectId";
                    value = [NSString stringWithUTF8String:e.__oid().str().c_str()];
                }else {
                    fieldType = @"String";
                    value = [NSString stringWithUTF8String:e.str().c_str()];
                    if (hasId) {
                        [arr addObject:[NSString stringWithUTF8String:e.str().c_str()]];
                    }
                }
            }
            if (!hasId) {
                NSMutableDictionary *dict = [[NSMutableDictionary alloc] initWithCapacity:4];
                [dict setObject:fieldName forKey:@"name"];
                [dict setObject:fieldType forKey:@"type"];
                [dict setObject:value forKey:@"value"];
                [dict setObject:child forKey:@"child"];
                [arr addObject:dict];
                [dict release];
            }
            [fieldName release];
            [child release];
            i ++;
        }
        return [arr autorelease];
    }
    return nil;
}

- (std::auto_ptr<mongo::DBClientCursor>) findAllCursorInDB:(NSString *)dbname collection:(NSString *)collectionname user:(NSString *)user password:(NSString *)password fields:(mongo::BSONObj) fields
{
    std::auto_ptr<mongo::DBClientCursor> cursor;
    try {
        if ([user length]>0 && [password length]>0) {
            BOOL ok = [self authUser:user pass:password database:dbname];
            if (!ok) {
                return cursor;
            }
        }
        NSString *col = [NSString stringWithFormat:@"%@.%@", dbname, collectionname];
        if (repl_conn) {
            cursor = repl_conn->query(std::string([col UTF8String]), mongo::Query(), 0, 0, &fields, mongo::QueryOption_SlaveOk | mongo::QueryOption_NoCursorTimeout);
        }else {
            cursor = conn->query(std::string([col UTF8String]), mongo::Query(), 0, 0, &fields, mongo::QueryOption_SlaveOk | mongo::QueryOption_NoCursorTimeout);
        }
        return cursor;
    }catch (mongo::DBException &e) {
        NSRunAlertPanel(@"Error", [NSString stringWithUTF8String:e.what()], @"OK", nil, nil);
    }
    return cursor;
}

- (std::auto_ptr<mongo::DBClientCursor>) findCursorInDB:(NSString *)dbname 
                   collection:(NSString *)collectionname 
                         user:(NSString *)user 
                     password:(NSString *)password 
                     critical:(NSString *)critical 
                       fields:(NSString *)fields 
                         skip:(NSNumber *)skip 
                        limit:(NSNumber *)limit 
                         sort:(NSString *)sort
{
    std::auto_ptr<mongo::DBClientCursor> cursor;
    try {
        if ([user length]>0 && [password length]>0) {
            BOOL ok = [self authUser:user pass:password database:dbname];
            if (!ok) {
                return cursor;
            }
        }
        NSString *col = [NSString stringWithFormat:@"%@.%@", dbname, collectionname];
        mongo::BSONObj criticalBSON = mongo::fromjson([critical UTF8String]);
        mongo::BSONObj sortBSON = mongo::fromjson([sort UTF8String]);
        mongo::BSONObj fieldsToReturn;
        if ([fields isPresent]) {
            NSArray *keys = [[NSArray alloc] initWithArray:[fields componentsSeparatedByString:@","]];
            mongo::BSONObjBuilder builder;
            for (NSString *str in keys) {
                builder.append([str UTF8String], 1);
            }
            fieldsToReturn = builder.obj();
            [keys release];
        }
        if (repl_conn) {
            cursor = repl_conn->query(std::string([col UTF8String]), mongo::Query(criticalBSON).sort(sortBSON), [limit intValue], [skip intValue], &fieldsToReturn, mongo::QueryOption_SlaveOk | mongo::QueryOption_NoCursorTimeout);
        }else {
            cursor = conn->query(std::string([col UTF8String]), mongo::Query(criticalBSON).sort(sortBSON), [limit intValue], [skip intValue], &fieldsToReturn, mongo::QueryOption_SlaveOk | mongo::QueryOption_NoCursorTimeout);
        }
        return cursor;
    }catch (mongo::DBException &e) {
        NSRunAlertPanel(@"Error", [NSString stringWithUTF8String:e.what()], @"OK", nil, nil);
    }
    return cursor;
}

- (void) updateBSONInDB:(NSString *)dbname 
         collection:(NSString *)collectionname 
               user:(NSString *)user 
           password:(NSString *)password 
           critical:(mongo::Query)critical 
             fields:(mongo::BSONObj)fields 
              upset:(BOOL)upset
{
    try {
        if ([user length]>0 && [password length]>0) {
            BOOL ok = [self authUser:user pass:password database:dbname];
            if (!ok) {
                return;
            }
        }
        NSString *col = [NSString stringWithFormat:@"%@.%@", dbname, collectionname];
        if (repl_conn) {
            repl_conn->update(std::string([col UTF8String]), critical, fields, upset);
        }else {
            conn->update(std::string([col UTF8String]), critical, fields, upset);
        }
        NSLog(@"Update in db: %@.%@", dbname, collectionname);
    }catch (mongo::DBException &e) {
        NSRunAlertPanel(@"Error", [NSString stringWithUTF8String:e.what()], @"OK", nil, nil);
    }
}

- (NSArray *)databaseList
{
    return [_databaseList allKeys];
}

@end
