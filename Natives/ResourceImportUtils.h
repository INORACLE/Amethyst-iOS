#import <Foundation/Foundation.h>

@interface ResourceImportUtils : NSObject
+ (void)checkAndPromptForBundledImport;
+ (void)importBundledDataWithCompletion:(void (^)(BOOL success, NSString *message))completion;
@end
