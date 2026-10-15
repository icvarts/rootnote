#import "PerformanceCollector.h"

typedef NS_ENUM(NSInteger, PRBSeverity) {
    PRBSeverityNormal = 0,
    PRBSeverityNotice = 1,
    PRBSeverityWarning = 2,
    PRBSeverityHigh = 3,
    PRBSeverityCritical = 4,
};

static const uint64_t PRBMB = 1000000ULL;
static const uint64_t PRBGB = 1000000000ULL;

static NSDictionary *PRBRun(NSString *executable, NSArray<NSString *> *arguments) {
    NSTask *task = [[NSTask alloc] init];
    NSPipe *pipe = [NSPipe pipe];
    task.executableURL = [NSURL fileURLWithPath:executable];
    task.arguments = arguments;
    task.standardOutput = pipe;
    task.standardError = pipe;
    NSError *error = nil;
    if (![task launchAndReturnError:&error]) {
        return @{@"output": error.localizedDescription ?: @"", @"status": @(-1)};
    }
    NSData *data = [pipe.fileHandleForReading readDataToEndOfFile];
    [task waitUntilExit];
    NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
    return @{@"output": output, @"status": @(task.terminationStatus)};
}

static NSArray<NSString *> *PRBCaptures(NSString *pattern, NSString *text) {
    NSRegularExpression *regex =
        [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:nil];
    NSTextCheckingResult *match =
        [regex firstMatchInString:text options:0 range:NSMakeRange(0, text.length)];
    if (!match) return nil;
    NSMutableArray<NSString *> *values = [NSMutableArray array];
    for (NSInteger index = 1; index < match.numberOfRanges; index++) {
        NSRange range = [match rangeAtIndex:index];
        if (range.location != NSNotFound) [values addObject:[text substringWithRange:range]];
    }
    return values;
}

static BOOL PRBScaledCapture(NSString *pattern, NSString *text, uint64_t *valueOut) {
    NSArray<NSString *> *values = PRBCaptures(pattern, text);
    if (values.count < 2) return NO;
    double value = values[0].doubleValue;
    NSString *unit = values[1].uppercaseString;
    double scale = 1;
    if ([unit isEqualToString:@"K"]) scale = 1e3;
    else if ([unit isEqualToString:@"M"]) scale = 1e6;
    else if ([unit isEqualToString:@"G"]) scale = 1e9;
    else if ([unit isEqualToString:@"T"]) scale = 1e12;
    else if ([unit isEqualToString:@"P"]) scale = 1e15;
    if (valueOut) *valueOut = (uint64_t)MAX(value * scale, 0);
    return YES;
}

static NSString *PRBThreadIDFromPath(NSString *path) {
    return PRBCaptures(
        @"([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})",
        path
    ).firstObject;
}

static NSString *PRBSeverityID(PRBSeverity severity) {
    switch (severity) {
        case PRBSeverityNotice: return @"notice";
        case PRBSeverityWarning: return @"warning";
        case PRBSeverityHigh: return @"high";
        case PRBSeverityCritical: return @"critical";
        default: return @"normal";
    }
}

static NSString *PRBSeverityLabel(PRBSeverity severity) {
    switch (severity) {
        case PRBSeverityNotice: return @"注意";
        case PRBSeverityWarning: return @"预警";
        case PRBSeverityHigh: return @"高风险";
        case PRBSeverityCritical: return @"严重";
        default: return @"正常";
    }
}

static PRBSeverity PRBSessionSeverity(uint64_t size) {
    if (size >= PRBGB) return PRBSeverityCritical;
    if (size >= 500 * PRBMB) return PRBSeverityHigh;
    if (size >= 250 * PRBMB) return PRBSeverityWarning;
    if (size >= 100 * PRBMB) return PRBSeverityNotice;
    return PRBSeverityNormal;
}

static PRBSeverity PRBSessionGrowthSeverity(double growth) {
    if (growth >= 400 * PRBMB) return PRBSeverityHigh;
    if (growth >= 200 * PRBMB) return PRBSeverityWarning;
    return PRBSeverityNormal;
}

static double PRBSessionGrowth(uint64_t size, id previousSize, NSTimeInterval elapsed) {
    // A newly discovered session has no growth baseline; normal samples are 15 seconds apart.
    if (![previousSize isKindOfClass:NSNumber.class] ||
        [previousSize doubleValue] < 0 || !(elapsed >= 1)) return 0;
    uint64_t previous = [previousSize unsignedLongLongValue];
    return size > previous ? (double)(size - previous) * 3600.0 / elapsed : 0;
}

static NSString *PRBSessionRiskSource(uint64_t size, double growth) {
    NSMutableArray<NSString *> *signals = [NSMutableArray array];
    if (size >= PRBGB) [signals addObject:@"体积 ≥ 1 GB"];
    else if (size >= 500 * PRBMB) [signals addObject:@"体积 ≥ 500 MB"];
    else if (size >= 250 * PRBMB) [signals addObject:@"体积 ≥ 250 MB"];
    else if (size >= 100 * PRBMB) [signals addObject:@"体积 ≥ 100 MB"];
    if (growth >= 400 * PRBMB) [signals addObject:@"增长 ≥ 400 MB/h"];
    else if (growth >= 200 * PRBMB) [signals addObject:@"增长 ≥ 200 MB/h"];
    return signals.count > 0
        ? [signals componentsJoinedByString:@" · "]
        : @"低于会话阈值";
}

static NSString *PRBFriendlyTitle(NSString *raw, NSString *threadID) {
    NSString *trimmed =
        [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (trimmed.length == 0) {
        NSUInteger start = threadID.length > 8 ? threadID.length - 8 : 0;
        return [NSString stringWithFormat:@"会话 %@", [threadID substringFromIndex:start]];
    }
    NSString *named = PRBCaptures(@"《([^》]{1,60})》", trimmed).firstObject;
    if (named.length > 0) return named;
    if (trimmed.length > 28) return [[trimmed substringToIndex:28] stringByAppendingString:@"…"];
    return trimmed;
}

static NSDictionary<NSString *, NSString *> *PRBTitlesForIDs(NSArray<NSString *> *threadIDs) {
    if (threadIDs.count == 0) return @{};
    NSString *database = [NSHomeDirectory() stringByAppendingPathComponent:@".codex/state_5.sqlite"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:database]) return @{};

    NSCharacterSet *unsafe =
        [[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef-"] invertedSet];
    NSMutableArray<NSString *> *safeIDs = [NSMutableArray array];
    for (NSString *threadID in threadIDs) {
        if ([threadID rangeOfCharacterFromSet:unsafe].location == NSNotFound) {
            [safeIDs addObject:[NSString stringWithFormat:@"'%@'", threadID]];
        }
    }
    if (safeIDs.count == 0) return @{};

    NSString *sql = [NSString stringWithFormat:
        @"SELECT id, replace(replace(COALESCE(NULLIF(name,''), title), char(10), ' '), "
         "char(13), ' ') FROM threads WHERE id IN (%@);",
        [safeIDs componentsJoinedByString:@","]
    ];
    NSString *separator = [NSString stringWithFormat:@"%C", (unichar)0x001F];
    NSDictionary *result =
        PRBRun(@"/usr/bin/sqlite3", @[@"-readonly", @"-separator", separator, database, sql]);
    if ([result[@"status"] intValue] != 0) return @{};

    NSMutableDictionary *titles = [NSMutableDictionary dictionary];
    for (NSString *line in
         [result[@"output"] componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        NSArray<NSString *> *parts = [line componentsSeparatedByString:separator];
        if (parts.count >= 2) titles[parts[0]] = parts[1];
    }
    return titles;
}

static NSArray<NSString *> *PRBOpenSessionPaths(NSMutableArray<NSString *> *issues) {
    NSDictionary *processList = PRBRun(@"/bin/ps", @[@"-axo", @"pid=,command="]);
    if ([processList[@"status"] intValue] != 0) {
        [issues addObject:@"codex_process_list_unavailable"];
        return nil;
    }

    NSMutableArray<NSString *> *pids = [NSMutableArray array];
    for (NSString *line in
         [processList[@"output"] componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        if (![line containsString:@"/Contents/Resources/codex"] ||
            ![line containsString:@" app-server"]) continue;
        NSString *trimmed =
            [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        NSString *pid =
            [trimmed componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet]
                .firstObject;
        if (pid.length > 0) [pids addObject:pid];
    }

    NSMutableSet<NSString *> *paths = [NSMutableSet set];
    for (NSString *pid in pids) {
        NSDictionary *lsof = PRBRun(@"/usr/sbin/lsof", @[@"-nP", @"-a", @"-p", pid, @"-Fn"]);
        if ([lsof[@"status"] intValue] != 0) {
            [issues addObject:@"open_session_metadata_unavailable"];
            continue;
        }
        for (NSString *line in
             [lsof[@"output"] componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
            if (![line hasPrefix:@"n/"]) continue;
            NSString *path = [line substringFromIndex:1];
            if ([path containsString:@"/.codex/sessions/"] && [path hasSuffix:@".jsonl"]) {
                [paths addObject:path];
            }
        }
    }
    return [paths.allObjects sortedArrayUsingSelector:@selector(compare:)];
}

static NSString *PRBString(id value) {
    return [value isKindOfClass:NSString.class] ? value : nil;
}

static NSDictionary *PRBActiveTaskState(NSString *path) {
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!handle) return @{@"active": @NO, @"reliable": @NO};

    unsigned long long fileSize = [handle seekToEndOfFile];
    unsigned long long readSize = MIN(fileSize, 256 * 1024);
    [handle seekToFileOffset:fileSize - readSize];
    NSData *data = [handle readDataToEndOfFile];
    [handle closeFile];
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!text) return @{@"active": @NO, @"reliable": @NO};

    if (fileSize > readSize) {
        NSRange newline = [text rangeOfString:@"\n"];
        if (newline.location != NSNotFound) {
            text = [text substringFromIndex:NSMaxRange(newline)];
        }
    }

    BOOL active = NO;
    BOOL sawRelevant = NO;
    NSString *status = @"unknown";
    NSString *eventAt = @"";
    for (NSString *line in
         [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        if (line.length == 0) continue;
        NSData *lineData = [line dataUsingEncoding:NSUTF8StringEncoding];
        NSDictionary *object =
            [NSJSONSerialization JSONObjectWithData:lineData options:0 error:nil];
        if (![object isKindOfClass:NSDictionary.class]) continue;
        NSString *outerType = PRBString(object[@"type"]);
        NSDictionary *payload =
            [object[@"payload"] isKindOfClass:NSDictionary.class] ? object[@"payload"] : @{};
        NSString *type = PRBString(payload[@"type"]);
        NSString *phase = PRBString(payload[@"phase"]);
        NSString *role = PRBString(payload[@"role"]);
        BOOL relevant = NO;

        if ([outerType isEqualToString:@"event_msg"]) {
            if ([type isEqualToString:@"user_message"] || [type isEqualToString:@"task_started"] ||
                [type isEqualToString:@"agent_reasoning"] || [type isEqualToString:@"web_search_end"] ||
                [type isEqualToString:@"patch_apply_end"] ||
                [type isEqualToString:@"image_generation_end"]) {
                active = YES;
                sawRelevant = YES;
                relevant = YES;
            } else if ([type isEqualToString:@"task_complete"]) {
                active = NO;
                sawRelevant = YES;
                relevant = YES;
            } else if ([type isEqualToString:@"agent_message"] &&
                       [phase isEqualToString:@"final_answer"]) {
                active = NO;
                sawRelevant = YES;
                relevant = YES;
            }
        } else if ([outerType isEqualToString:@"response_item"]) {
            if ([type isEqualToString:@"custom_tool_call"] ||
                [type isEqualToString:@"function_call"] ||
                [type isEqualToString:@"custom_tool_call_output"] ||
                [type isEqualToString:@"function_call_output"]) {
                active = YES;
                sawRelevant = YES;
                relevant = YES;
            } else if ([type isEqualToString:@"message"]) {
                if ([role isEqualToString:@"user"]) {
                    active = YES;
                    sawRelevant = YES;
                    relevant = YES;
                } else if ([role isEqualToString:@"assistant"] &&
                           [phase isEqualToString:@"final_answer"]) {
                    active = NO;
                    sawRelevant = YES;
                    relevant = YES;
                }
            }
        }
        if (relevant) {
            status = active ? @"running" : @"completed";
            eventAt = PRBString(object[@"timestamp"]) ?: @"";
        }
        if ([outerType isEqualToString:@"event_msg"] &&
            ([type isEqualToString:@"turn_aborted"] || [type isEqualToString:@"task_failed"])) {
            active = NO;
            sawRelevant = YES;
            status = [type isEqualToString:@"turn_aborted"] ? @"stopped" : @"failed";
            eventAt = PRBString(object[@"timestamp"]) ?: @"";
        }
    }
    return @{@"active": @(active), @"reliable": @(sawRelevant), @"status": status, @"eventAt": eventAt};
}

NSDictionary *PRBRunEventParsingSelfTest(void) {
    NSString *fixturePath = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"rootnote-event-parser-%@.jsonl", NSUUID.UUID.UUIDString]];
    NSArray<NSString *> *lines = @[
        @"{\"type\":null,\"payload\":null}",
        @"{\"type\":\"event_msg\",\"payload\":{\"type\":null,\"phase\":null}}",
        @"{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":null,\"phase\":null}}",
        @"{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"phase\":null}}",
        @"{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"assistant\",\"phase\":\"final_answer\"}}",
    ];
    NSString *fixtureBody =
        [[lines componentsJoinedByString:@"\n"] stringByAppendingString:@"\n"];
    NSError *writeError = nil;
    BOOL wrote = [[fixtureBody dataUsingEncoding:NSUTF8StringEncoding]
        writeToFile:fixturePath
        options:NSDataWritingAtomic
        error:&writeError];
    NSDictionary *state = wrote
        ? PRBActiveTaskState(fixturePath)
        : @{@"active": @NO, @"reliable": @NO};
    [[NSFileManager defaultManager] removeItemAtPath:fixturePath error:nil];

    BOOL ok = wrote &&
        [state[@"reliable"] boolValue] &&
        ![state[@"active"] boolValue];
    return @{
        @"ok": @(ok),
        @"nullFieldsHandled": @YES,
        @"state": state,
        @"writeError": writeError.localizedDescription ?: NSNull.null,
    };
}

static NSString *PRBHeadline(PRBSeverity severity, NSString *collectorHealth) {
    if ([collectorHealth isEqualToString:@"unavailable"]) return @"暂时无法确认系统压力";
    if ([collectorHealth isEqualToString:@"degraded"]) return @"部分性能数据待确认";
    switch (severity) {
        case PRBSeverityNotice: return @"压力开始抬头";
        case PRBSeverityWarning: return @"性能压力需要留意";
        case PRBSeverityHigh: return @"性能压力接近上限";
        case PRBSeverityCritical: return @"性能压力需要立即关注";
        default: return @"系统呼吸平稳";
    }
}

static NSString *PRBRecommendation(
    PRBSeverity severity,
    uint64_t swapUsed,
    NSDictionary *largestSession
) {
    NSString *title = largestSession[@"title"];
    switch (severity) {
        case PRBSeverityNotice:
            return @"开始留意会话增长，确保关键任务已有续接记录。";
        case PRBSeverityWarning:
            return @"当前阶段尽快收口，不再开启复杂分支，并准备新窗口承接。";
        case PRBSeverityHigh:
            return title.length > 0
                ? [NSString stringWithFormat:@"建议尽快为《%@》建立承接窗口，交接后归档旧窗口。",
                                           title]
                : @"建议尽快建立承接窗口，交接后归档旧窗口。";
        case PRBSeverityCritical:
            if (swapUsed >= 10 * PRBGB) {
                return @"立即停止扩展长任务，完成交接和归档；保存其他工作后重启 Codex 与 Mac。";
            }
            return title.length > 0
                ? [NSString stringWithFormat:
                    @"立即停止扩展《%@》，完成交接、归档旧窗口并重启 Codex。", title]
                : @"立即停止扩展长任务，完成交接、归档旧窗口并重启 Codex。";
        default:
            return @"状态正常，可以继续使用。";
    }
}

static NSDictionary *PRBResolvePresentation(
    PRBSeverity rawSeverity,
    NSString *collectorHealth,
    BOOL sessionsOK,
    NSUInteger sessionCount,
    BOOL activeTaskCountReliable,
    NSUInteger activeTaskCount,
    uint64_t swapUsed,
    NSDictionary *largestSession
) {
    // The pet jewel answers "is Codex work at risk?", not "has this Mac ever
    // swapped memory?". System metrics remain visible as evidence, but a
    // healthy and reliably observed empty Codex workload is explicitly idle.
    BOOL codexIdle =
        [collectorHealth isEqualToString:@"healthy"] &&
        sessionsOK &&
        sessionCount == 0 &&
        activeTaskCountReliable &&
        activeTaskCount == 0;
    PRBSeverity effectiveSeverity = codexIdle ? PRBSeverityNormal : rawSeverity;
    NSString *microState;
    if (codexIdle) {
        microState = @"green";
    } else if ([collectorHealth isEqualToString:@"unavailable"] ||
               effectiveSeverity >= PRBSeverityHigh) {
        microState = @"red";
    } else if (![collectorHealth isEqualToString:@"healthy"] ||
               effectiveSeverity >= PRBSeverityNotice) {
        microState = @"yellow";
    } else {
        microState = @"green";
    }

    NSString *displaySeverityID = PRBSeverityID(effectiveSeverity);
    NSString *displaySeverityLabel = PRBSeverityLabel(effectiveSeverity);
    NSString *headline = PRBHeadline(effectiveSeverity, collectorHealth);
    NSString *recommendation =
        PRBRecommendation(effectiveSeverity, swapUsed, largestSession);
    if (codexIdle) {
        headline = @"当前没有运行任务";
        recommendation = @"暂时没有 Codex 工作负载，无需性能处置；系统指标仅作背景参考。";
    } else if ([collectorHealth isEqualToString:@"unavailable"]) {
        displaySeverityID = @"unknown";
        displaySeverityLabel = @"采集异常";
        recommendation =
            @"性能证据暂不可用，不能视为正常；请稍后刷新。若持续红色，先保存当前工作并重启 Codex。";
    } else if ([collectorHealth isEqualToString:@"degraded"] &&
               effectiveSeverity == PRBSeverityNormal) {
        displaySeverityID = @"notice";
        displaySeverityLabel = @"需留意";
        recommendation =
            @"部分性能指标暂不可用，保留黄色提示；稍后刷新即可，无需立即处置。";
    }

    return @{
        @"codexIdle": @(codexIdle),
        @"effectiveSeverity": @(effectiveSeverity),
        @"severityID": displaySeverityID,
        @"severityLabel": displaySeverityLabel,
        @"microState": microState,
        @"headline": headline,
        @"recommendation": recommendation,
    };
}

NSDictionary *PRBRunIdlePolicySelfTest(void) {
    NSDictionary *idle = PRBResolvePresentation(
        PRBSeverityNotice, @"healthy", YES, 0, YES, 0, 4 * PRBGB, @{}
    );
    NSDictionary *active = PRBResolvePresentation(
        PRBSeverityNotice, @"healthy", YES, 1, YES, 1, 4 * PRBGB, @{}
    );
    NSDictionary *degraded = PRBResolvePresentation(
        PRBSeverityNormal, @"degraded", YES, 0, YES, 0, 0, @{}
    );
    NSDictionary *unavailable = PRBResolvePresentation(
        PRBSeverityNormal, @"unavailable", NO, 0, NO, 0, 0, @{}
    );
    NSDictionary *growthChecks = @{
        @"new_session_has_no_baseline": @(PRBSessionGrowth(100 * PRBMB, nil, 60) == 0),
        @"null_baseline_ignored": @(PRBSessionGrowth(100 * PRBMB, NSNull.null, 60) == 0),
        @"regular_15_second_sample": @(PRBSessionGrowth(101 * PRBMB, @(100 * PRBMB), 15) == 240 * PRBMB),
        @"zero_is_valid_baseline": @(PRBSessionGrowth(PRBMB, @0, 15) == 240 * PRBMB),
        @"shrinking_file_no_growth": @(PRBSessionGrowth(PRBMB, @(2 * PRBMB), 15) == 0),
        @"rapid_refresh_not_extrapolated": @(PRBSessionGrowth(PRBMB, @0, 0.1) == 0),
        @"backward_clock_not_extrapolated": @(PRBSessionGrowth(PRBMB, @0, -15) == 0),
    };
    BOOL ok =
        [idle[@"codexIdle"] boolValue] &&
        [idle[@"microState"] isEqualToString:@"green"] &&
        [idle[@"effectiveSeverity"] integerValue] == PRBSeverityNormal &&
        ![active[@"codexIdle"] boolValue] &&
        [active[@"microState"] isEqualToString:@"yellow"] &&
        [degraded[@"microState"] isEqualToString:@"yellow"] &&
        [degraded[@"headline"] isEqualToString:@"部分性能数据待确认"] &&
        [unavailable[@"microState"] isEqualToString:@"red"];
    for (NSNumber *passed in growthChecks.allValues) ok = ok && passed.boolValue;
    return @{
        @"ok": @(ok),
        @"idle": idle,
        @"active": active,
        @"degraded": degraded,
        @"unavailable": unavailable,
        @"growthChecks": growthChecks,
    };
}

NSDictionary *PRBCollectSnapshot(NSDictionary *previousState, BOOL simulateDegraded) {
    NSMutableArray<NSString *> *issues = [NSMutableArray array];
    uint64_t totalMemory = NSProcessInfo.processInfo.physicalMemory;

    NSDictionary *top = PRBRun(@"/usr/bin/top", @[@"-l", @"1", @"-n", @"0"]);
    uint64_t memoryUsed = 0;
    uint64_t compressed = 0;
    BOOL memoryOK =
        [top[@"status"] intValue] == 0 &&
        PRBScaledCapture(@"PhysMem:\\s*([0-9.]+)([KMGTP])\\s+used", top[@"output"], &memoryUsed);
    BOOL compressedOK =
        [top[@"status"] intValue] == 0 &&
        PRBScaledCapture(@"([0-9.]+)([KMGTP])\\s+compressor", top[@"output"], &compressed);
    if (!memoryOK || !compressedOK) [issues addObject:@"memory_metrics_unavailable"];

    uint64_t swapUsed = 0;
    BOOL swapOK = NO;
    if (!simulateDegraded) {
        NSDictionary *swap = PRBRun(@"/usr/sbin/sysctl", @[@"-n", @"vm.swapusage"]);
        swapOK =
            [swap[@"status"] intValue] == 0 &&
            PRBScaledCapture(@"used\\s*=\\s*([0-9.]+)([KMGTP])", swap[@"output"], &swapUsed);
    }
    if (!swapOK) [issues addObject:@"swap_metric_unavailable"];

    NSDictionary *pressure = PRBRun(@"/usr/bin/memory_pressure", @[@"-Q"]);
    NSString *freeText =
        PRBCaptures(@"System-wide memory free percentage:\\s*([0-9.]+)%",
                    pressure[@"output"]).firstObject;
    BOOL pressureOK = [pressure[@"status"] intValue] == 0 && freeText.length > 0;
    if (!pressureOK) [issues addObject:@"memory_pressure_unavailable"];

    NSArray<NSString *> *paths = simulateDegraded ? nil : PRBOpenSessionPaths(issues);
    if (simulateDegraded) [issues addObject:@"session_metadata_simulated_missing"];
    BOOL sessionsOK = paths != nil;

    NSMutableArray<NSString *> *threadIDs = [NSMutableArray array];
    for (NSString *path in paths ?: @[]) {
        NSString *threadID = PRBThreadIDFromPath(path);
        if (threadID) [threadIDs addObject:threadID];
    }
    NSDictionary *titles = PRBTitlesForIDs(threadIDs);
    NSDictionary *previousSizes =
        [previousState[@"last_sizes"] isKindOfClass:NSDictionary.class]
            ? previousState[@"last_sizes"]
            : @{};
    NSTimeInterval lastSampleAt = [previousState[@"last_sample_at"] doubleValue];
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    NSTimeInterval elapsed = lastSampleAt > 0 ? now - lastSampleAt : 0;

    NSMutableArray<NSDictionary *> *sessions = [NSMutableArray array];
    NSMutableDictionary *nextSizes = [NSMutableDictionary dictionary];
    NSUInteger activeTaskCount = 0;
    BOOL activeTaskCountReliable = sessionsOK;
    BOOL sawAmbiguousTaskState = NO;
    uint64_t totalOpenBytes = 0;
    uint64_t largestOpenBytes = 0;

    for (NSString *path in paths ?: @[]) {
        NSString *threadID = PRBThreadIDFromPath(path);
        if (!threadID) continue;
        NSDictionary *attributes =
            [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
        if (!attributes) {
            [issues addObject:@"session_size_metadata_unavailable"];
            continue;
        }
        uint64_t size = [attributes[NSFileSize] unsignedLongLongValue];
        double growth = PRBSessionGrowth(size, previousSizes[threadID], elapsed);
        PRBSeverity sessionSeverity = MAX(
            PRBSessionSeverity(size),
            PRBSessionGrowthSeverity(growth)
        );
        NSDictionary *taskState = PRBActiveTaskState(path);
        if ([taskState[@"active"] boolValue]) activeTaskCount += 1;
        if (![taskState[@"reliable"] boolValue]) sawAmbiguousTaskState = YES;

        NSDictionary *session = @{
            @"threadID": threadID,
            @"title": PRBFriendlyTitle(titles[threadID], threadID),
            @"sizeBytes": @(size),
            @"growthBytesPerHour": @(growth),
            @"severity": @(sessionSeverity),
            @"severityID": PRBSeverityID(sessionSeverity),
            @"severityLabel": PRBSeverityLabel(sessionSeverity),
            @"riskSource": PRBSessionRiskSource(size, growth),
            @"active": taskState[@"active"],
            @"taskStatus": taskState[@"status"] ?: @"unknown",
            @"eventAt": taskState[@"eventAt"] ?: @"",
        };
        [sessions addObject:session];
        nextSizes[threadID] = @(size);
        totalOpenBytes += size;
        largestOpenBytes = MAX(largestOpenBytes, size);
    }
    // A positive running event is usable even when another open session has no recent
    // lifecycle marker. Keep zero fail-closed when every candidate is ambiguous.
    activeTaskCountReliable =
        sessionsOK && (activeTaskCount > 0 || !sawAmbiguousTaskState);
    [sessions sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        uint64_t left = [a[@"sizeBytes"] unsignedLongLongValue];
        uint64_t right = [b[@"sizeBytes"] unsignedLongLongValue];
        if (left > right) return NSOrderedAscending;
        if (left < right) return NSOrderedDescending;
        return NSOrderedSame;
    }];

    PRBSeverity severity = PRBSeverityNormal;
    for (NSDictionary *session in sessions) {
        severity = MAX(severity, [session[@"severity"] integerValue]);
        double growth = [session[@"growthBytesPerHour"] doubleValue];
        if (growth >= 400 * PRBMB) severity = MAX(severity, PRBSeverityHigh);
        else if (growth >= 200 * PRBMB) severity = MAX(severity, PRBSeverityWarning);
    }
    if (totalOpenBytes >= 1500 * PRBMB) severity = MAX(severity, PRBSeverityHigh);
    else if (totalOpenBytes >= 1000 * PRBMB) severity = MAX(severity, PRBSeverityWarning);
    else if (totalOpenBytes >= 500 * PRBMB) severity = MAX(severity, PRBSeverityNotice);
    if (swapOK) {
        if (swapUsed >= 10 * PRBGB) severity = MAX(severity, PRBSeverityCritical);
        else if (swapUsed >= 6 * PRBGB) severity = MAX(severity, PRBSeverityWarning);
        else if (swapUsed >= 2 * PRBGB) severity = MAX(severity, PRBSeverityNotice);
    }
    if (compressedOK) {
        if (compressed >= 7 * PRBGB) severity = MAX(severity, PRBSeverityHigh);
        else if (compressed >= 5 * PRBGB) severity = MAX(severity, PRBSeverityWarning);
    }

    NSString *collectorHealth;
    if (!memoryOK && !swapOK && !sessionsOK) collectorHealth = @"unavailable";
    else if (issues.count == 0) collectorHealth = @"healthy";
    else collectorHealth = @"degraded";

    NSDictionary *largestSession = sessions.firstObject ?: @{};
    NSDictionary *presentation = PRBResolvePresentation(
        severity,
        collectorHealth,
        sessionsOK,
        sessions.count,
        activeTaskCountReliable,
        activeTaskCount,
        swapUsed,
        largestSession
    );
    PRBSeverity effectiveSeverity = [presentation[@"effectiveSeverity"] integerValue];

    NSMutableArray<NSDictionary *> *history =
        [previousState[@"history"] isKindOfClass:NSArray.class]
            ? [previousState[@"history"] mutableCopy]
            : [NSMutableArray array];
    [history addObject:@{
        @"timestamp": @(now),
        @"sessions": @(totalOpenBytes),
        @"swap": @(swapUsed),
        @"severity": @(effectiveSeverity),
    }];
    NSTimeInterval cutoff = now - 24 * 3600;
    NSIndexSet *expired =
        [history indexesOfObjectsPassingTest:^BOOL(NSDictionary *point, NSUInteger index, BOOL *stop) {
            return [point[@"timestamp"] doubleValue] < cutoff;
        }];
    [history removeObjectsAtIndexes:expired];
    if (history.count > 96) [history removeObjectsInRange:NSMakeRange(0, history.count - 96)];

    NSDictionary *nextState = @{
        @"last_sizes": nextSizes,
        @"last_sample_at": @(now),
        @"last_severity": @(effectiveSeverity),
        @"history": history,
    };

    return @{
        @"id": NSUUID.UUID.UUIDString,
        @"timestamp": @(now),
        @"observedAt": [[[NSISO8601DateFormatter alloc] init] stringFromDate:NSDate.date],
        @"severity": @(effectiveSeverity),
        @"rawSeverity": @(severity),
        @"severityID": presentation[@"severityID"],
        @"severityLabel": presentation[@"severityLabel"],
        @"microState": presentation[@"microState"],
        @"collectorHealth": collectorHealth,
        @"codexIdle": presentation[@"codexIdle"],
        @"headline": presentation[@"headline"],
        @"recommendation": presentation[@"recommendation"],
        @"metrics": @{
            @"memoryUsedBytes": memoryOK ? @(memoryUsed) : NSNull.null,
            @"memoryTotalBytes": @(totalMemory),
            @"compressedBytes": compressedOK ? @(compressed) : NSNull.null,
            @"swapUsedBytes": swapOK ? @(swapUsed) : NSNull.null,
            @"memoryFreePercent": pressureOK ? @(freeText.doubleValue) : NSNull.null,
            @"activeSessionCount": sessionsOK ? @(sessions.count) : NSNull.null,
            @"totalOpenBytes": sessionsOK ? @(totalOpenBytes) : NSNull.null,
            @"largestOpenBytes": sessionsOK ? @(largestOpenBytes) : NSNull.null,
        },
        @"sessions": sessions,
        @"history": history,
        @"activeTaskCount": @(activeTaskCount),
        @"activeTaskCountReliable": @(activeTaskCountReliable),
        @"issues": [[[NSOrderedSet alloc] initWithArray:issues] array],
        @"nextState": nextState,
        @"bodyPersisted": @NO,
        @"autoAction": @NO,
        @"sessionEventMetadataRead": @YES,
        @"sessionBodyPersisted": @NO,
    };
}
