iCloud Access
===

_Author:_ Drew McCormack<br>
_Created:_ 18th January, 2014<br>
_Last Updated:_ 18th January, 2014

iCloud Access is a simple class that makes it easier to work with iCloud, hiding details such as file coordination and metadata queries. It is much more like accessing a web service with a Cocoa networking class, which most developers are more used to.

The class was originally developed as part of the [Ensembles](https://github.com/drewmccormack/ensembles) Core Data Sync framework, and has been extracted for easier integration in projects not using Ensembles. 

#### Install
Just drag the ICACloud.h and ICACloud.m files directly into your Mac or iOS Xcode project. 

#### Using ICACloud
The methods of the class are fairly self explanatory, mirroring `NSFileManager` to some extent. One big difference is that most are asynchronous, with a completion callback block. The completion block includes an error parameter, which should be checked. If it is `nil`, the operation was successful, and if an `NSError` is supplied, it failed.

Cloud paths are relative to the ubiquity container, but you can optionally supply a relative path to a root directory in the container. This directory, and intermediate directories, will be created automatically if they don't exist.

Here is a simple example of using the `ICACloud` class.

  cloud = [[ICACloud alloc] initWithUbiquityContainerIdentifier:@"XXXXXXXXXX.com.mycompany.cloudtest" rootDirectoryPath:@"Path/To/Data/Root"];
  [cloud createDirectoryAtPath:@"Subdirectory" completion:^(NSError *error) {
      if (error) {
          NSLog(@"Failed to create subdirectory");
          return;
      }
    
      [cloud uploadLocalFile:@"/Users/me/Downloads/LocalImage.png" toPath:@"Subdirectory/CloudImage.png" completion:^(NSError *error) {
          if (error) NSLog(@"Failed to upload: %@", error);
      }];
  }];
