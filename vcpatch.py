#!/usr/bin/env python3
"""
EZCompleteUI Memory Recall / Context Turns patcher.

What this patches:
  1. Creates timestamped backups of helpers.m and ViewController.m before
     modifying either source file.
  2. Adds a persistent Memory Recall toggle to ViewController's input area.
  3. Adds a compact 0...15 UIStepper in the upper-right of the text-entry
     container. Its value controls how many prior user turns are included in
     the request context.
  4. When Memory Recall is OFF, chat requests bypass:
       - fetchRelevantMemories:
       - analyzePromptForContext:
       - helper-model routing
       - injected memory context
     and go directly to the selected intended chat model.
  5. Removes previously injected memory wrappers from retained historical
     messages while Memory Recall is disabled, so old memory context is not
     accidentally sent again.

Run from the directory containing helpers.m and ViewController.m:

    python3 patch_ezcompleteui_memory_recall.py

The patcher is fail-safe:
  - Validates every source anchor before writing.
  - Creates backups before modifying source.
  - Writes atomically.
  - Refuses to apply twice.
"""

from __future__ import annotations

import datetime
import os
import shutil
import sys
import tempfile
from pathlib import Path


ROOT = Path.cwd()
HELPERS_FILE = ROOT / "helpers.m"


def find_view_controller() -> Path:
    candidates = [
        ROOT / "ViewController.m",
        ROOT / "ViewController 15.m",
    ]
    for candidate in candidates:
        if candidate.is_file():
            return candidate

    raise FileNotFoundError(
        "Could not find ViewController.m or ViewController 15.m in the current directory."
    )


def fail(message: str) -> None:
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)


def replace_once(source: str, old: str, new: str, label: str) -> str:
    count = source.count(old)
    if count != 1:
        fail(
            f'Cannot safely patch "{label}". '
            f"Expected exactly one matching source anchor, found {count}."
        )
    return source.replace(old, new, 1)


def insert_after_once(source: str, anchor: str, addition: str, label: str) -> str:
    count = source.count(anchor)
    if count != 1:
        fail(
            f'Cannot safely patch "{label}". '
            f"Expected exactly one matching source anchor, found {count}."
        )
    return source.replace(anchor, anchor + addition, 1)


def atomic_write(path: Path, content: str) -> None:
    try:
        fd, temp_name = tempfile.mkstemp(
            prefix=f".{path.name}.",
            suffix=".tmp",
            dir=str(path.parent),
        )
        with os.fdopen(fd, "w", encoding="utf-8", newline="") as handle:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())

        shutil.copymode(path, temp_name)
        os.replace(temp_name, path)
    except Exception as exc:
        try:
            if "temp_name" in locals() and os.path.exists(temp_name):
                os.unlink(temp_name)
        except OSError:
            pass
        fail(f"Failed to atomically write {path.name}: {exc}")


def backup(path: Path, timestamp: str) -> Path:
    backup_path = path.with_name(f"{path.name}.backup-{timestamp}")
    try:
        shutil.copy2(path, backup_path)
    except Exception as exc:
        fail(f"Could not back up {path.name}: {exc}")
    return backup_path


def main() -> None:
    if not HELPERS_FILE.is_file():
        fail(f"Missing required file: {HELPERS_FILE.name}")

    try:
        view_controller_file = find_view_controller()
    except FileNotFoundError as exc:
        fail(str(exc))

    try:
        original_helpers = HELPERS_FILE.read_text(encoding="utf-8")
        original_view = view_controller_file.read_text(encoding="utf-8")
    except UnicodeDecodeError as exc:
        fail(f"Source file is not valid UTF-8: {exc}")
    except OSError as exc:
        fail(f"Could not read source file: {exc}")

    if "ez_memoryRecallEnabled" in original_view:
        fail(
            "ViewController already contains the Memory Recall patch marker "
            "(ez_memoryRecallEnabled). No files were changed."
        )

    patched = original_view

    # -------------------------------------------------------------------------
    # Add UI properties.
    # -------------------------------------------------------------------------
    patched = replace_once(
        patched,
        """@property (nonatomic, strong) UIButton      *brainRotButton;
//@property (nonatomic, strong) UIButton      *textToSpeechButton;""",
        """@property (nonatomic, strong) UIButton      *brainRotButton;

/// Persistent Memory Recall toggle. Green = enabled; gray = direct mode.
@property (nonatomic, strong) UIButton      *memoryRecallButton;

/// Compact numeric label paired with contextTurnsStepper.
@property (nonatomic, strong) UILabel       *contextTurnsLabel;

/// Selects 0...15 previous user turns retained in outgoing chat context.
@property (nonatomic, strong) UIStepper     *contextTurnsStepper;

//@property (nonatomic, strong) UIButton      *textToSpeechButton;""",
        "Memory Recall UI properties",
    )

    # -------------------------------------------------------------------------
    # Add private method declarations.
    # -------------------------------------------------------------------------
    patched = replace_once(
        patched,
        """- (void)callImageEdit:(NSString *)prompt imagePath:(NSString *)imagePath;

@end""",
        """- (void)callImageEdit:(NSString *)prompt imagePath:(NSString *)imagePath;

// Memory Recall / explicit context-turn controls.
- (BOOL)ez_memoryRecallEnabled;
- (NSInteger)ez_selectedContextTurnCount;
- (void)refreshMemoryRecallControls;
- (void)toggleMemoryRecall;
- (void)contextTurnsChanged:(UIStepper *)sender;
- (NSArray<NSDictionary *> *)contextLimitedToRecentTurns:(NSInteger)priorTurns;
- (NSArray<NSDictionary *> *)contextByRemovingInjectedMemoryFromContext:(NSArray<NSDictionary *> *)context;

@end""",
        "Memory Recall private declarations",
    )

    # -------------------------------------------------------------------------
    # Add persistent defaults. Memory Recall defaults to ON to retain current
    # behavior for existing users; context defaults to five prior turns.
    # -------------------------------------------------------------------------
    patched = replace_once(
        patched,
        """    // Set a sensible default system message if the user hasn't configured one yet.
    // This avoids the model claiming it "can't" do things it absolutely can.
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if (![defaults stringForKey:@"systemMessage"].length) {""",
        """    // Persistent Memory Recall / Context Turns defaults.
    // Recall remains enabled by default so existing installations preserve
    // their previous behavior until the user explicitly turns it off.
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if ([defaults objectForKey:@"memoryRecallEnabled"] == nil) {
        [defaults setBool:YES forKey:@"memoryRecallEnabled"];
    }

    NSInteger configuredContextTurns = [defaults integerForKey:@"contextTurnCount"];
    if (configuredContextTurns < 0 || configuredContextTurns > 15) {
        [defaults setInteger:5 forKey:@"contextTurnCount"];
    }

    // Set a sensible default system message if the user hasn't configured one yet.
    // This avoids the model claiming it "can't" do things it absolutely can.
    if (![defaults stringForKey:@"systemMessage"].length) {""",
        "Memory Recall persistent defaults",
    )

    # -------------------------------------------------------------------------
    # Build the compact input-container controls.
    # -------------------------------------------------------------------------
    patched = insert_after_once(
        patched,
        """    [self.inputContainer addSubview:self.imageSettingsButton];
""",
        """
    // Memory Recall button. It is intentionally small and uses tint to make
    // direct mode obvious without consuming message-entry space.
    self.memoryRecallButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.memoryRecallButton setImage:[UIImage systemImageNamed:@"brain.head.profile"]
                             forState:UIControlStateNormal];
    [self.memoryRecallButton addTarget:self
                                action:@selector(toggleMemoryRecall)
                      forControlEvents:UIControlEventTouchUpInside];
    self.memoryRecallButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.memoryRecallButton.accessibilityLabel = @"Memory Recall";
    [self.inputContainer addSubview:self.memoryRecallButton];

    // Context-turn count label plus stepper. The displayed number is the
    // count of PRIOR user turns retained; zero means only this request.
    self.contextTurnsLabel = [[UILabel alloc] init];
    self.contextTurnsLabel.font =
        [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightSemibold];
    self.contextTurnsLabel.textAlignment = NSTextAlignmentRight;
    self.contextTurnsLabel.textColor = [UIColor secondaryLabelColor];
    self.contextTurnsLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.inputContainer addSubview:self.contextTurnsLabel];

    self.contextTurnsStepper = [[UIStepper alloc] init];
    self.contextTurnsStepper.minimumValue = 0;
    self.contextTurnsStepper.maximumValue = 15;
    self.contextTurnsStepper.stepValue = 1;
    self.contextTurnsStepper.value = [self ez_selectedContextTurnCount];
    self.contextTurnsStepper.translatesAutoresizingMaskIntoConstraints = NO;
    self.contextTurnsStepper.accessibilityLabel = @"Previous context turns";
    [self.contextTurnsStepper addTarget:self
                                  action:@selector(contextTurnsChanged:)
                        forControlEvents:UIControlEventValueChanged];
    [self.inputContainer addSubview:self.contextTurnsStepper];

    [self refreshMemoryRecallControls];
""",
        "Memory Recall controls",
    )

    # -------------------------------------------------------------------------
    # Add constraints in the upper-right of the input container.
    # -------------------------------------------------------------------------
    patched = replace_once(
        patched,
        """        [self.imageSettingsButton.heightAnchor constraintEqualToConstant:32],
        [self.attachButton.leadingAnchor constraintEqualToAnchor:self.inputContainer.leadingAnchor constant:12],""",
        """        [self.imageSettingsButton.heightAnchor constraintEqualToConstant:32],

        // Upper-right Memory Recall / Context Turns controls.
        [self.contextTurnsStepper.trailingAnchor constraintEqualToAnchor:self.inputContainer.trailingAnchor constant:-12],
        [self.contextTurnsStepper.centerYAnchor constraintEqualToAnchor:self.modelButton.centerYAnchor],
        [self.contextTurnsLabel.trailingAnchor constraintEqualToAnchor:self.contextTurnsStepper.leadingAnchor constant:-4],
        [self.contextTurnsLabel.centerYAnchor constraintEqualToAnchor:self.contextTurnsStepper.centerYAnchor],
        [self.contextTurnsLabel.widthAnchor constraintEqualToConstant:24],
        [self.memoryRecallButton.trailingAnchor constraintEqualToAnchor:self.contextTurnsLabel.leadingAnchor constant:-6],
        [self.memoryRecallButton.centerYAnchor constraintEqualToAnchor:self.contextTurnsStepper.centerYAnchor],
        [self.memoryRecallButton.widthAnchor constraintEqualToConstant:28],
        [self.memoryRecallButton.heightAnchor constraintEqualToConstant:28],
        [self.imageSettingsButton.trailingAnchor constraintLessThanOrEqualToAnchor:self.memoryRecallButton.leadingAnchor constant:-6],

        [self.attachButton.leadingAnchor constraintEqualToAnchor:self.inputContainer.leadingAnchor constant:12],""",
        "Memory Recall layout constraints",
    )

    # -------------------------------------------------------------------------
    # Add implementation methods before Image Generation Settings.
    # -------------------------------------------------------------------------
    memory_methods = r'''
// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Memory Recall / Context Turns
// ─────────────────────────────────────────────────────────────────────────────

/// Memory Recall is opt-out. It defaults to YES for existing installs, but
/// when disabled the chat send path bypasses helper routing and memory recall.
- (BOOL)ez_memoryRecallEnabled {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if ([defaults objectForKey:@"memoryRecallEnabled"] == nil) return YES;
    return [defaults boolForKey:@"memoryRecallEnabled"];
}

/// Returns a safe persisted prior-turn count in the supported 0...15 range.
- (NSInteger)ez_selectedContextTurnCount {
    NSInteger count = [[NSUserDefaults standardUserDefaults] integerForKey:@"contextTurnCount"];
    return MAX(0, MIN(15, count));
}

/// Synchronizes the input controls with persisted settings and accessibility.
- (void)refreshMemoryRecallControls {
    BOOL recallEnabled = [self ez_memoryRecallEnabled];
    NSInteger turns = [self ez_selectedContextTurnCount];

    self.contextTurnsStepper.value = turns;
    self.contextTurnsLabel.text = [NSString stringWithFormat:@"%ld", (long)turns];
    self.contextTurnsLabel.accessibilityLabel =
        [NSString stringWithFormat:@"%ld previous context turns", (long)turns];

    [self.memoryRecallButton setTintColor:
        recallEnabled ? [UIColor systemGreenColor] : [UIColor systemGrayColor]];
    self.memoryRecallButton.accessibilityValue = recallEnabled ? @"On" : @"Off";
    self.memoryRecallButton.accessibilityHint = recallEnabled
        ? @"Tap to disable memory recall and routing"
        : @"Tap to enable memory recall and routing";
}

/// Persists the Memory Recall choice. Existing saved threads and memories are
/// not changed or deleted; this controls only future outgoing requests.
- (void)toggleMemoryRecall {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    BOOL enabled = ![self ez_memoryRecallEnabled];
    [defaults setBool:enabled forKey:@"memoryRecallEnabled"];
    [self refreshMemoryRecallControls];

    [self appendToChat:[NSString stringWithFormat:@"[System: Memory Recall %@]",
                        enabled ? @"ON" : @"OFF"]];
    EZLogf(EZLogLevelInfo, @"MEMORY", @"Memory Recall %@", enabled ? @"enabled" : @"disabled");
}

/// Persists the number of prior user turns retained in the outgoing context.
- (void)contextTurnsChanged:(UIStepper *)sender {
    NSInteger count = (NSInteger)sender.value;
    count = MAX(0, MIN(15, count));

    [[NSUserDefaults standardUserDefaults] setInteger:count forKey:@"contextTurnCount"];
    [self refreshMemoryRecallControls];
    EZLogf(EZLogLevelInfo, @"CONTEXT", @"Prior context turn count set to %ld", (long)count);
}

/// Returns a suffix of chatContext containing:
///   - the current user request,
///   - the requested number of prior USER-anchored turns,
///   - all assistant replies between retained user turns,
///   - an immediately preceding pending vision attachment, when applicable.
///
/// "Turn" means a prior user request and all following assistant context until
/// the next user request. This keeps the setting understandable and prevents
/// orphaned assistant replies without the user question that prompted them.
- (NSArray<NSDictionary *> *)contextLimitedToRecentTurns:(NSInteger)priorTurns {
    priorTurns = MAX(0, MIN(15, priorTurns));
    if (self.chatContext.count == 0) return @[];

    NSInteger currentUserIndex = NSNotFound;

    // Locate the real outgoing user prompt. Ignore UI timeline events and
    // pending vision attachment records, which are not standalone text turns.
    for (NSInteger index = (NSInteger)self.chatContext.count - 1; index >= 0; index--) {
        NSDictionary *message = self.chatContext[(NSUInteger)index];
        if (![message isKindOfClass:[NSDictionary class]]) continue;
        if ([message[@"_uiOnly"] boolValue]) continue;
        if ([message[@"_isVisionAttachment"] boolValue]) continue;

        if ([message[@"role"] isEqualToString:@"user"]) {
            currentUserIndex = index;
            break;
        }
    }

    // Preserve prior behavior on malformed context rather than accidentally
    // sending no user request at all.
    if (currentUserIndex == NSNotFound) {
        EZLog(EZLogLevelWarning, @"CONTEXT",
              @"Could not find current user turn; preserving full context");
        return [self.chatContext copy];
    }

    NSInteger startIndex = currentUserIndex;
    NSInteger foundPriorUserTurns = 0;

    // Find the selected number of earlier user turns. The suffix beginning at
    // that user message naturally includes its related assistant response(s).
    for (NSInteger index = currentUserIndex - 1;
         index >= 0 && foundPriorUserTurns < priorTurns;
         index--) {
        NSDictionary *message = self.chatContext[(NSUInteger)index];
        if (![message isKindOfClass:[NSDictionary class]]) continue;
        if ([message[@"_uiOnly"] boolValue]) continue;
        if ([message[@"_isVisionAttachment"] boolValue]) continue;

        if ([message[@"role"] isEqualToString:@"user"]) {
            startIndex = index;
            foundPriorUserTurns++;
        }
    }

    // A newly attached image is stored immediately before the current text
    // prompt. Include it even at zero turns so vision analysis remains valid.
    while (startIndex > 0) {
        NSDictionary *previous = self.chatContext[(NSUInteger)(startIndex - 1)];
        if (![previous isKindOfClass:[NSDictionary class]] ||
            ![previous[@"_isVisionAttachment"] boolValue]) {
            break;
        }
        startIndex--;
    }

    NSRange range = NSMakeRange(
        (NSUInteger)startIndex,
        self.chatContext.count - (NSUInteger)startIndex
    );
    NSArray<NSDictionary *> *limited = [self.chatContext subarrayWithRange:range];

    EZLogf(EZLogLevelInfo, @"CONTEXT",
           @"Using current turn plus %ld prior turn(s): %lu context records",
           (long)priorTurns, (unsigned long)limited.count);

    return [limited copy];
}

/// Removes historical memory wrapper text when Memory Recall is disabled.
/// Without this cleanup, a previously routed request could carry old injected
/// memory into a new direct-mode request simply because it remains in the
/// locally saved thread history.
- (NSArray<NSDictionary *> *)contextByRemovingInjectedMemoryFromContext:(NSArray<NSDictionary *> *)context {
    NSMutableArray<NSDictionary *> *result =
        [NSMutableArray arrayWithCapacity:context.count];

    for (NSDictionary *message in context) {
        if (![message isKindOfClass:[NSDictionary class]]) continue;

        id content = message[@"content"];
        if (![content isKindOfClass:[NSString class]]) {
            [result addObject:message];
            continue;
        }

        NSString *text = (NSString *)content;
        NSString *stripped = text;

        if ([text hasPrefix:@"[Relevant memory context:]"] ||
            [text hasPrefix:@"[Memories with possible relevance:]"]) {
            NSRange marker = [text rangeOfString:@"[User message]\n"];
            if (marker.location != NSNotFound) {
                stripped = [text substringFromIndex:
                    marker.location + marker.length];
            }
        }

        if (![stripped isEqualToString:text]) {
            NSMutableDictionary *cleanMessage = [message mutableCopy];
            cleanMessage[@"content"] = stripped;
            [result addObject:[cleanMessage copy]];
        } else {
            [result addObject:message];
        }
    }

    return [result copy];
}

'''

    patched = replace_once(
        patched,
        """// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Image Generation Settings
// ─────────────────────────────────────────────────────────────────────────────
""",
        memory_methods + """// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Image Generation Settings
// ─────────────────────────────────────────────────────────────────────────────
""",
        "Memory Recall implementation methods",
    )

    # -------------------------------------------------------------------------
    # Memory Recall OFF: chat requests bypass memory fetching, helper routing,
    # and analyzePromptForContext entirely.
    # -------------------------------------------------------------------------
    patched = replace_once(
        patched,
        """    // ── Chat / reasoning models ───────────────────────────────────────────────
    [self fetchRelevantMemories:text completion:^(NSString *memories) {""",
        """    // ── Chat / reasoning models ───────────────────────────────────────────────
    // Direct mode deliberately bypasses all memory fetches, helper-model
    // triage/routing, and contextual prompt injection. callChatCompletions
    // still applies the explicit Context Turns stepper to conversation history.
    if (![self ez_memoryRecallEnabled]) {
        EZLogf(EZLogLevelInfo, @"MEMORY",
               @"Memory Recall OFF — sending directly to %@", self.selectedModel);
        [self callChatCompletions];
        return;
    }

    [self fetchRelevantMemories:text completion:^(NSString *memories) {""",
        "direct chat dispatch when Memory Recall is off",
    )

    # -------------------------------------------------------------------------
    # Memory Recall OFF also skips previous-image prompt enrichment.
    # -------------------------------------------------------------------------
    patched = replace_once(
        patched,
        """                if (self.lastImagePrompt.length > 0) {
                    [self fetchRelevantMemories:text""",
        """                if ([self ez_memoryRecallEnabled] && self.lastImagePrompt.length > 0) {
                    [self fetchRelevantMemories:text""",
        "direct image generation when Memory Recall is off",
    )

    # -------------------------------------------------------------------------
    # Apply explicit turn-limited request context in callChatCompletions.
    # -------------------------------------------------------------------------
    patched = replace_once(
        patched,
        """    NSString *sys = [defaults stringForKey:@"systemMessage"];
    NSArray *cleanContext = [self sanitizedContextForAPI:self.chatContext
                                     modelSupportsVision:[self modelSupportsVision:self.selectedModel]
                                         useResponsesAPI:useResponsesAPI];""",
        """    NSString *sys = [defaults stringForKey:@"systemMessage"];

    // Always honor the explicit 0...15 context-turn control. In direct mode,
    // strip prior injected-memory wrappers before sanitizing for the API.
    NSArray<NSDictionary *> *requestContext =
        [self contextLimitedToRecentTurns:[self ez_selectedContextTurnCount]];

    if (![self ez_memoryRecallEnabled]) {
        requestContext = [self contextByRemovingInjectedMemoryFromContext:requestContext];
        EZLog(EZLogLevelInfo, @"MEMORY",
              @"Memory Recall OFF — no recall/routing context sent");
    }

    NSArray *cleanContext = [self sanitizedContextForAPI:requestContext
                                     modelSupportsVision:[self modelSupportsVision:self.selectedModel]
                                         useResponsesAPI:useResponsesAPI];""",
        "turn-limited API request context",
    )

    # -------------------------------------------------------------------------
    # Validate helpers remains readable. It is intentionally not changed by
    # this feature because all memory routing is bypassed at ViewController's
    # dispatch point. A backup is still created as explicitly requested.
    # -------------------------------------------------------------------------
    if not original_helpers.strip():
        fail("helpers.m is empty; refusing to proceed.")

    timestamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")

    helpers_backup = backup(HELPERS_FILE, timestamp)
    view_backup = backup(view_controller_file, timestamp)

    atomic_write(view_controller_file, patched)

    print("PATCH SUCCESS")
    print(f"Backed up: {helpers_backup.name}")
    print(f"Backed up: {view_backup.name}")
    print(f"Patched:   {view_controller_file.name}")
    print("helpers.m was backed up and intentionally left unchanged.")
    print("Memory Recall defaults to ON. Context Turns defaults to 5.")


if __name__ == "__main__":
    main()89-7=8