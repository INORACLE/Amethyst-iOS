#import "ResourceImportUtils.h"
#import "LauncherPreferences.h"
#import "PLProfiles.h"
#import "utils.h"
#import "UnzipKit.h"

#define fm NSFileManager.defaultManager

static BOOL importDialogShown = NO;
static BOOL importInProgress = NO;

static NSString *bundlePartPath(int index) {
    return [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:
        [NSString stringWithFormat:@"AmethystData.zip.%03d", index]];
}

static NSString *markerPath(void) {
    return [@(getenv("AME_HOME")) stringByAppendingPathComponent:@".zoo_imported"];
}

static BOOL bundledDataExists(void) {
    return [fm fileExistsAtPath:bundlePartPath(1)] && ![fm fileExistsAtPath:markerPath()];
}

static BOOL instanceAlreadyPopulated(void) {
    NSString *serverPath = [NSString stringWithFormat:@"%s/instances/default/servers.dat", getenv("AME_HOME")];
    return [fm fileExistsAtPath:serverPath];
}

static void deleteOldInstance(NSString *reason) {
    NSString *instPath = [NSString stringWithFormat:@"%s/instances/default", getenv("AME_HOME")];
    NSLog(@"[ZooImport] Deleting old instance (%@): %@", reason, instPath);
    [fm removeItemAtPath:instPath error:nil];
}

static void deleteBundledData(void) {
    [fm createFileAtPath:markerPath() contents:[NSData data] attributes:nil];
    NSLog(@"[ZooImport] Marker written, bundled parts remain in bundle (read-only)");
}

static void writePreferencesAndAccount(void) {
    NSString *home = @(getenv("AME_HOME"));
    NSString *plistPath = [home stringByAppendingPathComponent:@"launcher_preferences_v2.plist"];
    NSMutableDictionary *pref = [NSMutableDictionary dictionaryWithContentsOfFile:plistPath];
    if (!pref) pref = [NSMutableDictionary new];
    NSMutableDictionary *general = pref[@"general"];
    if (!general) general = [NSMutableDictionary new];
    general[@"game_directory"] = @"default";
    pref[@"general"] = general;
    NSMutableDictionary *internal = pref[@"internal"];
    if (!internal) internal = [NSMutableDictionary new];
    internal[@"selected_account"] = @"Player";
    pref[@"internal"] = internal;
    [pref writeToFile:plistPath atomically:YES];
    NSString *accountsDir = [home stringByAppendingPathComponent:@"accounts"];
    [fm createDirectoryAtPath:accountsDir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *accountPath = [accountsDir stringByAppendingPathComponent:@"Player.json"];
    if (![fm fileExistsAtPath:accountPath]) {
        NSDictionary *acct = @{ @"username": @"Player", @"profileId": @"00000000-0000-0000-0000-000000000000" };
        NSData *json = [NSJSONSerialization dataWithJSONObject:acct options:NSJSONWritingPrettyPrinted error:nil];
        [json writeToFile:accountPath atomically:YES];
    }
    NSLog(@"[ZooImport] Preferences and account written");
}

@implementation ResourceImportUtils

+ (void)checkAndPromptForBundledImport {
    if (importDialogShown || importInProgress) return;
    if (!bundledDataExists()) return;
    if (instanceAlreadyPopulated()) {
        deleteBundledData();
        return;
    }
    importDialogShown = YES;
    UIViewController *vc = currentVC();
    if (!vc) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"动物园：群星启程"
        message:@"检测到内置整合包数据（MC 1.21.1 + 34 模组 + 服务器）。立即导入到启动器吗？导入完成后即可直接进入游戏。"
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"立即导入" style:UIAlertActionStyleDefault handler:^(UIAlertAction *_) {
        [ResourceImportUtils importBundledDataWithCompletion:nil];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"稍后在菜单导入" style:UIAlertActionStyleCancel handler:nil]];
    [vc presentViewController:alert animated:YES completion:nil];
}

+ (void)importBundledDataWithCompletion:(void (^)(BOOL, NSString *))completion {
    if (importInProgress) return;
    importInProgress = YES;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSError *error = nil;
        // 1. Join numbered parts from the app bundle into one zip in tmp
        NSMutableArray<NSString *> *parts = [NSMutableArray new];
        for (int i = 1; i <= 99; i++) {
            NSString *p = bundlePartPath(i);
            if (![fm fileExistsAtPath:p]) break;
            [parts addObject:p];
        }
        if (parts.count < 2) {
            if (completion) completion(NO, @"未找到内置数据包分片");
            importInProgress = NO;
            return;
        }
        NSString *tmpZip = [NSTemporaryDirectory() stringByAppendingPathComponent:@"AmethystData-join.zip"];
        [fm removeItemAtPath:tmpZip error:nil];
        NSOutputStream *out = [[NSOutputStream alloc] initToFileAtPath:tmpZip append:NO];
        [out open];
        BOOL joinOK = YES;
        for (NSString *p in parts) {
            NSInputStream *in = [[NSInputStream alloc] initWithFileAtPath:p];
            [in open];
            uint8_t buf[1 << 20];
            while ([in hasBytesAvailable]) {
                NSInteger n = [in read:buf maxLength:sizeof(buf)];
                if (n <= 0) break;
                if ([out write:&buf[0] maxLength:n] < 0) { joinOK = NO; break; }
            }
            [in close];
            if (!joinOK) break;
        }
        [out close];
        if (!joinOK || ![fm fileExistsAtPath:tmpZip]) {
            if (completion) completion(NO, @"数据包拼接失败");
            importInProgress = NO;
            return;
        }
        NSLog(@"[ZooImport] Joined %lu parts -> %@", (unsigned long)parts.count, tmpZip);
        // 2. Extract into AME_HOME
        deleteOldInstance(@"pre-import cleanup");
        UZKArchive *archive = [[UZKArchive alloc] initWithPath:tmpZip error:&error];
        if (!archive) {
            if (completion) completion(NO, error.localizedDescription ?: @"无法打开数据包");
            importInProgress = NO;
            return;
        }
        NSString *home = @(getenv("AME_HOME"));
        BOOL ok = [archive extractFilesTo:home overwrite:YES error:&error];
        archive = nil;
        [fm removeItemAtPath:tmpZip error:nil];
        if (!ok) {
            NSLog(@"[ZooImport] Extract failed: %@", error);
            if (completion) completion(NO, error.localizedDescription ?: @"解压失败");
            importInProgress = NO;
            return;
        }
        // 3. Flatten possible nesting: AmethystData/ at extraction root
        NSString *nested = [home stringByAppendingPathComponent:@"AmethystData"];
        if ([fm fileExistsAtPath:nested]) {
            for (NSString *item in [fm contentsOfDirectoryAtPath:nested error:nil]) {
                NSString *from = [nested stringByAppendingPathComponent:item];
                NSString *to = [home stringByAppendingPathComponent:item];
                if ([fm fileExistsAtPath:to]) [fm removeItemAtPath:to error:nil];
                [fm moveItemAtPath:from toPath:to error:nil];
            }
            [fm removeItemAtPath:nested error:nil];
        }
        // 4. Verify
        NSString *servers = [NSString stringWithFormat:@"%s/instances/default/servers.dat", getenv("AME_HOME")];
        NSString *profiles = [NSString stringWithFormat:@"%s/instances/default/launcher_profiles.json", getenv("AME_HOME")];
        BOOL verified = [fm fileExistsAtPath:servers] && [fm fileExistsAtPath:profiles];
        if (verified) {
            writePreferencesAndAccount();
            deleteBundledData();
            [PLProfiles updateCurrent];
            [[NSNotificationCenter defaultCenter] postNotificationName:@"ZooDataImported" object:nil];
            NSLog(@"[ZooImport] SUCCESS");
            if (completion) completion(YES, @"整合包已就绪：34 个模组 + 服务器列表 + 配置全部就位");
        } else {
            NSLog(@"[ZooImport] Verification failed: servers=%d profiles=%d", [fm fileExistsAtPath:servers], [fm fileExistsAtPath:profiles]);
            if (completion) completion(NO, @"导入后校验失败（servers.dat / launcher_profiles.json 缺失）");
        }
        importInProgress = NO;
    });
}

@end
