separate (Model_Runner.Templates.Compile)
procedure Read_Value_Group
  (Held   : String;
   Result : out Term;
   Ok     : out Boolean)
is
   At_If   : constant Natural := Top_Level_Word (Held, "if");
   At_Else : constant Natural :=
     (if At_If = 0 then 0 else Top_Level_Word (Held, "else"));
   Test    : Condition;
   Valid   : Boolean;
   Kept    : Natural;
begin
   Result := (others => <>);
   Ok := False;

   if At_If /= 0 and then (At_Else = 0 or else At_Else > At_If) then
      declare
         Taken_Text : constant String := Held (Held'First .. At_If - 1);
         Test_Text  : constant String :=
           (if At_Else = 0 then Held (At_If + 2 .. Held'Last)
            else Held (At_If + 2 .. At_Else - 1));
         Other_Text : constant String :=
           (if At_Else = 0 then ""
            else Held (At_Else + 4 .. Held'Last));
         Taken, Other : Operand;
         Scan : Natural := Taken_Text'First;
         Read : Boolean;
      begin
         Read_Operand (Taken_Text, Scan, Taken, Read);
         if not Read
           or else Skip_Spaces (Taken_Text, Scan) <= Taken_Text'Last
         then
            return;
         end if;
         Read_Condition (Test_Text, Test, Valid);
         if not Valid then
            return;
         end if;
         Keep (Taken, Kept);
         if Kept = 0 then
            return;
         end if;
         Result.Kind := Term_Choice;
         Result.Index_At := Kept;
         Keep (Test, Kept);
         if Kept = 0 then
            return;
         end if;
         Result.Offset := Kept;
         if Model_Runner.Text.Trim (Other_Text) /= "" then
            Scan := Other_Text'First;
            Read_Operand (Other_Text, Scan, Other, Read);
            if not Read
              or else Skip_Spaces (Other_Text, Scan) <= Other_Text'Last
            then
               return;
            end if;
            Keep (Other, Kept);
            if Kept = 0 then
               return;
            end if;
            Result.Length := Kept;
         end if;
         Ok := True;
         return;
      end;
   end if;

   --  "A or B" and "A and B" where both sides are operands: one
   --  side or the other, as the language answers them. Anything
   --  with a comparison in it is not two operands and goes on to be
   --  read as the condition it is.
   declare
      At_Or  : constant Natural := Top_Level_Word (Held, "or");
      At_And : constant Natural := Top_Level_Word (Held, "and");
      At_Word : constant Natural :=
        (if At_Or /= 0 and then (At_And = 0 or else At_Or < At_And)
         then At_Or else At_And);
      Width  : constant Natural := (if At_Word = At_Or then 2 else 3);
   begin
      if At_Word /= 0 then
         declare
            Left_Text  : constant String := Held (Held'First .. At_Word - 1);
            Right_Text : constant String :=
              Held (At_Word + Width .. Held'Last);
            Left, Right : Operand;
            Scan : Natural := Left_Text'First;
            Read : Boolean;
         begin
            Read_Operand (Left_Text, Scan, Left, Read);
            if Read
              and then Skip_Spaces (Left_Text, Scan) > Left_Text'Last
            then
               Scan := Right_Text'First;
               Read_Operand (Right_Text, Scan, Right, Read);
               if Read
                 and then Skip_Spaces (Right_Text, Scan) > Right_Text'Last
               then
                  Keep (Left, Kept);
                  if Kept = 0 then
                     return;
                  end if;
                  Result.Index_At := Kept;
                  Keep (Right, Kept);
                  if Kept = 0 then
                     return;
                  end if;
                  Result.Length := Kept;
                  Result.Kind :=
                    (if At_Word = At_Or then Term_Or else Term_And);
                  Ok := True;
                  return;
               end if;
            end if;
         end;
      end if;
   end;

   Read_Condition (Held, Test, Valid);
   if not Valid then
      return;
   end if;
   Keep (Test, Kept);
   if Kept = 0 then
      return;
   end if;
   Result.Kind := Term_Condition;
   Result.Offset := Kept;
   Ok := True;
end Read_Value_Group;
