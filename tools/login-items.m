#import <Foundation/Foundation.h>
#import <CoreServices/CoreServices.h>
int main(int argc, const char **argv) {
 @autoreleasepool {
  LSSharedFileListRef list = LSSharedFileListCreate(NULL,kLSSharedFileListSessionLoginItems,NULL);
  if (!list) return 2;
  CFArrayRef items=LSSharedFileListCopySnapshot(list,NULL);
  int result=0;
  for (id item in (__bridge NSArray *)items) {
   CFURLRef url=LSSharedFileListItemCopyResolvedURL((__bridge LSSharedFileListItemRef)item,0,NULL);
   if (!url) continue;
   NSString *path=[(__bridge NSURL *)url path];
   printf("%s\n",path.UTF8String);
   if (argc==3 && strcmp(argv[1],"--remove")==0 && [path isEqualToString:[NSString stringWithUTF8String:argv[2]]]) {
    OSStatus status=LSSharedFileListItemRemove(list,(__bridge LSSharedFileListItemRef)item);
    printf("Removal status: %d\n",(int)status); result=status==0?0:3;
   }
   CFRelease(url);
  }
  CFRelease(items); CFRelease(list); return result;
 }
}
