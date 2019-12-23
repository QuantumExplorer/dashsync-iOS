//
//  Created by Andrew Podkovyrin
//  Copyright © 2019 Dash Core Group. All rights reserved.
//
//  Licensed under the MIT License (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//  https://opensource.org/licenses/MIT
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//

#import "DSContactProfileViewController.h"

#import <DashSync/DashSync.h>

#import "DSContactProfileAvatarView.h"
#import "FormTableViewController.h"
#import "TextFieldFormCellModel.h"
#import "TextViewFormCellModel.h"

NS_ASSUME_NONNULL_BEGIN

@interface DSContactProfileViewController ()

@property (null_resettable, nonatomic, strong) DSContactProfileAvatarView *avatarView;
@property (null_resettable, nonatomic, strong) TextFieldFormCellModel *avatarCellModel;
@property (null_resettable, nonatomic, strong) TextViewFormCellModel *aboutMeCellModel;

@end

@implementation DSContactProfileViewController

- (instancetype)initWithBlockchainIdentity:(DSBlockchainIdentity *)blockchainIdentity {
    self = [super init];
    if (self) {
        _blockchainIdentity = blockchainIdentity;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    self.title = self.blockchainIdentity.username;

    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemCancel
                             target:self
                             action:@selector(cancelButtonAction)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemSave
                             target:self
                             action:@selector(saveButtonAction)];

    FormTableViewController *formController = [[FormTableViewController alloc] initWithStyle:UITableViewStyleGrouped];
    formController.sections = [self sections];
    formController.tableView.tableHeaderView = self.avatarView;

    [self addChildViewController:formController];
    formController.view.frame = self.view.bounds;
    formController.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:formController.view];
    [formController didMoveToParentViewController:self];

    [self updateAvatarView];
}

#pragma mark - Private

- (TextFieldFormCellModel *)avatarCellModel {
    if (!_avatarCellModel) {
        TextFieldFormCellModel *cellModel = [[TextFieldFormCellModel alloc] initWithTitle:@"Avatar"];
        cellModel.autocorrectionType = UITextAutocorrectionTypeNo;
        cellModel.returnKeyType = UIReturnKeyNext;
        cellModel.placeholder = [NSString stringWithFormat:@"https://api.adorable.io/avatars/120/%@.png",
                                                           self.blockchainIdentity.username];
        cellModel.text = self.blockchainIdentity.ownContact.avatarPath;
        __weak typeof(self) weakSelf = self;
        cellModel.didChangeValueBlock = ^(TextFieldFormCellModel *_Nonnull cellModel) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) {
                return;
            }

            [strongSelf updateAvatarView];
        };
        _avatarCellModel = cellModel;
    }
    return _avatarCellModel;
}

- (TextViewFormCellModel *)aboutMeCellModel {
    if (!_aboutMeCellModel) {
        TextViewFormCellModel *cellModel = [[TextViewFormCellModel alloc] initWithTitle:@"About me"];
        cellModel.placeholder = [NSString stringWithFormat:@"Hey I'm a demo user %@", self.blockchainIdentity.username];
        cellModel.text = self.blockchainIdentity.ownContact.publicMessage;
        _aboutMeCellModel = cellModel;
    }
    return _aboutMeCellModel;
}

- (NSArray<BaseFormCellModel *> *)profileItems {
    return @[ self.avatarCellModel, self.aboutMeCellModel ];
}

- (NSArray<FormSectionModel *> *)sections {
    FormSectionModel *section = [[FormSectionModel alloc] init];
    section.headerTitle = @"Profile";
    section.items = [self profileItems];

    return @[ section ];
}

- (DSContactProfileAvatarView *)avatarView {
    if (!_avatarView) {
        CGRect frame = CGRectMake(0.0, 0.0, [UIScreen mainScreen].bounds.size.width, 146.0);
        DSContactProfileAvatarView *avatarView = [[DSContactProfileAvatarView alloc] initWithFrame:frame];
        _avatarView = avatarView;
    }
    return _avatarView;
}

- (void)updateAvatarView {
    NSString *urlString = self.avatarCellModel.text.length > 0
                              ? self.avatarCellModel.text
                              : self.avatarCellModel.placeholder;
    NSURL *url = [NSURL URLWithString:urlString];
    [self.avatarView updateWithImageURL:url];
}

- (void)cancelButtonAction {
    [self.delegate contactProfileViewControllerDidCancel:self];
}

- (void)saveButtonAction {
    [self.view endEditing:YES];

    self.view.userInteractionEnabled = NO;
    // TODO: show HUD
    BOOL isCreate = !self.blockchainIdentity.ownContact;
    NSString *aboutMe = self.aboutMeCellModel.text.length > 0
                            ? self.aboutMeCellModel.text
                            : self.aboutMeCellModel.placeholder;
    NSString *avatarURLString = self.avatarCellModel.text.length > 0
                                    ? self.avatarCellModel.text
                                    : self.avatarCellModel.placeholder;
    __weak typeof(self) weakSelf = self;
    [self.blockchainIdentity createOrUpdateProfileWithAboutMeString:aboutMe avatarURLString:avatarURLString completion:^(BOOL success) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }

        [strongSelf showAlertTitle:isCreate ? @"Create profile result:" : @"Update profile result:" result:success completion:^{
            if (success) {
                [strongSelf.delegate contactProfileViewControllerDidUpdateProfile:self];
            }
        }];
    }];
}

- (void)showAlertTitle:(NSString *)title result:(BOOL)result completion:(void (^)(void))completion {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:result ? @"✅ success" : @"❌ failure" preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:^(UIAlertAction *_Nonnull action) {
               completion();
           }]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end

NS_ASSUME_NONNULL_END
