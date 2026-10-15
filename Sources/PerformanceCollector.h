#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSDictionary *PRBCollectSnapshot(
    NSDictionary *previousState,
    BOOL simulateDegraded
);

FOUNDATION_EXPORT NSDictionary *PRBRunIdlePolicySelfTest(void);

FOUNDATION_EXPORT NSDictionary *PRBRunEventParsingSelfTest(void);

NS_ASSUME_NONNULL_END
