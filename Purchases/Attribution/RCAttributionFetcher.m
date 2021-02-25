//
//  RCAttributionFetcher.m
//  Purchases
//
//  Created by RevenueCat.
//  Copyright © 2019 RevenueCat. All rights reserved.
//

#import "RCAttributionFetcher.h"
#import "RCCrossPlatformSupport.h"
#import "RCLogUtils.h"
#import "RCDeviceCache.h"
#import "RCIdentityManager.h"
#import "RCBackend.h"
#import "RCAttributionData.h"
@import PurchasesCoreSwift;

typedef NS_ENUM(NSUInteger, FakeATTrackingManagerAuthorizationStatus) {
    FakeATTrackingManagerAuthorizationStatusNotDetermined = 0,
    FakeATTrackingManagerAuthorizationStatusRestricted,
    FakeATTrackingManagerAuthorizationStatusDenied,
    FakeATTrackingManagerAuthorizationStatusAuthorized
};

static NSMutableArray<RCAttributionData *> *_Nullable postponedAttributionData;


@interface RCAttributionFetcher ()

@property (strong, nonatomic) RCDeviceCache *deviceCache;
@property (strong, nonatomic) RCIdentityManager *identityManager;
@property (strong, nonatomic) RCBackend *backend;
@property (strong, nonatomic) RCAttributionTypeFactory *attributionFactory;

@end

@implementation RCAttributionFetcher : NSObject

- (instancetype)initWithDeviceCache:(RCDeviceCache *)deviceCache
                    identityManager:(RCIdentityManager *)identityManager
                            backend:(RCBackend *)backend
                 attributionFactory:(RCAttributionTypeFactory *)attributionFactory {
    if (self = [super init]) {
        self.deviceCache = deviceCache;
        self.identityManager = identityManager;
        self.backend = backend;
        self.attributionFactory = attributionFactory;
    }
    return self;
}

- (nullable NSString *)identifierForAdvertisers {
    if (@available(iOS 6.0, macOS 10.14, *)) {
        Class <FakeASIdentifierManager> _Nullable asIdentifierManagerClass = [self.attributionFactory asIdentifierClass];
        if (asIdentifierManagerClass) {
            id sharedManager = [asIdentifierManagerClass sharedManager];
            NSUUID *identifierValue = [sharedManager valueForKey:[self.attributionFactory asIdentifierPropertyName]];
            return identifierValue.UUIDString;
        } else {
            RCWarnLog(@"%@", RCStrings.configure.adsupport_not_imported);
        }
    }
    return nil;
}

- (nullable NSString *)identifierForVendor {
#if UI_DEVICE_AVAILABLE
    if ([UIDevice class]) {
        return UIDevice.currentDevice.identifierForVendor.UUIDString;
    }
#endif
    return nil;
}

- (void)adClientAttributionDetailsWithCompletionBlock:(RCAttributionDetailsBlock)completionHandler {
#if AD_CLIENT_AVAILABLE
    Class<FakeAdClient> _Nullable adClientClass = [self.attributionFactory adClientClass];
    if (!adClientClass) {
        return; // iAd isn't included in the bundle
    }
    [[adClientClass sharedClient] requestAttributionDetailsWithBlock:completionHandler];
#endif
}

- (NSString *)latestNetworkIdAndAdvertisingIdentifierSentForNetwork:(RCAttributionNetwork)network {
    NSString *networkID = [NSString stringWithFormat:@"%ld", (long) network];
    NSDictionary *cachedDict =
        [self.deviceCache latestNetworkAndAdvertisingIdsSentForAppUserID:self.identityManager.currentAppUserID];
    return cachedDict[networkID];
}

- (void)postAttributionData:(NSDictionary *)data
                fromNetwork:(RCAttributionNetwork)network
           forNetworkUserId:(nullable NSString *)networkUserId {
    if (data[@"rc_appsflyer_id"]) {
        RCWarnLog(@"%@", RCStrings.attribution.appsflyer_id_deprecated);
    }
    if (network == RCAttributionNetworkAppsFlyer && networkUserId == nil) {
        RCWarnLog(@"%@", RCStrings.attribution.networkuserid_required_for_appsflyer);
    }
    NSString *appUserID = self.identityManager.currentAppUserID;
    NSString *networkKey = [NSString stringWithFormat:@"%ld", (long) network];
    NSString *identifierForAdvertisers = [self identifierForAdvertisers];
    NSDictionary *dictOfLatestNetworkIdsAndAdvertisingIdsSentToNetworks =
        [self.deviceCache latestNetworkAndAdvertisingIdsSentForAppUserID:appUserID];
    NSString *latestSentToNetwork = dictOfLatestNetworkIdsAndAdvertisingIdsSentToNetworks[networkKey];
    NSString *newValueForNetwork = [NSString stringWithFormat:@"%@_%@", identifierForAdvertisers, networkUserId];

    if ([latestSentToNetwork isEqualToString:newValueForNetwork]) {
        RCDebugLog(@"%@", RCStrings.attribution.skip_same_attributes);
    } else {
        NSMutableDictionary<NSString *, NSString *> *newDictToCache =
            [NSMutableDictionary dictionaryWithDictionary:dictOfLatestNetworkIdsAndAdvertisingIdsSentToNetworks];
        newDictToCache[networkKey] = newValueForNetwork;

        NSMutableDictionary *newData = [NSMutableDictionary dictionaryWithDictionary:data];
        newData[@"rc_idfa"] = identifierForAdvertisers;
        newData[@"rc_idfv"] = [self identifierForVendor];
        newData[@"rc_attribution_network_id"] = networkUserId;

        if (newData.count > 0) {
            [self.backend postAttributionData:newData
                                  fromNetwork:network
                                 forAppUserID:appUserID
                                   completion:^(NSError *_Nullable error) {
                                       if (error == nil) {
                                           [self.deviceCache setLatestNetworkAndAdvertisingIdsSent:newDictToCache
                                                                                      forAppUserID:appUserID];
                                       }
                                   }];
        }
    }
}
- (void)postAppleSearchAdsAttributionIfNeeded {
#if APP_TRACKING_TRANSPARENCY_REQUIRED
    if (@available(iOS 14, macos 11, tvos 14, *)) {
        NSOperatingSystemVersion minimumOSVersionRequiringAuthorization = { .majorVersion = 14, .minorVersion = 5, .patchVersion = 0 };

        BOOL needsTrackingAuthorization = ![NSProcessInfo.processInfo isOperatingSystemAtLeastVersion:minimumOSVersionRequiringAuthorization];

        Class<FakeATTrackingManager> _Nullable trackingManagerClass = [self.attributionFactory trackingManagerClass];
        if (!trackingManagerClass) {
            return; // AppTrackingTransparency isn't included in the bundle
        }
        NSInteger authorizationStatus = [trackingManagerClass trackingAuthorizationStatus];
        BOOL authorized = (needsTrackingAuthorization && authorizationStatus == FakeATTrackingManagerAuthorizationStatusAuthorized)
            || (!needsTrackingAuthorization && (authorizationStatus == FakeATTrackingManagerAuthorizationStatusAuthorized
                                                || authorizationStatus == FakeATTrackingManagerAuthorizationStatusNotDetermined));
        if (!authorized) {
            return;
        }
    }
#endif

    NSString *latestNetworkIdAndAdvertisingIdSentToAppleSearchAds = [self
        latestNetworkIdAndAdvertisingIdentifierSentForNetwork:RCAttributionNetworkAppleSearchAds];
    if (latestNetworkIdAndAdvertisingIdSentToAppleSearchAds != nil) {
        return;
    }

    [self adClientAttributionDetailsWithCompletionBlock:^(NSDictionary<NSString *, NSObject *> *_Nullable attributionDetails,
                                                          NSError *_Nullable error) {
        NSArray *values = [attributionDetails allValues];

        bool hasIadAttribution = values.count != 0 && [values[0][@"iad-attribution"] boolValue];
        if (hasIadAttribution) {
            [self postAttributionData:attributionDetails
                          fromNetwork:RCAttributionNetworkAppleSearchAds
                     forNetworkUserId:nil];
        }
    }];
}

- (void)postPostponedAttributionDataIfNeeded {
    if (postponedAttributionData) {
        for (RCAttributionData *attributionData in postponedAttributionData) {
            [self postAttributionData:attributionData.data
                          fromNetwork:attributionData.network
                     forNetworkUserId:attributionData.networkUserId];
        }
    }

    postponedAttributionData = nil;
}

static NSMutableArray<RCAttributionData *> *_Nullable postponedAttributionData;

+ (void)storePostponedAttributionData:(NSDictionary *)data
                          fromNetwork:(RCAttributionNetwork)network
                     forNetworkUserId:(nullable NSString *)networkUserId {
    if (postponedAttributionData == nil) {
        postponedAttributionData = [NSMutableArray array];
    }
    [postponedAttributionData addObject:[[RCAttributionData alloc] initWithData:data
                                                                    fromNetwork:network
                                                               forNetworkUserId:networkUserId]];
}

@end

