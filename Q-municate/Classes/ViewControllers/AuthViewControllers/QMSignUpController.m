//
//  QMSignUpController.m
//  Q-municate
//
//  Created by Igor Alefirenko on 13/02/2014.
//  Copyright (c) 2014 Quickblox. All rights reserved.
//

#import "QMSignUpController.h"
#import "QMWelcomeScreenViewController.h"
#import "UIImage+Cropper.h"
#import "QMAddressBook.h"
#import "QMAuthService.h"
#import "QMChatService.h"
#import "QMContactList.h"
#import "QMContent.h"
#import "QMUtilities.h"

@interface QMSignUpController () <UIImagePickerControllerDelegate, UINavigationControllerDelegate>

@property (weak, nonatomic) IBOutlet UITextField *fullNameField;
@property (weak, nonatomic) IBOutlet UITextField *emailField;
@property (weak, nonatomic) IBOutlet UITextField *passwordField;
@property (weak, nonatomic) IBOutlet UIImageView *userImage;

@property (strong, nonatomic) UIImage *cachedPicture;

- (IBAction)chooseUserPicture:(id)sender;
- (IBAction)signUp:(id)sender;

@end


@implementation QMSignUpController


- (void)viewDidLoad
{
    [super viewDidLoad];
    [self configureAvatarImage];
    [[UIApplication sharedApplication] setStatusBarStyle:UIStatusBarStyleLightContent];
}


#pragma mark - UI

- (void)configureAvatarImage
{
    CALayer *imageLayer = self.userImage.layer;
    imageLayer.cornerRadius = self.userImage.frame.size.width / 2;
    imageLayer.masksToBounds = YES;
}


#pragma mark - Actions

- (IBAction)hideKeyboard:(id)sender
{
    [sender resignFirstResponder];
}

- (IBAction)switchToLoginController:(id)sender
{
    UINavigationController *navController = [self.root.childViewControllers lastObject];
    [self.root logInToQuickblox];
    [navController removeFromParentViewController];
}

- (IBAction)chooseUserPicture:(id)sender
{
    UIImagePickerController *imagePicker = [[UIImagePickerController alloc] init];
    imagePicker.delegate = self;
    imagePicker.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
    [self presentViewController:imagePicker animated:YES completion:nil];
}

- (IBAction)signUp:(id)sender
{
    if ([self.emailField.text isEqual:kEmptyString] || [self.fullNameField.text isEqual:kEmptyString] || [self.passwordField isEqual:kEmptyString]) {
        [self showAlertWithMessage:kAlertBodyFillInAllFieldsString success:NO];
        return;
    }
    
    [QMUtilities createIndicatorView];
    [[QMAuthService shared] signUpWithFullName:self.fullNameField.text email:self.emailField.text password:self.passwordField.text blobID:0 completion:^(QBUUser *user, BOOL success, NSError *error) {
        if (error) {
            [self showAlertWithMessage:error.domain success:NO];
            [QMUtilities removeIndicatorView];
            return;
        }
        
        // load image and update user with blob ID:
        if (self.cachedPicture != nil) {
            [self loginWithUser:user afterLoadingImage:self.cachedPicture];
            return;
        }
        [self loginWithUserWithoutImage:user];
    }];
}

// **************** 
- (void)loginWithUser:(QBUUser *)user afterLoadingImage:(UIImage *)image
{
    [[QMAuthService shared] logInWithEmail:user.email password:self.passwordField.text completion:^(QBUUser *user, BOOL success, NSError *error) {
        [self updateUser:user withAvatar:image];
    }];
}

- (void)loginWithUserWithoutImage:(QBUUser *)user
{
    [[QMAuthService shared] logInWithEmail:user.email password:self.passwordField.text completion:^(QBUUser *user, BOOL success, NSError *error) {
        if (!success) {
            return;
        }
        // save me:
        user.password = self.passwordField.text;
        [QMContactList shared].me = user;
        
        [[QMChatService shared] loginWithUser:user completion:^(BOOL success) {
            if (success) {
                [self getFriends];
            }
        }];
    }];
}

- (void)updateUser:(QBUUser *)user withAvatar:(UIImage *)image
{
    QMContent *content = [[QMContent alloc] init];
    [content loadImageForBlob:image named:user.email completion:^(QBCBlob *blob) {
        //
        [[QMAuthService shared] updateUser:user withBlob:blob completion:^(QBUUser *user, BOOL success, NSError *error) {
            if (!success) {
                return;
            }
            user.password = self.passwordField.text;
            [QMContactList shared].me = user;
            
            // login to chat:
            [[QMChatService shared] loginWithUser:user completion:^(BOOL success) {
                if (success) {
                    [self getFriends];
                }
            }];
        }];
    }];
}

- (void)getFriends
{
    [[QMContactList shared] retrieveFriendsUsingBlock:^(BOOL success) {
        [QMUtilities removeIndicatorView];
        [self.root dismissViewControllerAnimated:NO completion:nil];
        [[NSNotificationCenter defaultCenter] postNotificationName:kFriendsLoadedNotification object:nil];
        [[NSNotificationCenter defaultCenter] postNotificationName:kLoggedInNotification object:nil];
    }];
}


#pragma mark - Alert

- (void)showAlertWithMessage:(NSString *)message success:(BOOL)success
{
    NSString *title = nil;
    if (success) {
        title = kEmptyString;
    } else {
        title = kAlertTitleErrorString;
    }
    UIAlertView *alert = [[UIAlertView alloc] initWithTitle:title
                                                    message:message
                                                   delegate:nil
                                          cancelButtonTitle:kAlertButtonTitleOkString
                                          otherButtonTitles: nil];
    [alert show];
}


#pragma mark - UIImagePickerControllerDelegate


- (void)imagePickerController:(UIImagePickerController *)picker didFinishPickingMediaWithInfo:(NSDictionary *)info
{
    CGSize imgViewSize = self.userImage.frame.size;
    UIImage *image =  info[UIImagePickerControllerOriginalImage];
    UIImage *scaledImage = [image imageByScalingProportionallyToMinimumSize:imgViewSize];
    [self.userImage setImage:scaledImage];
    self.cachedPicture = scaledImage;
    
    [self dismissViewControllerAnimated:YES completion:nil];
    [[UIApplication sharedApplication] setStatusBarStyle:UIStatusBarStyleLightContent];
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker
{
    [self dismissViewControllerAnimated:YES completion:nil];
    [[UIApplication sharedApplication] setStatusBarStyle:UIStatusBarStyleLightContent];
}

@end