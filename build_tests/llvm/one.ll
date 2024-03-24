@str = private unnamed_addr constant [12 x i8] c"hello world\00"

declare i32 @puts(ptr nocapture) nounwind

define i32 @one()
{
    call i32 @puts(ptr @str)
    ret i32 0
}
