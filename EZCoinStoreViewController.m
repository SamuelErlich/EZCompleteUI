// Closed beta wallet. There is deliberately no checkout code in this target.
#import "EZCoinStoreViewController.h"
#import "EZAuthManager.h"
#import "EZEntitlementManager.h"
#import "EZCoinUsageViewController.h"
#import "EZUITheme.h"

@interface EZCoinStoreViewController ()
@property(nonatomic,strong) UILabel *balanceLabel;
@property(nonatomic,strong) UILabel *statusLabel;
@property(nonatomic,strong) UIButton *grantButton;
@property(nonatomic,strong) UIActivityIndicatorView *spinner;
@end

@implementation EZCoinStoreViewController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Carteira de teste";
    self.view.backgroundColor = [EZUITheme backgroundColor];
    self.view.tintColor = [EZUITheme accentSecondaryColor];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Fechar"
        style:UIBarButtonItemStylePlain target:self action:@selector(close)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Extrato"
        style:UIBarButtonItemStylePlain target:self action:@selector(historyTapped)];
    UIScrollView *scroll = [UIScrollView new];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:scroll];
    UIStackView *stack = [UIStackView new];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 24;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:32],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-32],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:24],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-24],
        [stack.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-48]
    ]];
    self.balanceLabel = [UILabel new];
    self.balanceLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleLargeTitle];
    self.balanceLabel.adjustsFontForContentSizeCategory = YES;
    self.balanceLabel.textColor = [EZUITheme primaryTextColor];
    self.balanceLabel.textAlignment = NSTextAlignmentCenter;
    self.balanceLabel.numberOfLines = 0;
    self.balanceLabel.text = @"Consultando saldo…";
    [stack addArrangedSubview:self.balanceLabel];
    UILabel *explanation = [UILabel new];
    explanation.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    explanation.adjustsFontForContentSizeCategory = YES;
    explanation.numberOfLines = 0;
    explanation.textColor = [EZUITheme secondaryTextColor];
    explanation.text = @"Beta fechada • sem cobrança real\n\nOs créditos de teste são liberados uma única vez pelo servidor para sua conta autorizada. Cada resposta de demonstração usa 1 crédito. A demonstração não consulta uma IA real.\n\nPayPal, Pix, cartão e assinaturas serão adicionados depois dos testes.";
    [stack addArrangedSubview:explanation];
    self.grantButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.grantButton setTitle:@"Verificando créditos de teste…" forState:UIControlStateNormal];
    [EZUITheme stylePrimaryButton:self.grantButton];
    self.grantButton.enabled = NO;
    [self.grantButton.heightAnchor constraintGreaterThanOrEqualToConstant:56].active = YES;
    [self.grantButton addTarget:self action:@selector(claimTestCredits) forControlEvents:UIControlEventTouchUpInside];
    [stack addArrangedSubview:self.grantButton];
    self.statusLabel = [UILabel new];
    self.statusLabel.numberOfLines = 0;
    self.statusLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    self.statusLabel.textColor = [EZUITheme secondaryTextColor];
    [stack addArrangedSubview:self.statusLabel];
    UIButton *refresh = [UIButton buttonWithType:UIButtonTypeSystem];
    [refresh setTitle:@"Atualizar saldo" forState:UIControlStateNormal];
    [refresh addTarget:self action:@selector(refreshWallet) forControlEvents:UIControlEventTouchUpInside];
    [stack addArrangedSubview:refresh];
    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    [stack addArrangedSubview:self.spinner];
    [self refreshWallet];
}
- (void)close { [self dismissViewControllerAnimated:YES completion:nil]; }
- (void)historyTapped {
    EZCoinUsageViewController *vc = [EZCoinUsageViewController new];
    [self presentViewController:[[UINavigationController alloc] initWithRootViewController:vc]
                      animated:YES completion:nil];
}
- (void)refreshWallet {
    [self.spinner startAnimating];
    NSString *account = [EZAuthManager shared].userId;
    [[EZAuthManager shared] postToPath:@"/functions/v1/wallet" body:@{}
        completion:^(NSDictionary *data, NSError *error) {
        [self.spinner stopAnimating];
        if (![account isEqualToString:[EZAuthManager shared].userId]) return;
        if (error || ![data[@"balance"] isKindOfClass:NSNumber.class]) {
            self.balanceLabel.text = @"Saldo indisponível";
            self.statusLabel.text = error.localizedDescription ?: @"Resposta de saldo inválida.";
            self.grantButton.enabled = NO;
            return;
        }
        NSInteger balance = [data[@"balance"] integerValue];
        self.balanceLabel.text = [NSString stringWithFormat:@"%ld créditos de teste",(long)balance];
        [[EZEntitlementManager shared] applyKnownBalance:balance];
        [[EZAuthManager shared] postToPath:@"/functions/v1/ez-grant-test-credits"
            body:@{@"action":@"status"} completion:^(NSDictionary *status, NSError *statusError) {
            if (![account isEqualToString:[EZAuthManager shared].userId]) return;
            BOOL available = !statusError && [status[@"available"] isKindOfClass:NSNumber.class] && [status[@"available"] boolValue];
            BOOL claimed = [status[@"claimed"] isKindOfClass:NSNumber.class] && [status[@"claimed"] boolValue];
            self.grantButton.enabled = available;
            [self.grantButton setTitle:claimed ? @"Créditos de teste já recebidos" : @"Receber créditos de teste"
                             forState:UIControlStateNormal];
            self.statusLabel.text = statusError.localizedDescription ?: (available ? @"Disponível para esta conta." :
                (claimed ? @"A concessão inicial desta conta já foi utilizada." : @"Aguardando liberação desta conta no servidor."));
        }];
    }];
}
- (void)claimTestCredits {
    self.grantButton.enabled = NO;
    [self.spinner startAnimating];
    NSString *account = [EZAuthManager shared].userId;
    // Request identity is stable after a timeout/relaunch. It is NOT authority
    // to mint credits: the server enforces a single fixed grant per account.
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSString *keyName = [@"EZBetaGrant." stringByAppendingString:account ?: @"anonymous"];
    NSString *key = [defaults stringForKey:keyName];
    if (!key) { key=NSUUID.UUID.UUIDString; [defaults setObject:key forKey:keyName]; }
    [[EZAuthManager shared] postToPath:@"/functions/v1/ez-grant-test-credits"
        body:@{@"grant_key":key} completion:^(NSDictionary *data, NSError *error) {
        [self.spinner stopAnimating];
        if (![account isEqualToString:[EZAuthManager shared].userId]) return;
        if (error) {
            self.statusLabel.text=error.localizedDescription;
            self.grantButton.enabled=YES;
            return;
        }
        [self refreshWallet];
        [[NSNotificationCenter defaultCenter] postNotificationName:@"EZSubscriptionUpdated" object:nil];
    }];
}
@end
