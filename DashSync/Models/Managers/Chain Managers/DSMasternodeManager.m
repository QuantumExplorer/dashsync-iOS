//
//  DSMasternodeManager.m
//  DashSync
//
//  Created by Sam Westrich on 6/7/18.
//  Copyright (c) 2018 Dash Core Group <contact@dash.org>
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
//  THE SOFTWARE.

#import "DSMasternodeManager.h"
#import "DSSimplifiedMasternodeEntryEntity+CoreDataClass.h"
#import "DSProviderRegistrationTransactionEntity+CoreDataClass.h"
#import "DSAddressEntity+CoreDataProperties.h"
#import "DSChainEntity+CoreDataProperties.h"
#import "NSManagedObject+Sugar.h"
#import "DSChain.h"
#import "DSPeer.h"
#import "NSData+Dash.h"
#import "DSPeerManager.h"
#import "DSTransactionFactory.h"
#import "NSMutableData+Dash.h"
#import "DSSimplifiedMasternodeEntry.h"
#import "DSMerkleBlock.h"
#import "DSChainManager+Protected.h"
#import "DSPeerManager+Protected.h"
#import "DSMutableOrderedDataKeyDictionary.h"
#import "DSLocalMasternode+Protected.h"
#import "DSLocalMasternodeEntity+CoreDataClass.h"
#import "DSProviderRegistrationTransaction.h"
#import "DSDerivationPath.h"
#import "DSQuorumEntryEntity+CoreDataClass.h"
#import "DSMerkleBlockEntity+CoreDataClass.h"
#import "DSMasternodeListEntity+CoreDataClass.h"
#import "DSQuorumEntry.h"
#import "DSMasternodeList.h"
#import "DSTransactionManager+Protected.h"
#import "NSString+Bitcoin.h"

#define REQUEST_MASTERNODE_BROADCAST_COUNT 500
#define FAULTY_DML_MASTERNODE_PEERS @"FAULTY_DML_MASTERNODE_PEERS"
#define CHAIN_FAULTY_DML_MASTERNODE_PEERS [NSString stringWithFormat:@"%@_%@",peer.chain.uniqueID,FAULTY_DML_MASTERNODE_PEERS]
#define MAX_FAULTY_DML_PEERS 5


@interface DSMasternodeManager()

@property (nonatomic,strong) DSChain * chain;
@property (nonatomic,strong) DSMasternodeList * currentMasternodeList;
@property (nonatomic,strong) DSMasternodeList * masternodeListAwaitingQuorumValidation;
@property (nonatomic,strong) NSManagedObjectContext * managedObjectContext;
@property (nonatomic,assign) UInt256 lastQueriedBlockHash; //last by height, not by time queried
@property (nonatomic,strong) NSMutableDictionary<NSData*,DSMasternodeList*>* masternodeListsByBlockHash;
@property (nonatomic,strong) NSMutableDictionary<NSData*,NSNumber*>* cachedBlockHashHeights;
@property (nonatomic,strong) NSMutableDictionary<NSData*,DSLocalMasternode*> *localMasternodesDictionaryByRegistrationTransactionHash;
@property (nonatomic,strong) NSMutableOrderedSet <NSData*>* masternodeListRetrievalQueue;
@property (nonatomic,assign) NSTimeInterval timeIntervalForMasternodeRetrievalSafetyDelay;

@end

@implementation DSMasternodeManager

- (instancetype)initWithChain:(DSChain*)chain
{
    NSParameterAssert(chain);
    
    if (! (self = [super init])) return nil;
    _chain = chain;
    _masternodeListRetrievalQueue = [NSMutableOrderedSet orderedSet];
    _masternodeListsByBlockHash = [NSMutableDictionary dictionary];
    _cachedBlockHashHeights = [NSMutableDictionary dictionary];
    _localMasternodesDictionaryByRegistrationTransactionHash = [NSMutableDictionary dictionary];
    self.managedObjectContext = [NSManagedObject context];
    self.lastQueriedBlockHash = UINT256_ZERO;
    return self;
}

// MARK: - Helpers

-(DSPeerManager*)peerManager {
    return self.chain.chainManager.peerManager;
}

-(NSArray*)orderedMasternodeLists {
    return [[self.masternodeListsByBlockHash allValues] sortedArrayUsingDescriptors:@[[NSSortDescriptor sortDescriptorWithKey:@"height" ascending:YES]]];
}

-(uint32_t)heightForBlockHash:(UInt256)blockhash {
    NSNumber * cachedHeightNumber = [self.cachedBlockHashHeights objectForKey:uint256_data(blockhash)];
    if (cachedHeightNumber) return [cachedHeightNumber intValue];
    uint32_t chainHeight = [self.chain heightForBlockHash:blockhash];
    if (chainHeight != UINT32_MAX) [self.cachedBlockHashHeights setObject:@(chainHeight) forKey:uint256_data(blockhash)];
    return chainHeight;
}

-(UInt256)closestKnownBlockHashForBlockHash:(UInt256)blockHash {
    DSMasternodeList * masternodeList = [self masternodeListBeforeBlockHash:blockHash];
    if (masternodeList) return masternodeList.blockHash;
    else return self.chain.genesisHash;
}

-(NSUInteger)simplifiedMasternodeEntryCount {
    return [self.currentMasternodeList masternodeCount];
}

-(NSUInteger)activeQuorumsCount {
    return self.currentMasternodeList.quorumsCount;
}

-(DSSimplifiedMasternodeEntry*)simplifiedMasternodeEntryForLocation:(UInt128)IPAddress port:(uint16_t)port {
    for (DSSimplifiedMasternodeEntry * simplifiedMasternodeEntry in [self.currentMasternodeList.simplifiedMasternodeListDictionaryByReversedRegistrationTransactionHash allValues]) {
        if (uint128_eq(simplifiedMasternodeEntry.address, IPAddress) && simplifiedMasternodeEntry.port == port) {
            return simplifiedMasternodeEntry;
        }
    }
    return nil;
}

-(DSSimplifiedMasternodeEntry*)masternodeHavingProviderRegistrationTransactionHash:(NSData*)providerRegistrationTransactionHash {
    NSParameterAssert(providerRegistrationTransactionHash);
    
    return [self.currentMasternodeList.simplifiedMasternodeListDictionaryByReversedRegistrationTransactionHash objectForKey:providerRegistrationTransactionHash];
}

-(BOOL)hasMasternodeAtLocation:(UInt128)IPAddress port:(uint32_t)port {
    if (self.chain.protocolVersion < 70211) {
        return FALSE;
    } else {
        DSSimplifiedMasternodeEntry * simplifiedMasternodeEntry = [self simplifiedMasternodeEntryForLocation:IPAddress port:port];
        return (!!simplifiedMasternodeEntry);
    }
}

// MARK: - Set Up and Tear Down

-(void)setUp {
    [self loadMasternodeLists];
    [self loadLocalMasternodes];
}

-(void)loadLocalMasternodes {
    NSFetchRequest * fetchRequest = [[DSLocalMasternodeEntity fetchRequest] copy];
    [fetchRequest setPredicate:[NSPredicate predicateWithFormat:@"providerRegistrationTransaction.transactionHash.chain == %@",self.chain.chainEntity]];
    NSArray * localMasternodeEntities = [DSLocalMasternodeEntity fetchObjects:fetchRequest];
    for (DSLocalMasternodeEntity * localMasternodeEntity in localMasternodeEntities) {
        [localMasternodeEntity loadLocalMasternode]; // lazy loaded into the list
    }
}

-(void)loadMasternodeLists {
    [self.managedObjectContext performBlockAndWait:^{
        NSFetchRequest * fetchRequest = [[DSMasternodeListEntity fetchRequest] copy];
        [fetchRequest setPredicate:[NSPredicate predicateWithFormat:@"block.chain == %@",self.chain.chainEntity]];
        [fetchRequest setSortDescriptors:@[[NSSortDescriptor sortDescriptorWithKey:@"block.height" ascending:YES]]];
        NSArray * masternodeListEntities = [DSMasternodeListEntity fetchObjects:fetchRequest];
        NSMutableDictionary * simplifiedMasternodeEntryPool = [NSMutableDictionary dictionary];
        NSMutableDictionary * quorumEntryPool = [NSMutableDictionary dictionary];
        for (DSMasternodeListEntity * masternodeListEntity in masternodeListEntities) {
            DSMasternodeList * masternodeList = [masternodeListEntity masternodeListWithSimplifiedMasternodeEntryPool:[simplifiedMasternodeEntryPool copy] quorumEntryPool:quorumEntryPool];
            [self.masternodeListsByBlockHash setObject:masternodeList forKey:uint256_data(masternodeList.blockHash)];
            [self.cachedBlockHashHeights setObject:@(masternodeListEntity.block.height) forKey:uint256_data(masternodeList.blockHash)];
            [simplifiedMasternodeEntryPool addEntriesFromDictionary:masternodeList.simplifiedMasternodeListDictionaryByReversedRegistrationTransactionHash];
            [quorumEntryPool addEntriesFromDictionary:masternodeList.quorums];
            DSDLog(@"Loading Masternode List at height %u for blockHash %@ with %lu entries",masternodeList.height,uint256_hex(masternodeList.blockHash),(unsigned long)masternodeList.simplifiedMasternodeEntries.count);
            self.currentMasternodeList = masternodeList;
        }
    }];
}

-(void)wipeMasternodeInfo {
    [self.masternodeListsByBlockHash removeAllObjects];
    [self.localMasternodesDictionaryByRegistrationTransactionHash removeAllObjects];
    self.currentMasternodeList = nil;
    self.masternodeListAwaitingQuorumValidation = nil;
    [self.masternodeListRetrievalQueue removeAllObjects];
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:DSMasternodeListDidChangeNotification object:nil userInfo:@{DSChainManagerNotificationChainKey:self.chain}];
        [[NSNotificationCenter defaultCenter] postNotificationName:DSQuorumListDidChangeNotification object:nil userInfo:@{DSChainManagerNotificationChainKey:self.chain}];
    });
}

// MARK: - Masternode List Helpers

-(DSMasternodeList*)masternodeListForBlockHash:(UInt256)blockHash {
    return [self.masternodeListsByBlockHash objectForKey:uint256_data(blockHash)];
}

-(DSMasternodeList*)masternodeListAtBlockHeight:(uint32_t)blockHeight {
    DSMerkleBlock * merkleBlock = [self.chain blockFromChainTip:8];
    return [self masternodeListBeforeBlockHash:merkleBlock.blockHash];
}

-(DSMasternodeList*)masternodeListBeforeBlockHash:(UInt256)blockHash {
    uint32_t minDistance = UINT32_MAX;
    uint32_t blockHeight = [self heightForBlockHash:blockHash];
    DSMasternodeList * closestMasternodeList = nil;
    for (NSData * blockHashData in self.masternodeListsByBlockHash) {
        uint32_t masternodeListBlockHeight = [self heightForBlockHash:blockHashData.UInt256];
        if (blockHeight <= masternodeListBlockHeight) continue;
        uint32_t distance = blockHeight - masternodeListBlockHeight;
        if (distance < minDistance) {
            minDistance = distance;
            closestMasternodeList = self.masternodeListsByBlockHash[blockHashData];
        }
    }
    if (closestMasternodeList.height < 1088640 && blockHeight >= 1088640) return nil;
    return closestMasternodeList;
}

// MARK: - Requesting Masternode List

-(void)dequeueMasternodeListRequest {
    if (![self.masternodeListRetrievalQueue count]) return;
    if (self.peerManager.downloadPeer.status != DSPeerStatus_Connected) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), [self peerManager].chainPeerManagerQueue, ^{
            [self dequeueMasternodeListRequest];
        });
        return;
    }
    UInt256 blockHash = [self.masternodeListRetrievalQueue objectAtIndex:0].UInt256;
    
    //we should check the associated block still exists
    __block BOOL hasBlock;
    [self.managedObjectContext performBlockAndWait:^{
        hasBlock = !![DSMerkleBlockEntity countObjectsMatching:@"blockHash == %@",uint256_data(blockHash)];
    }];
    if (hasBlock) {
        UInt256 previousBlockHash = [self closestKnownBlockHashForBlockHash:blockHash];
        DSDLog(@"Requesting masternode list and quorums from %u to %u (%@ to %@)",[self heightForBlockHash:previousBlockHash],[self heightForBlockHash:blockHash], uint256_reverse_hex(previousBlockHash), uint256_reverse_hex(blockHash));
        [self.peerManager.downloadPeer sendGetMasternodeListFromPreviousBlockHash:previousBlockHash forBlockHash:blockHash];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30 * NSEC_PER_SEC)), [self peerManager].chainPeerManagerQueue, ^{
            if (![self.masternodeListRetrievalQueue count]) return;
            DSDLog(@"TimedOut");
            UInt256 timeoutBlockHash = [self.masternodeListRetrievalQueue objectAtIndex:0].UInt256;
            if (uint256_eq(timeoutBlockHash, blockHash)) {
                //timeout
                [self dequeueMasternodeListRequest];
            }
        });
    } else {
        DSDLog(@"Missing block (%@)",uint256_reverse_hex(blockHash));
        [self.masternodeListRetrievalQueue removeObject:uint256_data(blockHash)];
        [self dequeueMasternodeListRequest];
    }
    
}

-(void)getRecentMasternodeList:(NSUInteger)blocksAgo {
    @synchronized (self.masternodeListRetrievalQueue) {
        BOOL emptyRequestQueue = ![self.masternodeListRetrievalQueue count];
        DSMerkleBlock * merkleBlock = [self.chain blockFromChainTip:blocksAgo];
        DSDLog(@"Get recent masternode list %u",merkleBlock.height);
        if ([self.masternodeListRetrievalQueue lastObject] && uint256_eq(merkleBlock.blockHash, [self.masternodeListRetrievalQueue lastObject].UInt256)) {
            //we are asking for the same as the last one
            return;
        }
        if ([self.masternodeListsByBlockHash.allKeys containsObject:uint256_data(merkleBlock.blockHash)]) {
            DSDLog(@"Already have that masternode list %u",merkleBlock.height);
            return;
        }
        self.lastQueriedBlockHash = merkleBlock.blockHash;
        [self.masternodeListRetrievalQueue addObject:[NSData dataWithUInt256:merkleBlock.blockHash]];
        if (emptyRequestQueue) {
            [self dequeueMasternodeListRequest];
        }
    }
}

-(void)getCurrentMasternodeListWithSafetyDelay:(uint32_t)safetyDelay {
    @synchronized (self.masternodeListRetrievalQueue) {
        if (safetyDelay) {
            //the safety delay checks to see if this was called in the last n seconds.
            self.timeIntervalForMasternodeRetrievalSafetyDelay = [[NSDate date] timeIntervalSince1970];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(safetyDelay * NSEC_PER_SEC)), [self peerManager].chainPeerManagerQueue, ^{
                NSTimeInterval timeElapsed = [[NSDate date] timeIntervalSince1970] - self.timeIntervalForMasternodeRetrievalSafetyDelay;
                if (timeElapsed > safetyDelay) {
                    [self getCurrentMasternodeListWithSafetyDelay:0];
                }
            });
            return;
        }
        if ([self.masternodeListRetrievalQueue lastObject] && uint256_eq(self.chain.lastBlock.blockHash, [self.masternodeListRetrievalQueue lastObject].UInt256)) {
            //we are asking for the same as the last one
            return;
        }
        if ([self.masternodeListsByBlockHash.allKeys containsObject:uint256_data(self.chain.lastBlock.blockHash)]) {
            DSDLog(@"Already have that masternode list %u",self.chain.lastBlock.height);
            return;
        }
        self.lastQueriedBlockHash = self.chain.lastBlock.blockHash;
        DSDLog(@"Get current masternode list %u",self.chain.lastBlock.height);
        BOOL emptyRequestQueue = ![self.masternodeListRetrievalQueue count];
        [self.masternodeListRetrievalQueue addObject:[NSData dataWithUInt256:self.chain.lastBlock.blockHash]];
        if (emptyRequestQueue) {
            [self dequeueMasternodeListRequest];
        }
    }
}

-(void)getMasternodeListsForBlockHashes:(NSArray*)blockHashes {
    @synchronized (self.masternodeListRetrievalQueue) {
        NSArray * orderedBlockHashes = [blockHashes sortedArrayUsingComparator:^NSComparisonResult(NSData *  _Nonnull obj1, NSData *  _Nonnull obj2) {
            uint32_t height1 = [self heightForBlockHash:obj1.UInt256];
            uint32_t height2 = [self heightForBlockHash:obj2.UInt256];
            return (height1>height2)?NSOrderedDescending:NSOrderedAscending;
        }];
        for (NSData * blockHash in orderedBlockHashes) {
            DSDLog(@"adding retrieval of masternode list at height %u to queue (%@)",[self  heightForBlockHash:blockHash.UInt256],blockHash.reverse.hexString);
        }
        BOOL emptyRequestQueue = ![self.masternodeListRetrievalQueue count];
        [self.masternodeListRetrievalQueue addObjectsFromArray:orderedBlockHashes];
        if (emptyRequestQueue) {
            [self dequeueMasternodeListRequest];
        }
    }
}

-(void)getMasternodeListForBlockHeight:(uint32_t)blockHeight previousBlockHeight:(uint32_t)previousBlockHeight error:(NSError**)error {
    DSMerkleBlock * merkleBlock = [self.chain blockAtHeight:blockHeight];
    if (!merkleBlock) {
        *error = [NSError errorWithDomain:@"DashSync" code:600 userInfo:@{NSLocalizedDescriptionKey:@"Unknown block"}];
        return;
    }
    DSMerkleBlock * previousMerkleBlock = previousBlockHeight?[self.chain blockAtHeight:previousBlockHeight]:nil;
    if (previousBlockHeight && !previousMerkleBlock) {
        *error = [NSError errorWithDomain:@"DashSync" code:600 userInfo:@{NSLocalizedDescriptionKey:@"Unknown previous block"}];
        return;
    }
    [self getMasternodeListForBlockHash:merkleBlock.blockHash previousBlockHash:previousMerkleBlock.blockHash];
}

-(void)getMasternodeListForBlockHash:(UInt256)blockHash previousBlockHash:(UInt256)previousBlockHash {
    self.lastQueriedBlockHash = blockHash;
    if (uint256_is_zero(previousBlockHash)) {
        //this is safe
        [self getMasternodeListsForBlockHashes:@[uint256_data(blockHash)]];
        return;
    }
    @synchronized (self.masternodeListRetrievalQueue) {
        //this is for debugging purposes only
        [self.masternodeListRetrievalQueue addObject:uint256_data(blockHash)];
        BOOL emptyRequestQueue = ![self.masternodeListRetrievalQueue count];
        if (emptyRequestQueue) {
            [self.peerManager.downloadPeer sendGetMasternodeListFromPreviousBlockHash:previousBlockHash forBlockHash:blockHash];
        }
    }
}

// MARK: - Deterministic Masternode List Sync

#define LOG_MASTERNODE_DIFF 1
#define TEST_RANDOM_ERROR_IN_MASTERNODE_DIFF 0

-(void)processMasternodeDiffMessage:(NSData*)message baseMasternodeList:(DSMasternodeList*)baseMasternodeList lastBlock:(DSMerkleBlock*)lastBlock completion:(void (^)(BOOL foundCoinbase, BOOL validCoinbase, BOOL rootMNListValid, BOOL rootQuorumListValid, BOOL validQuorums, DSMasternodeList * masternodeList, NSMutableDictionary * addedMasternodes, NSMutableDictionary * modifiedMasternodes, NSMutableDictionary * addedQuorums, NSArray * neededMissingMasternodeLists))completion {
    [DSMasternodeManager processMasternodeDiffMessage:message baseMasternodeList:baseMasternodeList knownMasternodeLists:self.masternodeListsByBlockHash lastBlock:lastBlock onChain:self.chain blockHeightLookup:^uint32_t(UInt256 blockHash) {
        return [self heightForBlockHash:blockHash];
    } completion:completion];
}

+(void)processMasternodeDiffMessage:(NSData*)message baseMasternodeList:(DSMasternodeList*)baseMasternodeList knownMasternodeLists:(NSDictionary*)knownMasternodeLists lastBlock:(DSMerkleBlock*)lastBlock onChain:(DSChain*)chain blockHeightLookup:(uint32_t(^)(UInt256 blockHash))blockHeightLookup completion:(void (^)(BOOL foundCoinbase, BOOL validCoinbase, BOOL rootMNListValid, BOOL rootQuorumListValid, BOOL validQuorums, DSMasternodeList * masternodeList, NSMutableDictionary * addedMasternodes, NSMutableDictionary * modifiedMasternodes, NSMutableDictionary * addedQuorums, NSArray * neededMissingMasternodeLists))completion {
    
    void(^failureBlock)(void) = ^{
        completion(NO,NO,NO,NO,NO,nil,nil,nil,nil,nil);
    };
    
    NSUInteger length = message.length;
    NSUInteger offset = 0;
    
    if (length - offset < 32) {
        failureBlock();
        return;
    }
    __unused UInt256 baseBlockHash = [message UInt256AtOffset:offset];
    offset += 32;
    
    if (length - offset < 32) {
        failureBlock();
        return;
    }
    UInt256 blockHash = [message UInt256AtOffset:offset];
    offset += 32;
    
    if (length - offset < 4) {
        failureBlock();
        return;
    }
    uint32_t totalTransactions = [message UInt32AtOffset:offset];
    offset += 4;
    
    if (length - offset < 1) {
        failureBlock();
        return;
    }
    
    NSNumber * merkleHashCountLength;
    NSUInteger merkleHashCount = (NSUInteger)[message varIntAtOffset:offset length:&merkleHashCountLength]*sizeof(UInt256);
    offset += [merkleHashCountLength unsignedLongValue];
    
    
    NSData * merkleHashes = [message subdataWithRange:NSMakeRange(offset, merkleHashCount)];
    offset += merkleHashCount;
    
    NSNumber * merkleFlagCountLength;
    NSUInteger merkleFlagCount = (NSUInteger)[message varIntAtOffset:offset length:&merkleFlagCountLength];
    offset += [merkleFlagCountLength unsignedLongValue];
    
    
    NSData * merkleFlags = [message subdataWithRange:NSMakeRange(offset, merkleFlagCount)];
    offset += merkleFlagCount;
    
    
    DSCoinbaseTransaction *coinbaseTransaction = (DSCoinbaseTransaction*)[DSTransactionFactory transactionWithMessage:[message subdataWithRange:NSMakeRange(offset, message.length - offset)] onChain:chain];
    if (![coinbaseTransaction isMemberOfClass:[DSCoinbaseTransaction class]]) return;
    offset += coinbaseTransaction.payloadOffset;
    
    if (length - offset < 1) {
        failureBlock();
        return;
    }
    NSNumber * deletedMasternodeCountLength;
    uint64_t deletedMasternodeCount = [message varIntAtOffset:offset length:&deletedMasternodeCountLength];
    offset += [deletedMasternodeCountLength unsignedLongValue];
    
    NSMutableArray * deletedMasternodeHashes = [NSMutableArray array];
    
    while (deletedMasternodeCount >= 1) {
        if (length - offset < 32) {
            failureBlock();
            return;
        }
        [deletedMasternodeHashes addObject:[NSData dataWithUInt256:[message UInt256AtOffset:offset]].reverse];
        offset += 32;
        deletedMasternodeCount--;
    }
    
    if (length - offset < 1) {
        failureBlock();
        return;
    }
    NSNumber * addedMasternodeCountLength;
    uint64_t addedMasternodeCount = [message varIntAtOffset:offset length:&addedMasternodeCountLength];
    offset += [addedMasternodeCountLength unsignedLongValue];
    
    NSMutableDictionary * addedOrModifiedMasternodes = [NSMutableDictionary dictionary];
    
    while (addedMasternodeCount >= 1) {
        if (length - offset < [DSSimplifiedMasternodeEntry payloadLength]) return;
        NSData * data = [message subdataWithRange:NSMakeRange(offset, [DSSimplifiedMasternodeEntry payloadLength])];
        DSSimplifiedMasternodeEntry * simplifiedMasternodeEntry = [DSSimplifiedMasternodeEntry simplifiedMasternodeEntryWithData:data onChain:chain];
        [addedOrModifiedMasternodes setObject:simplifiedMasternodeEntry forKey:[NSData dataWithUInt256:simplifiedMasternodeEntry.providerRegistrationTransactionHash].reverse];
        offset += [DSSimplifiedMasternodeEntry payloadLength];
        addedMasternodeCount--;
    }
    
    NSMutableDictionary * addedMasternodes = [addedOrModifiedMasternodes mutableCopy];
    if (baseMasternodeList) [addedMasternodes removeObjectsForKeys:baseMasternodeList.reversedRegistrationTransactionHashes];
    NSMutableSet * modifiedMasternodeKeys;
    if (baseMasternodeList) {
        modifiedMasternodeKeys = [NSMutableSet setWithArray:[addedOrModifiedMasternodes allKeys]];
        [modifiedMasternodeKeys intersectSet:[NSSet setWithArray:baseMasternodeList.reversedRegistrationTransactionHashes]];
    } else {
        modifiedMasternodeKeys = [NSMutableSet set];
    }
    NSMutableDictionary * modifiedMasternodes = [NSMutableDictionary dictionary];
    for (NSData * data in modifiedMasternodeKeys) {
        [modifiedMasternodes setObject:addedOrModifiedMasternodes[data] forKey:data];
    }
    
    NSMutableDictionary * deletedQuorums = [NSMutableDictionary dictionary];
    NSMutableDictionary * addedQuorums = [NSMutableDictionary dictionary];
    
    BOOL quorumsActive = (coinbaseTransaction.coinbaseTransactionVersion >= 2);
    
    BOOL validQuorums = TRUE;
    
    NSMutableArray * neededMasternodeLists = [NSMutableArray array]; //if quorums are not active this stays empty
    
    if (quorumsActive) {
        if (length - offset < 1) {
            failureBlock();
            return;
        }
        NSNumber * deletedQuorumsCountLength;
        uint64_t deletedQuorumsCount = [message varIntAtOffset:offset length:&deletedQuorumsCountLength];
        offset += [deletedQuorumsCountLength unsignedLongValue];
        
        while (deletedQuorumsCount >= 1) {
            if (length - offset < 33) {
                failureBlock();
                return;
            }
            DSLLMQ llmq;
            llmq.type = [message UInt8AtOffset:offset];
            llmq.hash = [message UInt256AtOffset:offset + 1];
            if (![deletedQuorums objectForKey:@(llmq.type)]) {
                [deletedQuorums setObject:[NSMutableArray arrayWithObject:[NSData dataWithUInt256:llmq.hash]] forKey:@(llmq.type)];
            } else {
                NSMutableArray * mutableLLMQArray = [deletedQuorums objectForKey:@(llmq.type)];
                [mutableLLMQArray addObject:[NSData dataWithUInt256:llmq.hash]];
            }
            offset += 33;
            deletedQuorumsCount--;
        }
        
        if (length - offset < 1) {
            failureBlock();
            return;
        }
        NSNumber * addedQuorumsCountLength;
        uint64_t addedQuorumsCount = [message varIntAtOffset:offset length:&addedQuorumsCountLength];
        offset += [addedQuorumsCountLength unsignedLongValue];
        
        while (addedQuorumsCount >= 1) {
            DSQuorumEntry * potentialQuorumEntry = [DSQuorumEntry potentialQuorumEntryWithData:message dataOffset:(uint32_t)offset onChain:chain];
            
            DSMasternodeList * quorumMasternodeList = [knownMasternodeLists objectForKey:uint256_data(potentialQuorumEntry.quorumHash)];
            
            if (quorumMasternodeList) {
                validQuorums &= [potentialQuorumEntry validateWithMasternodeList:quorumMasternodeList];
                if (!validQuorums) {
                    DSDLog(@"Invalid Quorum Found");
                }
            } else {
                
                if (blockHeightLookup(potentialQuorumEntry.quorumHash) != UINT32_MAX) {
                    [neededMasternodeLists addObject:uint256_data(potentialQuorumEntry.quorumHash)];
                }
            }
            
            if (![addedQuorums objectForKey:@(potentialQuorumEntry.llmqType)]) {
                [addedQuorums setObject:[NSMutableDictionary dictionaryWithObject:potentialQuorumEntry forKey:[NSData dataWithUInt256:potentialQuorumEntry.quorumHash]] forKey:@(potentialQuorumEntry.llmqType)];
            } else {
                NSMutableDictionary * mutableLLMQDictionary = [addedQuorums objectForKey:@(potentialQuorumEntry.llmqType)];
                [mutableLLMQDictionary setObject:potentialQuorumEntry forKey:[NSData dataWithUInt256:potentialQuorumEntry.quorumHash]];
            }
            offset += potentialQuorumEntry.length;
            addedQuorumsCount--;
        }
    }
    
    DSMasternodeList * masternodeList = [DSMasternodeList masternodeListAtBlockHash:blockHash atBlockHeight:blockHeightLookup(blockHash) fromBaseMasternodeList:baseMasternodeList addedMasternodes:addedMasternodes removedMasternodeHashes:deletedMasternodeHashes modifiedMasternodes:modifiedMasternodes addedQuorums:addedQuorums removedQuorumHashesByType:deletedQuorums onChain:chain];
    
    BOOL rootMNListValid = uint256_eq(coinbaseTransaction.merkleRootMNList, masternodeList.masternodeMerkleRoot);
    
    if (!rootMNListValid) {
        DSDLog(@"Masternode Merkle root not valid for DML on block %d version %d (%@ wanted - %@ calculated)",coinbaseTransaction.height,coinbaseTransaction.version,uint256_hex(coinbaseTransaction.merkleRootMNList),uint256_hex(masternodeList.masternodeMerkleRoot));
    }
    
    BOOL rootQuorumListValid = TRUE;
    
    if (quorumsActive) {
        rootQuorumListValid = uint256_eq(coinbaseTransaction.merkleRootLLMQList, masternodeList.quorumMerkleRoot);
        
        if (!rootQuorumListValid) {
            DSDLog(@"Quorum Merkle root not valid for DML on block %d version %d (%@ wanted - %@ calculated)",coinbaseTransaction.height,coinbaseTransaction.version,uint256_hex(coinbaseTransaction.merkleRootLLMQList),uint256_hex(masternodeList.quorumMerkleRoot));
        }
    }
    
    //we need to check that the coinbase is in the transaction hashes we got back
    UInt256 coinbaseHash = coinbaseTransaction.txHash;
    BOOL foundCoinbase = FALSE;
    for (int i = 0;i<merkleHashes.length;i+=32) {
        UInt256 randomTransactionHash = [merkleHashes UInt256AtOffset:i];
        if (uint256_eq(coinbaseHash, randomTransactionHash)) {
            foundCoinbase = TRUE;
            break;
        }
    }
    
    //we also need to check that the coinbase is in the merkle block
    DSMerkleBlock * coinbaseVerificationMerkleBlock = [[DSMerkleBlock alloc] initWithBlockHash:blockHash merkleRoot:lastBlock.merkleRoot totalTransactions:totalTransactions hashes:merkleHashes flags:merkleFlags];
    
    BOOL validCoinbase = [coinbaseVerificationMerkleBlock isMerkleTreeValid];
    
#if TEST_RANDOM_ERROR_IN_MASTERNODE_DIFF
    //test random errors
    uint32_t chance = 20; //chance is 1/10
    
    completion((arc4random_uniform(chance) != 0) && foundCoinbase,(arc4random_uniform(chance) != 0) && validCoinbase,(arc4random_uniform(chance) != 0) && rootMNListValid,(arc4random_uniform(chance) != 0) && rootQuorumListValid,(arc4random_uniform(chance) != 0) && validQuorums, masternodeList, addedMasternodes, modifiedMasternodes, addedQuorums, neededMasternodeLists);
#else
    
    //normal completion
    completion(foundCoinbase,validCoinbase,rootMNListValid,rootQuorumListValid,validQuorums, masternodeList, addedMasternodes, modifiedMasternodes, addedQuorums, neededMasternodeLists);
    
#endif
    
    
}




-(void)peer:(DSPeer *)peer relayedMasternodeDiffMessage:(NSData*)message {
#if LOG_MASTERNODE_DIFF
    NSUInteger chunkSize = 4096;
    NSUInteger chunks = ceilf(((float)message.length)/chunkSize);
    for (int i = 0;i<chunks;) {
        NSInteger lengthLeft = message.length - i*chunkSize;
        if (lengthLeft < 0) continue;
        DSDLog(@"Logging masternode DIFF message chunk %d %@",i,[message subdataWithRange:NSMakeRange(i*chunkSize, MIN(lengthLeft, chunkSize))].hexString);
        i++;
    }
    DSDLog(@"Logging masternode DIFF message hash %@",[NSData dataWithUInt256:message.SHA256].hexString);
#endif
    
    NSUInteger length = message.length;
    NSUInteger offset = 0;
    
    if (length - offset < 32) return;
    UInt256 baseBlockHash = [message UInt256AtOffset:offset];
    offset += 32;
    
    if (length - offset < 32) return;
    UInt256 blockHash = [message UInt256AtOffset:offset];
    offset += 32;
    
    DSDLog(@"baseBlockHash %@ (%u) blockHash %@ (%u)",uint256_reverse_hex(baseBlockHash), [self.chain heightForBlockHash:baseBlockHash], uint256_reverse_hex(blockHash),[self.chain heightForBlockHash:blockHash]);
    
    DSMasternodeList * baseMasternodeList = [self.masternodeListsByBlockHash objectForKey:uint256_data(baseBlockHash)];
    
    if (!baseMasternodeList && !uint256_eq(self.chain.genesisHash, baseBlockHash) && !uint256_is_zero(baseBlockHash)) {
        //this could have been deleted in the meantime, if so rerequest
        [self issueWithMasternodeListFromPeer:peer];
        DSDLog(@"No base masternode list");
        return;
    };
    
    DSMerkleBlock * lastBlock = peer.chain.lastBlock;
    
    while (lastBlock && !uint256_eq(lastBlock.blockHash, blockHash)) {
        lastBlock = peer.chain.recentBlocks[uint256_obj(lastBlock.prevBlock)];
    }
    
    if (!lastBlock) {
        [self issueWithMasternodeListFromPeer:peer];
        DSDLog(@"Last Block missing");
        return;
    }
    
    [self processMasternodeDiffMessage:message baseMasternodeList:baseMasternodeList lastBlock:lastBlock completion:^(BOOL foundCoinbase, BOOL validCoinbase, BOOL rootMNListValid, BOOL rootQuorumListValid, BOOL validQuorums, DSMasternodeList *masternodeList, NSMutableDictionary *addedMasternodes, NSMutableDictionary *modifiedMasternodes, NSMutableDictionary *addedQuorums, NSArray *neededMissingMasternodeLists) {
        
        
        if (foundCoinbase && validCoinbase && rootMNListValid && rootQuorumListValid && validQuorums) {
            DSDLog(@"Valid masternode list found at height %u",[self heightForBlockHash:blockHash]);
            //yay this is the correct masternode list verified deterministically for the given block
            
            NSArray * updatedSimplifiedMasternodeEntries = [addedMasternodes.allValues arrayByAddingObjectsFromArray:modifiedMasternodes.allValues];
            [self.chain updateAddressUsageOfSimplifiedMasternodeEntries:updatedSimplifiedMasternodeEntries];
            
            if ([neededMissingMasternodeLists count] && uint256_eq(self.lastQueriedBlockHash,blockHash)) {
                DSDLog(@"Last masternode list is missing previous masternode lists for quorum validation");
                
                //This is the current one, get more previous masternode lists we need to verify quorums
                
                self.masternodeListAwaitingQuorumValidation = masternodeList;
                
                [self.masternodeListRetrievalQueue removeObject:uint256_data(blockHash)];
                NSMutableArray * neededMasternodeLists = [neededMissingMasternodeLists mutableCopy];
                [neededMasternodeLists addObject:uint256_data(self.chain.lastBlock.blockHash)]; //also get the current one again
                [self getMasternodeListsForBlockHashes:neededMasternodeLists];
                return;
            } else {
                NSLog(@"a");
                if (uint256_eq(self.lastQueriedBlockHash,blockHash)) {
                    //this is now the current masternode list
                    self.currentMasternodeList = masternodeList;
                }
                if (uint256_eq(self.masternodeListAwaitingQuorumValidation.blockHash,blockHash)) {
                    self.masternodeListAwaitingQuorumValidation = nil;
                }
                NSLog(@"b");
                if (!self.masternodeListsByBlockHash[uint256_data(blockHash)]) {
                    //in rare race conditions this might already exist
                    [self saveMasternodeList:masternodeList havingModifiedMasternodes:modifiedMasternodes
                                addedQuorums:addedQuorums];
                }
                
                NSLog(@"c");
                if (uint256_eq(self.lastQueriedBlockHash,blockHash)) {
                    [self removeOldMasternodeLists];
                }
                NSLog(@"d");
                NSAssert([self.masternodeListRetrievalQueue containsObject:uint256_data(blockHash)], @"This should still be here");
                [self.masternodeListRetrievalQueue removeObject:uint256_data(blockHash)];
                DSDLog(@"Last masternode list is missing previous masternode lists for quorum validation");
                [self dequeueMasternodeListRequest];
                
                [[NSUserDefaults standardUserDefaults] removeObjectForKey:CHAIN_FAULTY_DML_MASTERNODE_PEERS];
                
                //check for instant send locks that were awaiting a quorum
                
                if (![self.masternodeListRetrievalQueue count]) {
                    [self.chain.chainManager.transactionManager checkInstantSendLocksWaitingForQuorums];
                }
            }
        } else {
            if (!foundCoinbase) DSDLog(@"Did not find coinbase at height %u",[self heightForBlockHash:blockHash]);
            if (!validCoinbase) DSDLog(@"Coinbase not valid at height %u",[self heightForBlockHash:blockHash]);
            if (!rootMNListValid) DSDLog(@"rootMNListValid not valid at height %u",[self heightForBlockHash:blockHash]);
            if (!rootQuorumListValid) DSDLog(@"rootQuorumListValid not valid at height %u",[self heightForBlockHash:blockHash]);
            if (!validQuorums) DSDLog(@"validQuorums not valid at height %u",[self heightForBlockHash:blockHash]);
            [self issueWithMasternodeListFromPeer:peer];
        }
        
    }];
}

-(BOOL)saveMasternodeList:(DSMasternodeList*)masternodeList havingModifiedMasternodes:(NSDictionary*)modifiedMasternodes addedQuorums:(NSDictionary*)addedQuorums {
    __block BOOL hasError = NO;
    [self.managedObjectContext performBlockAndWait:^{
        //masternodes
        [DSSimplifiedMasternodeEntryEntity setContext:self.managedObjectContext];
        [DSChainEntity setContext:self.managedObjectContext];
        [DSLocalMasternodeEntity setContext:self.managedObjectContext];
        [DSAddressEntity setContext:self.managedObjectContext];
        [DSMasternodeListEntity setContext:self.managedObjectContext];
        [DSQuorumEntryEntity setContext:self.managedObjectContext];
        [DSMerkleBlockEntity setContext:self.managedObjectContext];
        DSChainEntity * chainEntity = self.chain.chainEntity;
        DSMerkleBlockEntity * merkleBlockEntity = [DSMerkleBlockEntity anyObjectMatching:@"blockHash == %@",uint256_data(masternodeList.blockHash)];
        NSAssert(merkleBlockEntity, @"merkle block should exist");
        NSAssert(!merkleBlockEntity.masternodeList, @"merkle block should not have a masternode list already");
        if (!merkleBlockEntity || merkleBlockEntity.masternodeList) hasError = YES;
        
        if (!hasError) {
            DSMasternodeListEntity * masternodeListEntity = [DSMasternodeListEntity managedObject];
            masternodeListEntity.block = merkleBlockEntity;
            uint32_t i = 0;
            for (DSSimplifiedMasternodeEntry * simplifiedMasternodeEntry in masternodeList.simplifiedMasternodeEntries) {
                if (i % 100 == 0) DSDLog(@"MN %@",@(i));
                DSSimplifiedMasternodeEntryEntity * simplifiedMasternodeEntryEntity = [DSSimplifiedMasternodeEntryEntity simplifiedMasternodeEntryForProviderRegistrationTransactionHash:[NSData dataWithUInt256:simplifiedMasternodeEntry.providerRegistrationTransactionHash] onChain:chainEntity];
                if (!simplifiedMasternodeEntryEntity) {
                    simplifiedMasternodeEntryEntity = [DSSimplifiedMasternodeEntryEntity managedObject];
                    [simplifiedMasternodeEntryEntity setAttributesFromSimplifiedMasternodeEntry:simplifiedMasternodeEntry onChain:chainEntity];
                }
                [masternodeListEntity addMasternodesObject:simplifiedMasternodeEntryEntity];
                i++;
            }
            for (NSData * simplifiedMasternodeEntryHash in modifiedMasternodes) {
                DSSimplifiedMasternodeEntry * simplifiedMasternodeEntry = modifiedMasternodes[simplifiedMasternodeEntryHash];
                DSSimplifiedMasternodeEntryEntity * simplifiedMasternodeEntryEntity = [DSSimplifiedMasternodeEntryEntity simplifiedMasternodeEntryForProviderRegistrationTransactionHash:[NSData dataWithUInt256:simplifiedMasternodeEntry.providerRegistrationTransactionHash] onChain:chainEntity];
                [simplifiedMasternodeEntryEntity updateAttributesFromSimplifiedMasternodeEntry:simplifiedMasternodeEntry];
            }
            for (NSNumber * llmqType in masternodeList.quorums) {
                NSDictionary * quorumsForMasternodeType = masternodeList.quorums[llmqType];
                for (NSData * quorumHash in quorumsForMasternodeType) {
                    DSQuorumEntry * potentialQuorumEntry = quorumsForMasternodeType[quorumHash];
                    DSQuorumEntryEntity * quorumEntry = [DSQuorumEntryEntity quorumEntryEntityFromPotentialQuorumEntry:potentialQuorumEntry];
                    [masternodeListEntity addQuorumsObject:quorumEntry];
                }
            }
            chainEntity.baseBlockHash = [NSData dataWithUInt256:masternodeList.blockHash];
            
            NSError * error = [DSSimplifiedMasternodeEntryEntity saveContext];
            hasError = !!error;
        }
        if (hasError) {
            [self.masternodeListRetrievalQueue removeAllObjects];
            chainEntity.baseBlockHash = uint256_data(self.chain.genesisHash);
            [DSLocalMasternodeEntity deleteAllOnChain:chainEntity];
            [DSSimplifiedMasternodeEntryEntity deleteAllOnChain:chainEntity];
            [DSQuorumEntryEntity deleteAllOnChain:chainEntity];
            [self wipeMasternodeInfo];
            [DSSimplifiedMasternodeEntryEntity saveContext];
            dispatch_async([self peerManager].chainPeerManagerQueue, ^{
                [self getCurrentMasternodeListWithSafetyDelay:0];
            });
        } else {
            [self.masternodeListsByBlockHash setObject:masternodeList forKey:uint256_data(masternodeList.blockHash)];
        }
    }];
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:DSMasternodeListDidChangeNotification object:nil userInfo:@{DSChainManagerNotificationChainKey:self.chain}];
        
        [[NSNotificationCenter defaultCenter] postNotificationName:DSQuorumListDidChangeNotification object:nil userInfo:@{DSChainManagerNotificationChainKey:self.chain}];
    });
    return !hasError;
}

-(void)removeOldMasternodeLists {
    if (!self.currentMasternodeList) return;
    [self.managedObjectContext performBlockAndWait:^{
        uint32_t lastBlockHeight = self.currentMasternodeList.height;
        for (NSData * blockHash in [self.masternodeListsByBlockHash copy]) {
            DSMasternodeList * masternodeList = self.masternodeListsByBlockHash[blockHash];
            uint32_t height = self.masternodeListsByBlockHash[blockHash].height;
            if (height == UINT32_MAX) {
                height = [self heightForBlockHash:blockHash.UInt256];
            }
            if (height != UINT32_MAX) {
                if (lastBlockHeight - height > 50) {
                    
                    DSMasternodeListEntity * masternodeListEntity = [DSMasternodeListEntity anyObjectMatching:@"block.blockHash = %@ && (block.usedByQuorums.@count == 0)",uint256_data(masternodeList.blockHash)];
                    if (masternodeListEntity) {
                        DSDLog(@"Removing masternodeList at height %u",height);
                        DSDLog(@"quorums are %@",masternodeListEntity.block.usedByQuorums);
                        //A quorum is on a block that can only have one masternode list.
                        //A block can have one quorum of each type.
                        //A quorum references the masternode list by it's block
                        //we need to check if this masternode list is being referenced by a quorum using the inverse of quorum.block.masternodeList
                        
                        [self.managedObjectContext deleteObject:masternodeListEntity];
                        [self.masternodeListsByBlockHash removeObjectForKey:blockHash];
                        
                        //Now we should delete old quorums
                        //To do this, first get the last 24 active masternode lists
                        //Then check for quorums not referenced by them, and delete those
                        
                        NSArray<DSMasternodeListEntity *> * recentMasternodeLists = [DSMasternodeListEntity objectsSortedBy:@"block.height" ascending:NO offset:0 limit:10];
                        
                        uint32_t oldestBlockHeight = MIN(recentMasternodeLists[9].block.height,lastBlockHeight - 24);
                        
                        //NSArray * oldQuorums = [DSQuorumEntryEntity objectsMatching:@"ALL referencedByMasternodeLists.block.height < %@",@(oldestBlockHeight)];
                        
//                        NSArray * allQuorums = [DSQuorumEntryEntity allObjects];
//                        for (DSQuorumEntryEntity * quorum in allQuorums) {
//
//                            NSArray * sortedMasternodeLists = [quorum.referencedByMasternodeLists sortedArrayUsingDescriptors:@[[NSSortDescriptor sortDescriptorWithKey:@"block.height" ascending:YES]]];
//                            DSDLog(@"quorum %@ at height %u USED BY",quorum,quorum.block.height);
//                            for (DSMasternodeListEntity * masternodeList in sortedMasternodeLists) {
//                                DSDLog(@"masternodeList at height %u",masternodeList.block.height);
//                                if (masternodeList.block.height == 118272) {
//                                    DSDLog(@"%@ - %@ - %lu USED BY QUORUMS",masternodeList,masternodeList.block,(unsigned long)masternodeList.block.usedByQuorums.count);
//                                    for (DSQuorumEntryEntity * quorumEntryEntity in masternodeList.block.usedByQuorums) {
//                                        DSDLog(@"quorumEntryEntity %@ at height %u",quorumEntryEntity,quorumEntryEntity.block.height);
//
//                                    }
//                                }
//                            }
//                        }
//                        NSArray * oldUnusedQuorums = [DSQuorumEntryEntity objectsMatching:@"(usedByMasternodeLists.@count == 0)"];
                        //for (DSQuorumEntryEntity * unusedQuorumEntryEntity in [oldQuorums copy]) {
                        //    [self.managedObjectContext deleteObject:unusedQuorumEntryEntity];
                        //}
                    }
                }
            }
        }
    }];
}

-(void)issueWithMasternodeListFromPeer:(DSPeer *)peer {
    
    [self.peerManager peerMisbehaving:peer errorMessage:@"Issue with Deterministic Masternode list"];
    
    NSArray * faultyPeers = [[NSUserDefaults standardUserDefaults] arrayForKey:CHAIN_FAULTY_DML_MASTERNODE_PEERS];
    
    if (faultyPeers.count == MAX_FAULTY_DML_PEERS) {
        DSDLog(@"Exceeded max failures for masternode list, starting from scratch");
        //no need to remove local masternodes
        [self.masternodeListRetrievalQueue removeAllObjects];
        
        NSManagedObjectContext * context = [NSManagedObject context];
        [context performBlockAndWait:^{
            [DSMasternodeListEntity setContext:context];
            [DSSimplifiedMasternodeEntryEntity setContext:context];
            [DSQuorumEntryEntity setContext:context];
            DSChainEntity * chainEntity = peer.chain.chainEntity;
            [DSMasternodeListEntity deleteAllOnChain:chainEntity];
            [DSQuorumEntryEntity deleteAllOnChain:chainEntity];
            [DSSimplifiedMasternodeEntryEntity deleteAllOnChain:chainEntity];
        }];
        
        [self.masternodeListsByBlockHash removeAllObjects];
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:CHAIN_FAULTY_DML_MASTERNODE_PEERS];
        
        [self getCurrentMasternodeListWithSafetyDelay:0];
    } else {
        
        if (!faultyPeers) {
            faultyPeers = @[peer.location];
        } else {
            if (![faultyPeers containsObject:peer.location]) {
                faultyPeers = [faultyPeers arrayByAddingObject:peer.location];
            }
        }
        [[NSUserDefaults standardUserDefaults] setObject:faultyPeers forKey:CHAIN_FAULTY_DML_MASTERNODE_PEERS];
        [self dequeueMasternodeListRequest];
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:DSMasternodeListDiffValidationErrorNotification object:nil userInfo:@{DSChainManagerNotificationChainKey:self.chain}];
    });
}

// MARK: - Quorums

-(DSQuorumEntry*)quorumEntryForInstantSendRequestID:(UInt256)requestID withBlockHeightOffset:(uint32_t)blockHeightOffset {
    DSMerkleBlock * merkleBlock = [self.chain blockFromChainTip:blockHeightOffset];
    DSMasternodeList * masternodeList = [self masternodeListBeforeBlockHash:merkleBlock.blockHash];
    if (!masternodeList) {
        DSDLog(@"No masternode list found yet");
        return nil;
    }
    NSArray * quorumsForIS = [masternodeList.quorums[@(1)] allValues];
    UInt256 lowestValue = UINT256_MAX;
    DSQuorumEntry * firstQuorum = nil;
    for (DSQuorumEntry * quorumEntry in quorumsForIS) {
        UInt256 orderingHash = uint256_reverse([quorumEntry orderingHashForRequestID:requestID]);
        if (uint256_sup(lowestValue, orderingHash)) {
            lowestValue = orderingHash;
            firstQuorum = quorumEntry;
        }
    }
    return firstQuorum;
}

// MARK: - Local Masternodes

-(DSLocalMasternode*)createNewMasternodeWithIPAddress:(UInt128)ipAddress onPort:(uint32_t)port inWallet:(DSWallet*)wallet {
    NSParameterAssert(wallet);
    
    return [self createNewMasternodeWithIPAddress:ipAddress onPort:port inFundsWallet:wallet inOperatorWallet:wallet inOwnerWallet:wallet inVotingWallet:wallet];
}

-(DSLocalMasternode*)createNewMasternodeWithIPAddress:(UInt128)ipAddress onPort:(uint32_t)port inFundsWallet:(DSWallet*)fundsWallet inOperatorWallet:(DSWallet*)operatorWallet inOwnerWallet:(DSWallet*)ownerWallet inVotingWallet:(DSWallet*)votingWallet {
    DSLocalMasternode * localMasternode = [[DSLocalMasternode alloc] initWithIPAddress:ipAddress onPort:port inFundsWallet:fundsWallet inOperatorWallet:operatorWallet inOwnerWallet:ownerWallet inVotingWallet:votingWallet];
    return localMasternode;
}

-(DSLocalMasternode*)createNewMasternodeWithIPAddress:(UInt128)ipAddress onPort:(uint32_t)port inFundsWallet:(DSWallet* _Nullable)fundsWallet fundsWalletIndex:(uint32_t)fundsWalletIndex inOperatorWallet:(DSWallet* _Nullable)operatorWallet operatorWalletIndex:(uint32_t)operatorWalletIndex inOwnerWallet:(DSWallet* _Nullable)ownerWallet ownerWalletIndex:(uint32_t)ownerWalletIndex inVotingWallet:(DSWallet* _Nullable)votingWallet votingWalletIndex:(uint32_t)votingWalletIndex {
    DSLocalMasternode * localMasternode = [[DSLocalMasternode alloc] initWithIPAddress:ipAddress onPort:port inFundsWallet:fundsWallet fundsWalletIndex:fundsWalletIndex inOperatorWallet:operatorWallet operatorWalletIndex:operatorWalletIndex inOwnerWallet:ownerWallet ownerWalletIndex:ownerWalletIndex inVotingWallet:votingWallet votingWalletIndex:votingWalletIndex];
    return localMasternode;
}

-(DSLocalMasternode*)localMasternodeFromSimplifiedMasternodeEntry:(DSSimplifiedMasternodeEntry*)simplifiedMasternodeEntry claimedWithOwnerWallet:(DSWallet*)ownerWallet ownerKeyIndex:(uint32_t)ownerKeyIndex {
    NSParameterAssert(simplifiedMasternodeEntry);
    NSParameterAssert(ownerWallet);
    
    DSLocalMasternode * localMasternode = [self localMasternodeHavingProviderRegistrationTransactionHash:simplifiedMasternodeEntry.providerRegistrationTransactionHash];
    
    if (localMasternode) return localMasternode;
    
    uint32_t votingIndex;
    DSWallet * votingWallet = [simplifiedMasternodeEntry.chain walletHavingProviderVotingAuthenticationHash:simplifiedMasternodeEntry.keyIDVoting foundAtIndex:&votingIndex];
    
    uint32_t operatorIndex;
    DSWallet * operatorWallet = [simplifiedMasternodeEntry.chain walletHavingProviderOperatorAuthenticationKey:simplifiedMasternodeEntry.operatorPublicKey foundAtIndex:&operatorIndex];
    
    if (votingWallet || operatorWallet) {
        return [[DSLocalMasternode alloc] initWithIPAddress:simplifiedMasternodeEntry.address onPort:simplifiedMasternodeEntry.port inFundsWallet:nil fundsWalletIndex:0 inOperatorWallet:operatorWallet operatorWalletIndex:operatorIndex inOwnerWallet:ownerWallet ownerWalletIndex:ownerKeyIndex inVotingWallet:votingWallet votingWalletIndex:votingIndex];
    } else {
        return nil;
    }
}

-(DSLocalMasternode*)localMasternodeFromProviderRegistrationTransaction:(DSProviderRegistrationTransaction*)providerRegistrationTransaction save:(BOOL)save {
    NSParameterAssert(providerRegistrationTransaction);
    
    //First check to see if we have a local masternode for this provider registration hash
    
    @synchronized (self) {
        DSLocalMasternode * localMasternode = self.localMasternodesDictionaryByRegistrationTransactionHash[uint256_data(providerRegistrationTransaction.txHash)];
        
        if (localMasternode) {
            //We do
            //todo Update keys
            return localMasternode;
        }
        //We don't
        localMasternode = [[DSLocalMasternode alloc] initWithProviderTransactionRegistration:providerRegistrationTransaction];
        
        if (localMasternode.noLocalWallet) return nil;
        [self.localMasternodesDictionaryByRegistrationTransactionHash setObject:localMasternode forKey:uint256_data(providerRegistrationTransaction.txHash)];
        [localMasternode save];
        return localMasternode;
    }
}

-(DSLocalMasternode*)localMasternodeHavingProviderRegistrationTransactionHash:(UInt256)providerRegistrationTransactionHash {
    DSLocalMasternode * localMasternode = self.localMasternodesDictionaryByRegistrationTransactionHash[uint256_data(providerRegistrationTransactionHash)];
    
    return localMasternode;
    
}

-(DSLocalMasternode*)localMasternodeUsingIndex:(uint32_t)index atDerivationPath:(DSDerivationPath*)derivationPath {
    NSParameterAssert(derivationPath);
    
    for (DSLocalMasternode * localMasternode in self.localMasternodesDictionaryByRegistrationTransactionHash.allValues) {
        switch (derivationPath.reference) {
            case DSDerivationPathReference_ProviderFunds:
                if (localMasternode.holdingKeysWallet == derivationPath.wallet && localMasternode.holdingWalletIndex == index) {
                    return localMasternode;
                }
                break;
            case DSDerivationPathReference_ProviderOwnerKeys:
                if (localMasternode.ownerKeysWallet == derivationPath.wallet && localMasternode.ownerWalletIndex == index) {
                    return localMasternode;
                }
                break;
            case DSDerivationPathReference_ProviderOperatorKeys:
                if (localMasternode.operatorKeysWallet == derivationPath.wallet && localMasternode.operatorWalletIndex == index) {
                    return localMasternode;
                }
                break;
            case DSDerivationPathReference_ProviderVotingKeys:
                if (localMasternode.votingKeysWallet == derivationPath.wallet && localMasternode.votingWalletIndex == index) {
                    return localMasternode;
                }
                break;
            default:
                break;
        }
    }
    return nil;
}

-(NSUInteger)localMasternodesCount {
    return [self.localMasternodesDictionaryByRegistrationTransactionHash count];
}


@end
