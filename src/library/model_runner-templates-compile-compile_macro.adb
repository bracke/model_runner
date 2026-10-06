separate (Model_Runner.Templates.Compile)
procedure Compile_Macro (Text : String) is
   Scan        : Natural := Text'First;
   First, Last : Natural;
   Where       : Natural;
   Added       : Macro;
begin
   Read_Word (Text, Scan, First, Last);
   if Last < First or else not Is_Plain_Name (Text (First .. Last))
     or else (Item.Macro_Used >= Max_Macros
              and then Macro_Named (Text (First .. Last)) = 0)
     or else Depth >= Max_Depth
   then
      Fail (E.Template_Unsupported_Construct, "macro");
      return;
   end if;

   declare
      Opens  : constant Natural := Skip_Spaces (Text, Scan);
      Shut   : Natural;
      Stored : Boolean;
   begin
      if Opens > Text'Last or else Text (Opens) /= '(' then
         Fail (E.Template_Unsupported_Construct, "macro");
         return;
      end if;
      Shut := Closes_At (Text, Opens);
      if Shut = 0 or else Skip_Spaces (Text, Shut + 1) <= Text'Last then
         Fail (E.Template_Unsupported_Construct, "macro");
         return;
      end if;

      Store_Literal (Text (First .. Last), Added.Name.Offset,
                     Added.Name.Length, Stored);
      if not Stored then
         Fail (E.Template_Too_Large, "source");
         return;
      end if;

      --  The parameters, a name each, with a default after an
      --  equals sign where one is written.
      declare
         Inside : constant String := Text (Opens + 1 .. Shut - 1);
         Cursor_At     : Natural := Inside'First;
      begin
         while Skip_Spaces (Inside, Cursor_At) <= Inside'Last loop
            declare
               P_First, P_Last : Natural;
               Next : Natural;
            begin
               Cursor_At := Skip_Spaces (Inside, Cursor_At);
               Read_Word (Inside, Cursor_At, P_First, P_Last);
               if P_Last < P_First
                 or else not Is_Plain_Name (Inside (P_First .. P_Last))
                 or else Added.Count >= Max_Parameters
               then
                  Fail (E.Template_Unsupported_Construct, "macro");
                  return;
               end if;
               Added.Count := Added.Count + 1;
               Added.Slots (Added.Count) :=
                 Slot_Of (Inside (P_First .. P_Last));
               if Added.Slots (Added.Count) = 0 then
                  Fail (E.Template_Too_Large, "variables");
                  return;
               end if;

               Next := Skip_Spaces (Inside, Cursor_At);
               if Next <= Inside'Last and then Inside (Next) = '=' then
                  declare
                     Value : Operand;
                     Read  : Boolean;
                     Kept  : Natural;
                  begin
                     Cursor_At := Next + 1;
                     Read_Operand (Inside, Cursor_At, Value, Read);
                     if not Read then
                        Fail (E.Template_Unsupported_Construct,
                              "macro");
                        return;
                     end if;
                     Keep (Value, Kept);
                     if Kept = 0 then
                        return;
                     end if;
                     Added.Defaults (Added.Count) := Kept;
                  end;
                  Next := Skip_Spaces (Inside, Cursor_At);
               end if;

               if Next <= Inside'Last then
                  if Inside (Next) /= ',' then
                     Fail (E.Template_Unsupported_Construct, "macro");
                     return;
                  end if;
                  Cursor_At := Next + 1;
               else
                  Cursor_At := Next;
               end if;
            end;
         end loop;
      end;
   end;

   Emit ((Op => Op_Jump, others => <>), Where);
   if Where = 0 then
      return;
   end if;
   Added.Entry_At := Item.Program_Used + 1;

   --  Declared up front, unless the name was made here (a call
   --  block's caller) or is defined a second time.
   declare
      Declared : constant Natural := Macro_Named (Text (First .. Last));
   begin
      if Declared /= 0 and then Item.Macros (Declared).Entry_At = 0 then
         Item.Macros (Declared) := Added;
      else
         Item.Macro_Used := Item.Macro_Used + 1;
         Item.Macros (Item.Macro_Used) := Added;
      end if;
   end;

   Depth := Depth + 1;
   Frames (Depth) := (Kind => Block_Macro, Pending => Where,
                      others => <>);
end Compile_Macro;
