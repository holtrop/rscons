@str = private unnamed_addr constant [12 x i8] c"hello again\00"

declare i32 @puts(ptr nocapture) nounwind

define i32 @two()
{
    call i32 @puts(ptr @str)
    ret i32 0
}
