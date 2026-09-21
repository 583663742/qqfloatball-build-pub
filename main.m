//  ShellPlayer — 空壳视频播放器
//  一个极简的本地/网络视频播放器，无任何附加功能。
//
//  compile: clang -arch arm64 -fobjc-arc -framework UIKit -framework AVKit -framework AVFoundation

#import <UIKit/UIKit.h>
#import <AVKit/AVKit.h>
#import <AVFoundation/AVFoundation.h>
#if __has_include(<UniformTypeIdentifiers/UniformTypeIdentifiers.h>)
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#define SP_HAS_UTTYPE 1
#endif

static NSArray<NSString *> *SPVideoExtensions(void) {
    static NSArray *exts = nil;
    if (!exts) {
        exts = @[@"mp4", @"mov", @"m4v", @"mkv", @"avi", @"flv", @"ts", @"webm",
                 @"3gp", @"mpg", @"mpeg", @"wmv", @"rmvb", @"mp3", @"m4a",
                 @"aac", @"flac", @"wav", @"ogg"];
    }
    return exts;
}

static NSString *SPHumanSize(unsigned long long bytes) {
    if (bytes > 1024ULL * 1024ULL * 1024ULL)
        return [NSString stringWithFormat:@"%.2f GB", bytes / 1073741824.0];
    if (bytes > 1024ULL * 1024ULL)
        return [NSString stringWithFormat:@"%.1f MB", bytes / 1048576.0];
    if (bytes > 1024ULL)
        return [NSString stringWithFormat:@"%.0f KB", bytes / 1024.0];
    return [NSString stringWithFormat:@"%llu B", bytes];
}

#pragma mark - 播放器

@interface SPPlayerViewController : UIViewController <AVPlayerViewControllerDelegate>
@property (nonatomic, strong) AVPlayerViewController *playerVC;
@property (nonatomic, copy) NSString *mediaTitle;
- (instancetype)initWithURL:(NSURL *)url title:(NSString *)title;
@end

@implementation SPPlayerViewController

- (instancetype)initWithURL:(NSURL *)url title:(NSString *)title {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _mediaTitle = [title copy] ?: @"播放";
        _playerVC = [[AVPlayerViewController alloc] init];
        AVPlayer *player = [AVPlayer playerWithURL:url];
        _playerVC.player = player;
        _playerVC.delegate = self;
        _playerVC.allowsPictureInPicturePlayback = YES;
        _playerVC.showsPlaybackControls = YES;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];
    self.title = self.mediaTitle;

    AVPlayerViewController *pvc = self.playerVC;
    [self addChildViewController:pvc];
    pvc.view.frame = self.view.bounds;
    pvc.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:pvc.view];
    [pvc didMoveToParentViewController:self];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    NSError *err = nil;
    [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback
                                     withOptions:0
                                           error:&err];
    [[AVAudioSession sharedInstance] setActive:YES error:&err];
    [self.playerVC.player play];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self.playerVC.player pause];
}

@end

#pragma mark - 主界面

@interface SPBrowserViewController : UIViewController <UITableViewDataSource, UITableViewDelegate,
                                                      UIDocumentPickerDelegate, UITextFieldDelegate>
@property (nonatomic, strong) UITextField *urlField;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UILabel *emptyLabel;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *items;
@end

@implementation SPBrowserViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"空壳播放器";
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                                                      target:self
                                                      action:@selector(importFile)];

    // ── 顶部：网络地址输入区
    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 62)];
    header.backgroundColor = [UIColor secondarySystemBackgroundColor];

    self.urlField = [[UITextField alloc] initWithFrame:CGRectMake(12, 13, header.bounds.size.width - 24, 36)];
    self.urlField.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    self.urlField.borderStyle = UITextBorderStyleRoundedRect;
    self.urlField.keyboardType = UIKeyboardTypeURL;
    self.urlField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.urlField.autocorrectionType = UITextAutocorrectionTypeNo;
    self.urlField.returnKeyType = UIReturnKeyGo;
    self.urlField.delegate = self;
    self.urlField.placeholder = @"粘贴视频直链，回车播放";
    self.urlField.font = [UIFont systemFontOfSize:14];
    [header addSubview:self.urlField];

    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.rowHeight = 62;
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    [self.view addSubview:self.tableView];

    // 用 header 作为 tableHeaderView，随列表滚动
    self.tableView.tableHeaderView = header;

    self.emptyLabel = [[UILabel alloc] initWithFrame:CGRectMake(24, 140, self.view.bounds.size.width - 48, 100)];
    self.emptyLabel.numberOfLines = 0;
    self.emptyLabel.textAlignment = NSTextAlignmentCenter;
    self.emptyLabel.textColor = [UIColor secondaryLabelColor];
    self.emptyLabel.font = [UIFont systemFontOfSize:14];
    self.emptyLabel.text = @"还没有本地视频\n\n点右上角 ＋ 导入，或用「文件」App 把视频拖进本应用的文件夹";
    [self.view addSubview:self.emptyLabel];

    [self scanDocuments];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    UIEdgeInsets insets = self.view.safeAreaInsets;
    self.emptyLabel.frame = CGRectMake(24, insets.top + 190,
                                       self.view.bounds.size.width - 48, 100);
}

#pragma mark 文件扫描

- (NSURL *)documentsURL {
    return [[[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory
                                                   inDomains:NSUserDomainMask] firstObject];
}

- (void)scanDocuments {
    self.items = [NSMutableArray array];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSURL *docs = [self documentsURL];
    NSArray<NSURL *> *contents =
        [fm contentsOfDirectoryAtURL:docs
          includingPropertiesForKeys:@[NSURLFileSizeKey, NSURLContentModificationDateKey]
                             options:NSDirectoryEnumerationSkipsHiddenFiles
                               error:NULL];

    NSArray<NSString *> *exts = SPVideoExtensions();
    for (NSURL *u in contents) {
        NSString *ext = [[u pathExtension] lowercaseString];
        if (ext.length && [exts containsObject:ext]) {
            NSNumber *size = nil;
            [u getResourceValue:&size forKey:NSURLFileSizeKey error:NULL];
            NSDate *mtime = nil;
            [u getResourceValue:&mtime forKey:NSURLContentModificationDateKey error:NULL];
            [self.items addObject:@{@"url": u,
                                    @"name": [u lastPathComponent],
                                    @"size": size ?: @0,
                                    @"date": mtime ?: [NSDate date]}];
        }
    }

    [self.items sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSDate *da = (NSDate *)a[@"date"];
        NSDate *db = (NSDate *)b[@"date"];
        return (NSComparisonResult)[db compare:da];
    }];

    self.emptyLabel.hidden = (self.items.count > 0);
    [self.tableView reloadData];
}

#pragma mark 播放

- (void)playURL:(NSURL *)url title:(NSString *)title {
    if (!url) return;
    [self.view endEditing:YES];
    SPPlayerViewController *vc = [[SPPlayerViewController alloc] initWithURL:url title:title];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.modalPresentationStyle = UIModalPresentationFullScreen;
    [self presentViewController:nav animated:YES completion:nil];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    NSString *s = [textField.text stringByTrimmingCharactersInSet:
                   [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (s.length == 0) return YES;
    if (![s hasPrefix:@"http://"] && ![s hasPrefix:@"https://"] && ![s hasPrefix:@"rtsp://"]) {
        s = [@"http://" stringByAppendingString:s];
    }
    NSURL *url = [NSURL URLWithString:s];
    if (!url) return YES;
    textField.text = s;
    [self playURL:url title:[url lastPathComponent]];
    return YES;
}

#pragma mark 导入

- (void)importFile {
    UIDocumentPickerViewController *picker = nil;
#ifdef SP_HAS_UTTYPE
    picker = [[UIDocumentPickerViewController alloc]
              initForOpeningContentTypes:@[UTTypeMovie, UTTypeAudio, UTTypeData]
                                  asCopy:YES];
#else
    picker = [[UIDocumentPickerViewController alloc]
              initWithDocumentTypes:@[@"public.movie", @"public.audio", @"public.data"]
                             inMode:UIDocumentPickerModeImport];
#endif
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller
    didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    for (NSURL *src in urls) {
        NSString *name = [src lastPathComponent];
        NSURL *dst = [[self documentsURL] URLByAppendingPathComponent:name];
        NSFileManager *fm = [NSFileManager defaultManager];
        if ([fm fileExistsAtPath:[dst path]]) {
            NSString *base = [name stringByDeletingPathExtension];
            NSString *ext = [name pathExtension];
            name = [NSString stringWithFormat:@"%@-%u.%@", base, arc4random(), ext];
            dst = [[self documentsURL] URLByAppendingPathComponent:name];
        }
        NSError *err = nil;
        BOOL needStop = [src startAccessingSecurityScopedResource];
        BOOL ok = [fm copyItemAtURL:src toURL:dst error:&err];
        if (needStop) [src stopAccessingSecurityScopedResource];

        if (ok) {
            [self scanDocuments];
            NSIndexPath *ip = [NSIndexPath indexPathForRow:0 inSection:0];
            if (self.items.count > 0) [self.tableView scrollToRowAtIndexPath:ip
                                                            atScrollPosition:UITableViewScrollPositionTop
                                                                    animated:YES];
            [self playURL:dst title:name];
        } else {
            UIAlertController *a = [UIAlertController alertControllerWithTitle:@"导入失败"
                                                                      message:err.localizedDescription
                                                               preferredStyle:UIAlertControllerStyleAlert];
            [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:a animated:YES completion:nil];
        }
    }
}

#pragma mark 表格

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.items.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cid = @"cell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cid];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cid];
    }
    NSDictionary *item = self.items[indexPath.row];
    cell.textLabel.text = item[@"name"];
    cell.textLabel.font = [UIFont systemFontOfSize:15];
    cell.textLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"MM-dd HH:mm";
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%@  ·  %@",
                                 SPHumanSize([item[@"size"] unsignedLongLongValue]),
                                 [df stringFromDate:item[@"date"]]];
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    cell.imageView.image = [UIImage systemImageNamed:@"play.rectangle"];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *item = self.items[indexPath.row];
    [self playURL:item[@"url"] title:item[@"name"]];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
    trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *item = self.items[indexPath.row];
    __weak typeof(self) weakSelf = self;
    UIContextualAction *del =
        [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
                                                title:@"删除"
                                              handler:^(UIContextualAction *action, UIView *src, void (^done)(BOOL)) {
        [[NSFileManager defaultManager] removeItemAtURL:item[@"url"] error:NULL];
        [weakSelf scanDocuments];
        done(YES);
    }];
    return [UISwipeActionsConfiguration configurationWithActions:@[del]];
}

@end

#pragma mark - AppDelegate

@interface SPAppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation SPAppDelegate

- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)options {
    self.window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    SPBrowserViewController *root = [[SPBrowserViewController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:root];
    self.window.rootViewController = nav;
    [self.window makeKeyAndVisible];
    return YES;
}

@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([SPAppDelegate class]));
    }
}
