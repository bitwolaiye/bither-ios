//  TransactionsUtil.m
//  bither-ios
//
//  Copyright 2014 http://Bither.net
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//    http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.

#import "TransactionsUtil.h"
#import "NSDictionary+Fromat.h"
#import "DateUtil.h"
#import "BitherApi.h"
#import "BTAddressManager.h"
#import "BTBlockChain.h"
#import "BTIn.h"
#import "UnitUtil.h"
#import "BTHDAccountProvider.h"


#define BLOCK_COUNT  @"block_count"

#define TX_VER @"ver"
#define TX_IN @"in"
#define TX_OUT @"out"

#define TX_OUT_ADDRESS @"address"
#define TX_COINBASE @"coinbase"
#define TX_SEQUENCE @"sequence"
#define TX_TIME @"time"

#define TXS @"txs"
#define BLOCK_HASH @"block_hash"
#define TX_HASH @"tx_hash"
#define BLOCK_NO @"block_no"
#define VALUE @"val"
#define PREV_TX_HASH @"prev"
#define PREV_OUTPUT_SN @"n"
#define SCRIPT_PUB_KEY @"script"

#define SPECIAL_TYPE @"special_type"


@implementation TransactionsUtil

+ (void)getAddressState:(NSArray *)addressList index:(NSInteger)index callback:(IdResponseBlock)callback andErrorCallback:(ErrorBlock)errorBlcok {
    if (index == addressList.count) {
        if (callback) {
            callback([NSNumber numberWithInt:AddressNormal]);
        }
    } else {
        NSString *address = [addressList objectAtIndex:index];
        index++;
        [[BitherApi instance] getMyTransactionApi:address callback:^(NSDictionary *dict) {
            if ([[dict allKeys] containsObject:SPECIAL_TYPE]) {
                NSInteger specialType = [dict getIntFromDict:SPECIAL_TYPE];
                if (specialType == 0) {
                    if (callback) {
                        callback([NSNumber numberWithInt:AddressSpecialAddress]);
                    }
                } else {
                    if (callback) {
                        callback([NSNumber numberWithInt:AddressTxTooMuch]);
                    }
                }
            } else {
                [self getAddressState:addressList index:index callback:callback andErrorCallback:errorBlcok];
            }
        }                        andErrorCallBack:^(NSOperation *errorOp, NSError *error) {
            if (errorBlcok) {
                errorBlcok(error);
            }
        }];
    }

}

+ (NSArray *)getTransactions:(NSDictionary *)dict storeBlockHeight:(uint32_t)storeBlockHeigth {
    NSMutableArray *array = [NSMutableArray new];
    if ([[dict allKeys] containsObject:TXS]) {
        NSArray *txs = [dict objectForKey:TXS];
        for (NSDictionary *txDict in  txs) {
            BTTx *tx = [[BTTx alloc] init];
            //  NSData * blockHashData=[[[txDict getStringFromDict:BLOCK_HASH] hexToData] reverse];
            NSData *txHash = [[txDict getStringFromDict:TX_HASH] hexToData].reverse;
            uint32_t blockNo = [txDict getIntFromDict:BLOCK_NO];

            if (storeBlockHeigth > 0 && blockNo > storeBlockHeigth) {
                continue;
            }
            int version = [txDict getIntFromDict:TX_VER andDefault:1];
            NSString *timeStr = [txDict getStringFromDict:TX_TIME];
            uint32_t time = [[DateUtil getDateFormStringWithTimeZone:timeStr] timeIntervalSince1970];
            [tx setTxHash:txHash];
            [tx setTxVer:version];
            [tx setBlockNo:blockNo];
            [tx setTxTime:time];
            if ([[txDict allKeys] containsObject:TX_OUT]) {
                NSArray *outArray = [txDict objectForKey:TX_OUT];
                for (NSDictionary *outDict in outArray) {
                    uint64_t value = [outDict getLongLongFromDict:VALUE];
                    //  NSString * address=[outDict getStringFromDict:TX_OUT_ADDRESS];
                    NSString *pubKey = [outDict getStringFromDict:SCRIPT_PUB_KEY];
                    [tx addOutputScript:[pubKey hexToData] amount:value];
                }

            }
            if ([[txDict allKeys] containsObject:TX_IN]) {
                NSArray *inArray = [txDict objectForKey:TX_IN];
                for (NSDictionary *inDict in inArray) {
                    if ([[inDict allKeys] containsObject:TX_COINBASE]) {
                        int index = [inDict getIntFromDict:TX_SEQUENCE];
                        [tx addInputHash:@"".hexToData index:index script:nil];
                    } else {
                        NSData *prevOutHash = [[inDict getStringFromDict:PREV_TX_HASH] hexToData].reverse;
                        int index = [inDict getIntFromDict:PREV_OUTPUT_SN];
                        [tx addInputHash:prevOutHash index:index script:nil];
                    }

                }

            }
            NSMutableArray *txInputHashes = [NSMutableArray new];
            for (BTIn *btIn in tx.ins) {
                [txInputHashes addObject:btIn.prevTxHash];
            }
            for (BTTx *temp in array) {
                if (temp.blockNo == tx.blockNo) {
                    NSMutableArray *tempInputHashes = [NSMutableArray new];
                    for (BTIn *btIn in temp.ins) {
                        [tempInputHashes addObject:btIn.prevTxHash];
                    }
                    if ([tempInputHashes containsObject:tx.txHash]) {
                        [tx setTxTime:temp.txTime - 1];
                    } else if ([txInputHashes containsObject:temp.txHash]) {
                        [tx setTxTime:temp.txTime + 1];
                    }
                }
            }
            [array addObject:tx];

        }
    }
    [array sortUsingComparator:^NSComparisonResult(id obj1, id obj2) {
        if ([obj1 blockNo] > [obj2 blockNo]) return NSOrderedDescending;
        if ([obj1 blockNo] < [obj2 blockNo]) return NSOrderedAscending;
        if ([obj1 txTime] > [obj2 txTime]) return NSOrderedDescending;
        if ([obj1 txTime] < [obj2 txTime]) return NSOrderedAscending;
        NSLog(@"NSOrderedSame");
        return NSOrderedSame;
    }];
    return array;
}


+ (void)syncWallet:(VoidBlock)voidBlock andErrorCallBack:(ErrorHandler)errorCallback {
    NSArray *addresses = [[BTAddressManager instance] allAddresses];
    if ([[BTAddressManager instance] allSyncComplete]) {
        if (voidBlock) {
            voidBlock();
        }
        return;
    }
    __block  NSInteger index = 0;
    addresses = [addresses reverseObjectEnumerator].allObjects;
    [TransactionsUtil getMyTx:addresses index:index callback:^{
        [TransactionsUtil getMyTxForHDAccount:EXTERNAL_ROOT_PATH index:0 callback:^{
            [TransactionsUtil getMyTxForHDAccount:INTERNAL_ROOT_PATH index:0 callback:^{
                if (voidBlock) {
                    voidBlock();
                }
            }                    andErrorCallBack:errorCallback];

        }                    andErrorCallBack:errorCallback];
    }        andErrorCallBack:errorCallback];

}

+ (void)getMyTx:(NSArray *)addresses index:(NSInteger)index callback:(VoidBlock)callback andErrorCallBack:(ErrorHandler)errorCallback {
    if (index == addresses.count) {
        if (callback) {
            callback();
        }
        return;
    }
    BTAddress *address = [addresses objectAtIndex:index];
    index = index + 1;
    if (address.isSyncComplete) {
        if (index == addresses.count) {
            if (callback) {
                callback();
            }
        } else {
            [TransactionsUtil getMyTx:addresses index:index callback:callback andErrorCallBack:errorCallback];
        }
    } else {
        [TransactionsUtil getTxs:address callback:^{
            if (index == addresses.count) {
                if (callback) {
                    callback();
                }
            } else {
                [TransactionsUtil getMyTx:addresses index:index callback:callback andErrorCallBack:errorCallback];
            }
        }       andErrorCallBack:^(NSOperation *errorOp, NSError *error) {
            if (errorCallback) {
                errorCallback(errorOp, error);
            }
        }];
    }
}

+ (void)getMyTxForHDAccount:(PathType)pathType index:(int)index
                   callback:(VoidBlock)callback andErrorCallBack:(ErrorHandler)errorCallback {
    int unSyncedCount = [[BTHDAccountProvider instance] unSyncedCountOfPath:pathType];
    BTHDAccountAddress *address = [[BTHDAccountProvider instance] addressForPath:pathType index:index];
    index++;
    if (unSyncedCount == 0) {
        if (callback) {
            callback();
        }
    } else {
        [TransactionsUtil getTxForHDAccount:pathType index:index hdAddress:address callback:^(void) {
            int unSyncedCountInBlock = [[BTHDAccountProvider instance] unSyncedCountOfPath:pathType];
            if (unSyncedCountInBlock == 0) {
                if (callback) {
                    callback();
                }
            } else {
                [TransactionsUtil getMyTxForHDAccount:pathType index:index
                                             callback:callback andErrorCallBack:errorCallback];
            }

        }                  andErrorCallBack:errorCallback];
    }


}

+ (void)getTxForHDAccount:(PathType)pathType index:(int)index hdAddress:(BTHDAccountAddress *)address
                 callback:(VoidBlock)callback andErrorCallBack:(ErrorHandler)errorCallback {
    __block NSMutableArray *allTxs = [NSMutableArray new];
    __block int tmpBlockCount = 0;
    __block int tmpTxCnt = 0;
    __block int page = 1;
    if (address.isSyncedComplete) {
        if (callback) {
            callback();
        }
    }
    ErrorHandler errorHandler = ^(NSOperation *errorOp, NSError *error) {
        if (errorCallback) {
            errorCallback(errorOp, error);
        }
        NSLog(@"get my transcation api %@", errorOp);
    };

    DictResponseBlock nextPageBlock = ^(NSDictionary *dict) {
        int blockCount = [dict[@"block_count"] intValue];
        int txCnt = [dict[@"tx_cnt"] intValue];
        if (blockCount != tmpBlockCount && txCnt != tmpTxCnt) {
            // may be server data updated
        }
        NSArray *txs = [TransactionsUtil getTxs:dict];
        [allTxs addObjectsFromArray:txs];
        if ([allTxs count] < txCnt) {
            page += 1;
            [[BitherApi instance] getTransactionApi:address.address withPage:page callback:nextPageBlock andErrorCallBack:errorHandler];
        } else {
            [[BTAddressManager instance].hdAccount initTxs:[[BTAddressManager instance] compressTxsForApi:allTxs andAddress:address.address]];
            [address setIsSyncedComplete:YES];
            [[BTAddressManager instance].hdAccount updateSyncComplete:address];

            if (allTxs.count > 0) {
                [[BTAddressManager instance].hdAccount updateIssuedIndex:pathType index:index - 1];
                [[BTAddressManager instance].hdAccount supplyEnoughKeys:NO];
                [[NSNotificationCenter defaultCenter] postNotificationName:kHDAccountPaymentAddressChangedNotification object:[BTAddressManager instance].hdAccount.address userInfo:@{kHDAccountPaymentAddressChangedNotificationFirstAdding : @(NO)}];
            } else {
                [[BTHDAccountProvider instance] updateSyncdForIndex:pathType index:index - 1];
            }

            uint32_t storeHeight = [[BTBlockChain instance] lastBlock].blockNo;
            if (blockCount < storeHeight && storeHeight - blockCount < 100) {
                [[BTBlockChain instance] rollbackBlock:(uint32_t) blockCount];
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                [[NSNotificationCenter defaultCenter] postNotificationName:BitherAddressNotification object:address.address];
            });
            if (callback) {
                callback();
            }
        }
    };

    [[BitherApi instance] getTransactionApi:address.address withPage:page callback:nextPageBlock andErrorCallBack:errorHandler];

}


+ (void)getTxs:(BTAddress *)address callback:(VoidBlock)callback andErrorCallBack:(ErrorHandler)errorCallback {
    __block NSMutableArray *allTxs = [NSMutableArray new];
    __block int tmpBlockCount = 0;
    __block int tmpTxCnt = 0;
    __block int page = 1;

    ErrorHandler errorHandler = ^(NSOperation *errorOp, NSError *error) {
        if (errorCallback) {
            errorCallback(errorOp, error);
        }
        NSLog(@"get my transcation api %@", errorOp);
    };

    DictResponseBlock nextPageBlock = ^(NSDictionary *dict) {
        int blockCount = [dict[@"block_count"] intValue];
        int txCnt = [dict[@"tx_cnt"] intValue];
        if (blockCount != tmpBlockCount && txCnt != tmpTxCnt) {
            // may be server data updated
        }
        NSArray *txs = [TransactionsUtil getTxs:dict];
        [allTxs addObjectsFromArray:txs];
        if ([allTxs count] < txCnt) {
            page += 1;
            [[BitherApi instance] getTransactionApi:address.address withPage:page callback:nextPageBlock andErrorCallBack:errorHandler];
        } else {
            [address initTxs:[[BTAddressManager instance] compressTxsForApi:allTxs andAddress:address.address]];
            [address setIsSyncComplete:YES];
            [address updateSyncComplete];

            uint32_t storeHeight = [[BTBlockChain instance] lastBlock].blockNo;
            if (blockCount < storeHeight && storeHeight - blockCount < 100) {
                [[BTBlockChain instance] rollbackBlock:(uint32_t) blockCount];
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                [[NSNotificationCenter defaultCenter] postNotificationName:BitherAddressNotification object:address.address];
            });
            if (callback) {
                callback();
            }
        }
    };

    [[BitherApi instance] getTransactionApi:address.address withPage:page callback:^(NSDictionary *dict) {
        int blockCount = [dict[@"block_count"] intValue];
        int txCnt = [dict[@"tx_cnt"] intValue];
        tmpBlockCount = blockCount;
        tmpTxCnt = txCnt;
        NSArray *txs = [TransactionsUtil getTxs:dict];
        [allTxs addObjectsFromArray:txs];
        if ([allTxs count] < txCnt) {
            page += 1;
            [[BitherApi instance] getTransactionApi:address.address withPage:page callback:nextPageBlock andErrorCallBack:errorHandler];
        } else {
            [address initTxs:[[BTAddressManager instance] compressTxsForApi:allTxs andAddress:address.address]];
            [address setIsSyncComplete:YES];
            [address updateSyncComplete];

            uint32_t storeHeight = [[BTBlockChain instance] lastBlock].blockNo;
            if (blockCount < storeHeight && storeHeight - blockCount < 100) {
                [[BTBlockChain instance] rollbackBlock:(uint32_t) blockCount];
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                [[NSNotificationCenter defaultCenter] postNotificationName:BitherAddressNotification object:address.address];
            });
            if (callback) {
                callback();
            }
        }
    }                      andErrorCallBack:errorHandler];


//    [[BitherApi instance] getMyTransactionApi:address.address callback:^(NSDictionary * dict) {
//        int blockCount = [dict[@"block_count"] intValue];
//        int txCnt = [dict[@"tx_cnt"] intValue];
//
//        uint32_t storeHeight=[[BTBlockChain instance] lastBlock].blockNo;
//        NSArray *txs=[TransactionsUtil getTransactions:dict storeBlockHeight:storeHeight];
//        uint32_t apiBlockCount=[dict getIntFromDict:BLOCK_COUNT];
//        [address initTxs:txs];
//        [address setIsSyncComplete:YES];
//        [[BTAddressProvider instance] updateSyncComplete:address];
////        [address updateAddressWithPub];
//        //TODO 100?
//        if (apiBlockCount<storeHeight&&storeHeight-apiBlockCount<100) {
//            [[BTBlockChain instance] rollbackBlock:apiBlockCount];
//        }
//        dispatch_async(dispatch_get_main_queue(), ^{
//            [[NSNotificationCenter defaultCenter] postNotificationName:BitherAddressNotification object:address.address];
//        });
//        if (callback) {
//            callback();
//        }
//    } andErrorCallBack:^(MKNetworkOperation *errorOp, NSError *error) {
//        if (errorCallback) {
//            errorCallback(errorOp,error);
//        }
//        NSLog(@"get my transcation api %@",errorOp.responseString);
//    }];
}


+ (NSArray *)getTxs:(NSDictionary *)dict; {
    NSArray *array = [[BTBlockChain instance] getAllBlocks];
    NSMutableDictionary *dictionary = [NSMutableDictionary new];
    BTBlock *minBlock = [array objectAtIndex:array.count - 1];
    uint32_t minBlockNo = minBlock.blockNo;
    for (BTBlock *block in array) {
        if (block.blockNo < minBlockNo) {
            minBlockNo = block.blockNo;
        }
        [dictionary setObject:block forKey:[NSNumber numberWithInt:block.blockNo]];
    };
    NSMutableArray *txs = [NSMutableArray new];
    for (NSArray *each in dict[@"tx"]) {
        BTTx *tx = [[BTTx alloc] initWithMessage:[NSData dataFromBase64String:each[1]]];
        tx.blockNo = (uint32_t) [each[0] intValue];
        BTBlock *block;
        if (tx.blockNo < minBlockNo) {
            block = [dictionary objectForKey:[NSNumber numberWithInt:minBlockNo]];
        } else {
            block = [dictionary objectForKey:[NSNumber numberWithInt:tx.blockNo]];
        }

        [tx setTxTime:block.blockTime];
        [txs addObject:tx];
    }
    return txs;
}

+ (NSString *)getCompleteTxForError:(NSError *)error {
    NSString *msg = @"";
    switch (error.code) {
        case ERR_TX_DUST_OUT_CODE:
            msg = NSLocalizedString(@"Send failed. Sending coins this few will be igored.", nil);
            break;
        case ERR_TX_NOT_ENOUGH_MONEY_CODE:
            msg = [NSString stringWithFormat:NSLocalizedString(@"Send failed. Lack of %@ %@.", nil), [UnitUtil stringForAmount:[error.userInfo getLongLongFromDict:ERR_TX_NOT_ENOUGH_MONEY_LACK]], [UnitUtil unitName]];
            break;
        case ERR_TX_WAIT_CONFIRM_CODE:
            msg = [NSString stringWithFormat:NSLocalizedString(@"%@ %@ to be confirmed.", nil), [UnitUtil stringForAmount:[error.userInfo getLongLongFromDict:ERR_TX_WAIT_CONFIRM_AMOUNT]], [UnitUtil unitName]];
            break;
        case ERR_TX_CAN_NOT_CALCULATE_CODE:
            msg = NSLocalizedString(@"Send failed. You don\'t have enough coins available.", nil);
            break;
        case ERR_TX_MAX_SIZE_CODE:
            msg = NSLocalizedString(@"Send failed. Transaction size is to large.", nil);
            break;
        default:
            break;
    }
    return msg;
}

+ (void)completeInputsForAddressForApi:(BTAddress *)address fromBlock:(uint32_t)fromBlock callback:(VoidBlock)callback andErrorCallBack:(ErrorHandler)errorCallback {
    if (fromBlock <= 0) {
        if (callback) {
            callback();
        }
        return;
    }
    [[BitherApi instance] getInSignaturesApi:address.address fromBlock:fromBlock callback:^(id response) {
        NSArray *ins = [TransactionsUtil getInSignature:response];
        [address completeInSignature:ins];
        uint32_t newFromBlock = [address needCompleteInSignature];
        if (newFromBlock <= 0) {
            if (callback) {
                callback();
            }
        } else {
            [TransactionsUtil completeInputsForAddressForApi:address fromBlock:newFromBlock callback:callback andErrorCallBack:errorCallback];
        }

    }                       andErrorCallBack:^(NSOperation *errorOp, NSError *error) {
        if (errorCallback) {
            errorCallback(errorOp, error);
        }

    }];

}

+ (NSArray *)getInSignature:(NSString *)result {
    NSMutableArray *resultList = [NSMutableArray new];
    if (![StringUtil isEmpty:result]) {
        NSArray *txs = [result componentsSeparatedByString:@";"];
        for (NSString *tx in txs) {
            NSArray *ins = [tx componentsSeparatedByString:@":"];
            NSString *inStr = ins[0];
            NSData *txHash = [[StringUtil getUrlSaleBase64:inStr] reverse];
            for (int i = 1; i < ins.count; i++) {
                NSArray *array = [ins[i] componentsSeparatedByString:@","];
                int inSn = [array[0] intValue];
                NSData *inSignature = [StringUtil getUrlSaleBase64:array[1]];
                BTIn *btIn = [[BTIn alloc] init];
                [btIn setTxHash:txHash];
                btIn.inSn = inSn;
                [btIn setInSignature:inSignature];
                [resultList addObject:btIn];

            }
        }
    }
    return resultList;

}
@end
