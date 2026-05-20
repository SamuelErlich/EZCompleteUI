// LoginViewController.m
// EZCompleteUI

#import "LoginViewController.h"
#import "EZAuthManager.h"
#import "ViewController.h"

// ── Constants ─────────────────────────────────────────────────────────────────

static NSString *const kLastEmailKey         = @"EZLastSignedInEmail";
static NSString *const kLastAuthDateKey      = @"EZLastAuthenticatedDate";
static const NSTimeInterval kReAuthInterval  = 60 * 60 * 24 * 7; // 7 days

// ── Supabase error code → human readable ──────────────────────────────────────

static NSString *EZFriendlyAuthError(NSString *code, NSString *description) {
    if (!code && !description) return @"Something went wrong. Please try again.";

    // Supabase error codes
    if ([code isEqualToString:@"invalid_credentials"] ||
        [description containsString:@"Invalid login credentials"] ||
        [description containsString:@"invalid_credentials"]) {
        return @"Incorrect email or password. Please try again.";
    }
    if ([code isEqualToString:@"email_not_confirmed"] ||
        [description containsString:@"Email not confirmed"]) {
        return @"Please check your email and confirm your account before signing in.";
    }
    if ([code isEqualToString:@"user_already_exists"] ||
        [description containsString:@"User already registered"]) {
        return @"An account with this email already exists. Try signing in instead.";
    }
    if ([code isEqualToString:@"weak_password"] ||
        [description containsString:@"Password should be"]) {
        return @"Password is too weak. Use at least 8 characters with a mix of letters and numbers.";
    }
    if ([code isEqualToString:@"over_email_send_rate_limit"] ||
        [description containsString:@"rate limit"]) {
        return @"Too many attempts. Please wait a few minutes and try again.";
    }
    if ([code isEqualToString:@"signup_disabled"] ||
        [description containsString:@"Signups not allowed"]) {
        return @"New signups are temporarily disabled. Please try again later.";
    }
    if ([code isEqualToString:@"email_address_invalid"] ||
        [description containsString:@"valid email"]) {
        return @"Please enter a valid email address.";
    }
    if ([description containsString:@"Network"] ||
        [description containsString:@"network"] ||
        [description containsString:@"connection"] ||
        [description containsString:@"offline"]) {
        return @"Network error. Check your connection and try again.";
    }

    // Fall back to the raw description if we have one, otherwise generic
    return description.length > 0 ? description : @"Something went wrong. Please try again.";
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Interface
// ─────────────────────────────────────────────────────────────────────────────

@interface LoginViewController ()
@property (nonatomic, strong) UIScrollView              *scrollView;
@property (nonatomic, strong) UIView                    *containerView;
@property (nonatomic, strong) UILabel                   *titleLabel;
@property (nonatomic, strong) UILabel                   *subtitleLabel;
@property (nonatomic, strong) UITextField               *emailField;
@property (nonatomic, strong) UITextField               *passwordField;
@property (nonatomic, strong) UIButton                  *loginButton;
@property (nonatomic, strong) UIButton                  *toggleModeButton;
@property (nonatomic, strong) UIActivityIndicatorView   *spinner;
@property (nonatomic, strong) UILabel                   *errorLabel;
@property (nonatomic, strong) UILabel                   *savedAccountLabel;
@property (nonatomic, assign) BOOL                       isSignUpMode;
@end

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Implementation
// ─────────────────────────────────────────────────────────────────────────────

@implementation LoginViewController

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    [self setupUI];
    [self prefillSavedEmail];
    [self registerForKeyboardNotifications];
}

#pragma mark - Pre-fill

- (void)prefillSavedEmail {
    NSString *savedEmail = [[NSUserDefaults standardUserDefaults]
                            stringForKey:kLastEmailKey];
    if (savedEmail.length == 0) return;

    // Show which account was last used
    self.savedAccountLabel.text = [NSString stringWithFormat:
                                   @"Last signed in as %@", savedEmail];
    self.savedAccountLabel.hidden = NO;

    // Pre-fill email field
    self.emailField.text = savedEmail;

    // Hint that a password exists without pre-filling it (security best practice)
    // Using a custom placeholder that looks like masked characters
    NSAttributedString *hint = [[NSAttributedString alloc]
        initWithString:@"••••••••"
            attributes:@{
                NSForegroundColorAttributeName: [UIColor tertiaryLabelColor],
                NSFontAttributeName: [UIFont systemFontOfSize:17]
            }];
    self.passwordField.attributedPlaceholder = hint;
}

#pragma mark - UI Construction

- (void)setupUI {
    // Scroll view
    self.scrollView = [[UIScrollView alloc] init];
    self.scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.scrollView];

    self.containerView = [[UIView alloc] init];
    self.containerView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.scrollView addSubview:self.containerView];

    // Title
    self.titleLabel = [[UILabel alloc] init];
    self.titleLabel.text = @"EZCompleteUI";
    self.titleLabel.font = [UIFont systemFontOfSize:32 weight:UIFontWeightBold];
    self.titleLabel.textAlignment = NSTextAlignmentCenter;
    self.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;

    // Subtitle
    self.subtitleLabel = [[UILabel alloc] init];
    self.subtitleLabel.text = @"Sign in to continue";
    self.subtitleLabel.font = [UIFont systemFontOfSize:16];
    self.subtitleLabel.textColor = [UIColor secondaryLabelColor];
    self.subtitleLabel.textAlignment = NSTextAlignmentCenter;
    self.subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;

    // Saved account label — shown when a previous email is remembered
    self.savedAccountLabel = [[UILabel alloc] init];
    self.savedAccountLabel.font = [UIFont systemFontOfSize:12];
    self.savedAccountLabel.textColor = [UIColor secondaryLabelColor];
    self.savedAccountLabel.textAlignment = NSTextAlignmentCenter;
    self.savedAccountLabel.hidden = YES;
    self.savedAccountLabel.translatesAutoresizingMaskIntoConstraints = NO;

    // Email field
    self.emailField = [self makeTextField:@"Email" secure:NO];
    self.emailField.keyboardType = UIKeyboardTypeEmailAddress;
    self.emailField.autocapitalizationType = UITextAutocapitalizationTypeNone;

    // Password field
    self.passwordField = [self makeTextField:@"Password" secure:YES];

    // Error label
    self.errorLabel = [[UILabel alloc] init];
    self.errorLabel.textColor = [UIColor systemRedColor];
    self.errorLabel.font = [UIFont systemFontOfSize:13];
    self.errorLabel.textAlignment = NSTextAlignmentCenter;
    self.errorLabel.numberOfLines = 0;
    self.errorLabel.hidden = YES;
    self.errorLabel.translatesAutoresizingMaskIntoConstraints = NO;

    // Login button
    self.loginButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.loginButton setTitle:@"Sign In" forState:UIControlStateNormal];
    self.loginButton.titleLabel.font = [UIFont systemFontOfSize:17
                                                         weight:UIFontWeightSemibold];
    self.loginButton.backgroundColor = [UIColor systemBlueColor];
    [self.loginButton setTitleColor:[UIColor whiteColor]
                           forState:UIControlStateNormal];
    self.loginButton.layer.cornerRadius = 12;
    self.loginButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.loginButton addTarget:self
                         action:@selector(handleLogin)
               forControlEvents:UIControlEventTouchUpInside];

    // Toggle mode button
    self.toggleModeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.toggleModeButton setTitle:@"Don't have an account? Sign Up"
                           forState:UIControlStateNormal];
    self.toggleModeButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.toggleModeButton addTarget:self
                              action:@selector(toggleMode)
                    forControlEvents:UIControlEventTouchUpInside];

    // Spinner
    self.spinner = [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.spinner.translatesAutoresizingMaskIntoConstraints = NO;
    self.spinner.hidesWhenStopped = YES;

    // Add subviews
    for (UIView *v in @[self.titleLabel, self.subtitleLabel, self.savedAccountLabel,
                        self.emailField, self.passwordField, self.errorLabel,
                        self.loginButton, self.toggleModeButton, self.spinner]) {
        [self.containerView addSubview:v];
    }

    // Constraints
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.scrollView.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [self.scrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.scrollView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

        [self.containerView.topAnchor constraintEqualToAnchor:self.scrollView.topAnchor],
        [self.containerView.leadingAnchor constraintEqualToAnchor:self.scrollView.leadingAnchor],
        [self.containerView.trailingAnchor constraintEqualToAnchor:self.scrollView.trailingAnchor],
        [self.containerView.bottomAnchor constraintEqualToAnchor:self.scrollView.bottomAnchor],
        [self.containerView.widthAnchor constraintEqualToAnchor:self.scrollView.widthAnchor],

        [self.titleLabel.topAnchor constraintEqualToAnchor:self.containerView.topAnchor constant:80],
        [self.titleLabel.leadingAnchor constraintEqualToAnchor:self.containerView.leadingAnchor constant:32],
        [self.titleLabel.trailingAnchor constraintEqualToAnchor:self.containerView.trailingAnchor constant:-32],

        [self.subtitleLabel.topAnchor constraintEqualToAnchor:self.titleLabel.bottomAnchor constant:8],
        [self.subtitleLabel.leadingAnchor constraintEqualToAnchor:self.containerView.leadingAnchor constant:32],
        [self.subtitleLabel.trailingAnchor constraintEqualToAnchor:self.containerView.trailingAnchor constant:-32],

        [self.savedAccountLabel.topAnchor constraintEqualToAnchor:self.subtitleLabel.bottomAnchor constant:6],
        [self.savedAccountLabel.leadingAnchor constraintEqualToAnchor:self.containerView.leadingAnchor constant:32],
        [self.savedAccountLabel.trailingAnchor constraintEqualToAnchor:self.containerView.trailingAnchor constant:-32],

        [self.emailField.topAnchor constraintEqualToAnchor:self.savedAccountLabel.bottomAnchor constant:32],
        [self.emailField.leadingAnchor constraintEqualToAnchor:self.containerView.leadingAnchor constant:24],
        [self.emailField.trailingAnchor constraintEqualToAnchor:self.containerView.trailingAnchor constant:-24],
        [self.emailField.heightAnchor constraintEqualToConstant:52],

        [self.passwordField.topAnchor constraintEqualToAnchor:self.emailField.bottomAnchor constant:12],
        [self.passwordField.leadingAnchor constraintEqualToAnchor:self.containerView.leadingAnchor constant:24],
        [self.passwordField.trailingAnchor constraintEqualToAnchor:self.containerView.trailingAnchor constant:-24],
        [self.passwordField.heightAnchor constraintEqualToConstant:52],

        [self.errorLabel.topAnchor constraintEqualToAnchor:self.passwordField.bottomAnchor constant:8],
        [self.errorLabel.leadingAnchor constraintEqualToAnchor:self.containerView.leadingAnchor constant:24],
        [self.errorLabel.trailingAnchor constraintEqualToAnchor:self.containerView.trailingAnchor constant:-24],

        [self.loginButton.topAnchor constraintEqualToAnchor:self.errorLabel.bottomAnchor constant:24],
        [self.loginButton.leadingAnchor constraintEqualToAnchor:self.containerView.leadingAnchor constant:24],
        [self.loginButton.trailingAnchor constraintEqualToAnchor:self.containerView.trailingAnchor constant:-24],
        [self.loginButton.heightAnchor constraintEqualToConstant:52],

        [self.toggleModeButton.topAnchor constraintEqualToAnchor:self.loginButton.bottomAnchor constant:16],
        [self.toggleModeButton.centerXAnchor constraintEqualToAnchor:self.containerView.centerXAnchor],

        [self.spinner.topAnchor constraintEqualToAnchor:self.toggleModeButton.bottomAnchor constant:16],
        [self.spinner.centerXAnchor constraintEqualToAnchor:self.containerView.centerXAnchor],
        [self.spinner.bottomAnchor constraintEqualToAnchor:self.containerView.bottomAnchor constant:-40],
    ]];
}

- (UITextField *)makeTextField:(NSString *)placeholder secure:(BOOL)secure {
    UITextField *tf = [[UITextField alloc] init];
    tf.placeholder = placeholder;
    tf.secureTextEntry = secure;
    tf.borderStyle = UITextBorderStyleNone;
    tf.backgroundColor = [UIColor secondarySystemBackgroundColor];
    tf.layer.cornerRadius = 12;
    tf.leftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 16, 0)];
    tf.leftViewMode = UITextFieldViewModeAlways;
    tf.translatesAutoresizingMaskIntoConstraints = NO;
    tf.autocorrectionType = UITextAutocorrectionTypeNo;
    return tf;
}

#pragma mark - Mode toggle

- (void)toggleMode {
    self.isSignUpMode = !self.isSignUpMode;
    if (self.isSignUpMode) {
        self.subtitleLabel.text = @"Create your account";
        [self.loginButton setTitle:@"Sign Up" forState:UIControlStateNormal];
        [self.toggleModeButton setTitle:@"Already have an account? Sign In"
                               forState:UIControlStateNormal];
        self.savedAccountLabel.hidden = YES;
    } else {
        self.subtitleLabel.text = @"Sign in to continue";
        [self.loginButton setTitle:@"Sign In" forState:UIControlStateNormal];
        [self.toggleModeButton setTitle:@"Don't have an account? Sign Up"
                               forState:UIControlStateNormal];
        [self prefillSavedEmail];
    }
    self.errorLabel.hidden = YES;
}

#pragma mark - Login / Signup

- (void)handleLogin {
    NSString *email    = [self.emailField.text
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *password = self.passwordField.text;

    if (email.length == 0) {
        [self showError:@"Please enter your email address."];
        return;
    }
    if (password.length == 0) {
        [self showError:@"Please enter your password."];
        return;
    }
    if (![email containsString:@"@"]) {
        [self showError:@"Please enter a valid email address."];
        return;
    }
    if (!self.isSignUpMode && password.length < 6) {
        [self showError:@"Password must be at least 6 characters."];
        return;
    }

    [self setLoading:YES];
    self.errorLabel.hidden = YES;

    void(^completion)(BOOL, NSString *) = ^(BOOL success, NSString *errorMsg) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self setLoading:NO];
            if (success) {
                // Save email for next launch pre-fill
                [[NSUserDefaults standardUserDefaults] setObject:email
                                                         forKey:kLastEmailKey];
                // Record auth timestamp for periodic re-auth
                [[NSUserDefaults standardUserDefaults]
                    setDouble:[[NSDate date] timeIntervalSince1970]
                       forKey:kLastAuthDateKey];
                [[NSUserDefaults standardUserDefaults] synchronize];
                [self proceedToApp];
            } else {
                [self showError:errorMsg ?: @"Something went wrong. Please try again."];
            }
        });
    };

    if (self.isSignUpMode) {
        [[EZAuthManager shared] signUpWithEmail:email
                                       password:password
                                     completion:completion];
    } else {
        [[EZAuthManager shared] signInWithEmail:email
                                       password:password
                                     completion:completion];
    }
}

#pragma mark - Navigation

- (void)proceedToApp {
    ViewController *vc = [[ViewController alloc] init];
    UIWindow *window = self.view.window;
    window.rootViewController = vc;
    [UIView transitionWithView:window
                      duration:0.3
                       options:UIViewAnimationOptionTransitionCrossDissolve
                    animations:nil
                    completion:nil];
}

#pragma mark - Helpers

- (void)showError:(NSString *)message {
    self.errorLabel.text = message;
    self.errorLabel.hidden = NO;
}

- (void)setLoading:(BOOL)loading {
    loading ? [self.spinner startAnimating] : [self.spinner stopAnimating];
    self.loginButton.enabled    = !loading;
    self.emailField.enabled     = !loading;
    self.passwordField.enabled  = !loading;
    self.toggleModeButton.enabled = !loading;
}

#pragma mark - Keyboard

- (void)registerForKeyboardNotifications {
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(keyboardWillShow:)
                                                 name:UIKeyboardWillShowNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(keyboardWillHide:)
                                                 name:UIKeyboardWillHideNotification
                                               object:nil];
}

- (void)keyboardWillShow:(NSNotification *)notification {
    CGSize keyboardSize = [notification.userInfo[UIKeyboardFrameEndUserInfoKey]
                           CGRectValue].size;
    self.scrollView.contentInset = UIEdgeInsetsMake(0, 0, keyboardSize.height, 0);
}

- (void)keyboardWillHide:(NSNotification *)notification {
    self.scrollView.contentInset = UIEdgeInsetsZero;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

@end
