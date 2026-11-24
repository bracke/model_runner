with Ada.Directories;
with Ada.Strings.Unbounded;
with Hostkit.Process;
with Hostkit;
with Hostkit.Fs;
with Project_Tools.Files;
with Trial_Graders;
with Agent_Trial;

package body Learning_Curriculum is
   use Ada.Strings.Unbounded;
   use type Agent_Trial.Verdict;
   use type Hostkit.String_Vectors.Vector;
   LF : constant String := [1 => ASCII.LF];
   function Family (Which : Positive) return String is
     (case Which is
         when 1 => "ascii-case", when 2 => "array-parity", when 3 => "reverse-character-search",
         when 4 => "record-visibility", when 5 => "gregorian-calendar", when others => "invalid");
   function Notes (Which : Positive) return String is
     (case Which is
         when 1 => "Fix Calc.Lower_ASCII in src/calc.adb to lowercase A through Z and preserve every other"
           & " character. Preserve the string bounds and handle empty strings. Change only that function.",
         when 2 => "Fix Calc.Count_Even in src/calc.adb to count even elements, including zero and negative"
           & " even numbers. Handle arrays of any bounds, including empty arrays. Change only that function.",
         when 3 => "Fix Calc.Last_Index in src/calc.adb to return the last index containing Needle, or zero"
           & " if absent. Handle empty strings and strings whose lower bound is not one. Change only that function.",
         when 4 => "Fix Calc.Visible in src/calc.adb: an entry is visible exactly when Active is true and"
           & " Deleted is false. Change only Visible and keep the public types unchanged.",
         when 5 => "Fix Calc.Is_Leap in src/calc.adb to implement the Gregorian leap-year rule: divisible"
           & " by four, except centuries unless divisible by 400. Change only that function.",
         when others => "invalid");
   procedure Make_Project (Root : String; Which : Positive; Reference : Boolean := False) is
      function Spec return String is
        (case Which is
            when 1 => "   function Lower_ASCII (Text : String) return String;",
            when 2 => "   type Values is array (Integer range <>) of Integer;" & LF
              & "   function Count_Even (Items : Values) return Natural;",
            when 3 => "   function Last_Index (Text : String; Needle : Character) return Natural;",
            when 4 => "   type Entry_Info is record Active, Deleted : Boolean; end record;" & LF
              & "   function Visible (Item : Entry_Info) return Boolean;",
            when others => "   function Is_Leap (Year : Positive) return Boolean;");
      function Body_Text return String is
        (case Which is
            when 1 => "   function Lower_ASCII (Text : String) return String is" & LF
              & (if Reference then "      Result : String := Text;" & LF & "   begin" & LF
                 & "      for I in Result'Range loop" & LF & "         if Result (I) in 'A' .. 'Z' then" & LF
                 & "            Result (I) := Character'Val (Character'Pos (Result (I)) + 32);" & LF
                 & "         end if;" & LF & "      end loop;" & LF & "      return Result;" & LF
                 else "   begin" & LF & "      return Text;" & LF) & "   end Lower_ASCII;",
            when 2 => "   function Count_Even (Items : Values) return Natural is" & LF
              & (if Reference then "      Count : Natural := 0;" & LF & "   begin" & LF
                 & "      for Item of Items loop" & LF & "         if Item mod 2 = 0 then" & LF
                 & "            Count := Count + 1;" & LF & "         end if;" & LF & "      end loop;" & LF
                 & "      return Count;" & LF else "   begin" & LF & "      return 0;" & LF) & "   end Count_Even;",
            when 3 => "   function Last_Index (Text : String; Needle : Character) return Natural is" & LF
              & "   begin" & LF & (if Reference then "      for I in reverse Text'Range loop" & LF
                 & "         if Text (I) = Needle then return I; end if;" & LF & "      end loop;" & LF else "")
              & "      return 0;" & LF & "   end Last_Index;",
            when 4 => "   function Visible (Item : Entry_Info) return Boolean is" & LF & "   begin" & LF
              & "      return Item.Active" & (if Reference then " and then not Item.Deleted" else "") & ";" & LF
              & "   end Visible;",
            when others => "   function Is_Leap (Year : Positive) return Boolean is" & LF & "   begin" & LF
              & (if Reference then "      return Year mod 4 = 0 and then (Year mod 100 /= 0 or else Year mod 400 = 0);"
                 else "      return False;") & LF & "   end Is_Leap;");
      function Checks return String is
        (case Which is
            when 1 => "   Shifted : constant String (3 .. 4) := ""AZ"";" & LF & "begin" & LF
              & "   if Calc.Lower_ASCII (""AZ09z!"") /= ""az09z!"" or else Calc.Lower_ASCII ("""") /= """""
              & " or else Calc.Lower_ASCII (Shifted) /= ""az"" or else Calc.Lower_ASCII (Shifted)'First /= 3",
            when 2 => "begin" & LF & "   if Calc.Count_Even ((2 => -4, 3 => -3, 4 => 0, 5 => 5, 6 => 8)) /= 3"
              & " or else Calc.Count_Even (Calc.Values'(1 .. 0 => 0)) /= 0"
              & " or else Calc.Count_Even ((1 => Integer'First, 2 => Integer'Last)) /= 1",
            when 3 => "   Shifted : constant String (3 .. 6) := ""abac"";" & LF & "begin" & LF
              & "   if Calc.Last_Index (""abac"", 'a') /= 3 or else Calc.Last_Index ("""", 'a') /= 0"
              & " or else Calc.Last_Index (""bbb"", 'a') /= 0 or else Calc.Last_Index (Shifted, 'a') /= 5",
            when 4 => "begin" & LF & "   if Calc.Visible ((False, False)) or else Calc.Visible ((False, True))"
              & " or else not Calc.Visible ((True, False)) or else Calc.Visible ((True, True))",
            when others => "begin" & LF & "   if not Calc.Is_Leap (2000) or else Calc.Is_Leap (1900)"
              & " or else not Calc.Is_Leap (2024) or else Calc.Is_Leap (2023) or else not Calc.Is_Leap (2400)");
      procedure Put (Path, Text : String) is
      begin
         Project_Tools.Files.Write_Raw_File (Root & "/" & Path, Text & LF);
      end Put;
      Ran : Hostkit.Process.Process_Outcome;
      procedure Git (Args : Hostkit.String_Vectors.Vector) is
      begin
         Ran := Hostkit.Process.Run_Captured
           ("git", [To_Unbounded_String ("-C"), To_Unbounded_String (Root),
                    To_Unbounded_String ("-c"), To_Unbounded_String ("user.name=learning fixture"),
                    To_Unbounded_String ("-c"), To_Unbounded_String ("user.email=fixture@example.invalid")] & Args,
            Stdout_Path => Hostkit.Fs.Null_Device, Stderr_Path => Hostkit.Fs.Null_Device);
         if not Ran.Started or else Ran.Exit_Status /= 0 then
            raise Program_Error with "fixture git failed";
         end if;
      end Git;
   begin
      if Which > Families or else Ada.Directories.Exists (Root) then
         raise Program_Error with "new valid teaching fixture required";
      end if;
      Ada.Directories.Create_Path (Root & "/src");
      Ada.Directories.Create_Path (Root & "/obj");
      Put ("src/calc.ads", "package Calc is" & LF & Spec & LF & "   function Keep return Integer;" & LF & "end Calc;");
      Put ("src/calc.adb", "package body Calc is" & LF & Body_Text & LF
           & "   function Keep return Integer is (17);" & LF & "end Calc;");
      Put ("src/main.adb", "with Calc; procedure Main is begin if Calc.Keep /= 17 then"
           & " raise Program_Error; end if; end Main;");
      Put ("src/test_add.adb", "with Calc; procedure Test_Add is" & LF & Checks
           & " or else Calc.Keep /= 17 then raise Program_Error; end if; end Test_Add;");
      Put (".gitignore", "obj/*" & LF & "!obj/.gitkeep" & LF & ".model_runner/" & LF & ".trial-runtime/");
      Put ("obj/.gitkeep", "");
      Git ([To_Unbounded_String ("init"), To_Unbounded_String ("-q")]);
      Git ([To_Unbounded_String ("add"), To_Unbounded_String ("src"), To_Unbounded_String (".gitignore"),
            To_Unbounded_String ("obj/.gitkeep")]);
      Git ([To_Unbounded_String ("commit"), To_Unbounded_String ("-qm"), To_Unbounded_String ("teaching fixture")]);
   end Make_Project;
   procedure Validate (Root : String; Clean : out Boolean) is
   begin
      Clean := True;
      for Which in 1 .. Families loop
         for Reference in Boolean loop
            declare
               Path : constant String := Root & "/" & Family (Which) & "-" & Boolean'Image (Reference);
            begin
               Make_Project (Path, Which, Reference);
               Trial_Graders.Preserve (Path);
               if Trial_Graders.Verify (Path, "edit", "", "", True) /=
                 (if Reference then Agent_Trial.Passed else Agent_Trial.Failed)
               then
                  Clean := False;
               end if;
            end;
         end loop;
      end loop;
   end Validate;
end Learning_Curriculum;
