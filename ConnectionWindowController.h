//
//  ConnectionWindowController.h
//  MongoHub
//
//  Created by Syd on 10-4-25.
//  Copyright 2010 MusicPeace.ORG. All rights reserved.
//

#import <Cocoa/Cocoa.h>
#import <SSHTunnel/SSHTunnel.h>
@class DatabasesArrayController;
@class AddDBController;
@class AddCollectionController;
@class AuthWindowController;
@class ResultsOutlineViewController;
@class Connection;
@class Sidebar;
@class SidebarNode;
@class MongoDB;

@interface ConnectionWindowController : NSWindowController {
    NSManagedObjectContext *managedObjectContext;
    IBOutlet DatabasesArrayController *databaseArrayController;
    IBOutlet ResultsOutlineViewController *resultsOutlineViewController;
    Connection *conn;
    MongoDB *mongoDB;
    IBOutlet Sidebar *sidebar;
    IBOutlet NSTextField *resultsTitle;
    NSMutableArray *databases;
    NSMutableArray *collections;
    SidebarNode *selectedDB;
    SidebarNode *selectedCollection;
    SSHTunnel *sshTunnel;
    AddDBController *addDBController;
    AddCollectionController *addCollectionController;
    AuthWindowController *authWindowController;
    IBOutlet NSTextField *bundleVersion;
}

@property (nonatomic, retain) NSManagedObjectContext *managedObjectContext;
@property (nonatomic, retain) DatabasesArrayController *databaseArrayController;
@property (nonatomic, retain) ResultsOutlineViewController *resultsOutlineViewController;
@property (nonatomic, retain) Connection *conn;
@property (nonatomic, retain) MongoDB *mongoDB;
@property (nonatomic, retain) Sidebar *sidebar;
@property (nonatomic, retain) NSMutableArray *databases;
@property (nonatomic, retain) NSMutableArray *collections;
@property (nonatomic, retain) SidebarNode *selectedDB;
@property (nonatomic, retain) SidebarNode *selectedCollection;
@property (nonatomic, retain) SSHTunnel *sshTunnel;
@property (nonatomic, retain) NSTextField *resultsTitle;
@property (nonatomic, retain) AddDBController *addDBController;
@property (nonatomic, retain) AddCollectionController *addCollectionController;
@property (nonatomic, retain) NSTextField *bundleVersion;
@property (nonatomic, retain) AuthWindowController *authWindowController;

- (void)reloadSidebar;
- (void)reloadDBList;
- (void)useDB:(id)sender;
- (void)useCollection:(id)sender;
- (IBAction)showServerStatus:(id)sender;
- (IBAction)showDBStats:(id)sender;
- (IBAction)showCollStats:(id)sender;
- (IBAction)createDBorCollection:(id)sender;
- (void)dropCollection:(NSString *)collectionname 
                 ForDB:(NSString *)dbname;
- (void)createDB;
- (void)createCollectionForDB:(NSString *)dbname;
- (IBAction)dropDBorCollection:(id)sender;
- (void)dropDB;
- (IBAction)query:(id)sender;
- (IBAction)showAuth:(id)sender;
@end