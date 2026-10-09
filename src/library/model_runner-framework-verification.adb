with Ada.Characters.Handling;
with Ada.Directories;
with Ada.Strings.Fixed;

with Hostkit.Fs;

with Model_Runner.Framework.Configurations;
with Model_Runner.Framework.Events;
with Model_Runner.Framework.Execution;
with Model_Runner.Framework.Intent;
with Model_Runner.Framework.Records;
with Model_Runner.Framework.Repository;
with Model_Runner.Framework.Results;
with Model_Runner.Framework.Schemas;
with Model_Runner.Framework.Tasks;
with Model_Runner.Framework.Traceability;
with Model_Runner.Framework.Transitions;
with Model_Runner.Framework.Workspaces;
with Model_Runner.Platform;

package body Model_Runner.Framework.Verification is
   use type Tasks.Core_State;

   use Ada.Strings.Unbounded;

   package E renames Model_Runner.Errors;

   Tab : constant Character := ASCII.HT;

   function Trim (Text : String) return String
   is (Ada.Strings.Fixed.Trim (Text, Ada.Strings.Both));

   function Image (Value : Natural) return String
   is (Trim (Natural'Image (Value)));

   function Lower (Text : String) return String
   renames Ada.Characters.Handling.To_Lower;

   function Starts (Text, Prefix : String) return Boolean
   is (Text'Length >= Prefix'Length
       and then Text (Text'First .. Text'First + Prefix'Length - 1) = Prefix);

   function Pad (Value : Natural; Width : Positive) return String is
      Plain : constant String := Image (Value);
   begin
      return [1 .. Integer'Max (0, Width - Plain'Length) => '0'] & Plain;
   end Pad;

   function Length (From : Check_List) return Natural
   is (Natural (From.Items.Length));

   function Length (From : Diagnostic_List) return Natural
   is (Natural (From.Items.Length));

   function Length (From : Gate_List) return Natural
   is (Natural (From.Items.Length));

   function Element (From : Check_List; Index : Positive) return Check
   is (From.Items (Index));

   function Element (From : Diagnostic_List; Index : Positive) return Diagnostic
   is (From.Items (Index));

   function Element (From : Gate_List; Index : Positive) return Gate
   is (From.Items (Index));

   function Config (Item : Stores.Store) return Records.Item is
   begin
      return Configurations.Required (Item);
   end Config;

   -------------------
   -- Parse_Profile --
   -------------------

   function Parse_Profile (Text : String) return Check_List is
      Result : Check_List;
      Start  : Natural := Text'First;
   begin
      for Index in Text'First .. Text'Last + 1 loop
         if Index > Text'Last or else Text (Index) in ';' | ASCII.LF then
            declare
               Part  : constant String := Trim (Text (Start .. Index - 1));
               Colon : constant Natural := Ada.Strings.Fixed.Index (Part, ":");
            begin
               if Part /= "" then
                  declare
                     Head    : constant String :=
                       (if Colon = 0 then "check" else Trim (Part (Part'First .. Colon - 1)));
                     Command : constant String :=
                       (if Colon = 0 then Part else Trim (Part (Colon + 1 .. Part'Last)));
                     Inside  : constant Natural := Ada.Strings.Fixed.Index (Head, " in ");
                     Written : constant String :=
                       (if Inside = 0 then Head else Trim (Head (Head'First .. Inside - 1)));
                     Optional : constant Boolean :=
                       Written'Length > 0 and then Written (Written'Last) = '?';
                     Bare    : constant String :=
                       (if Optional then Written (Written'First .. Written'Last - 1) else Written);
                     Opening : constant Natural := Ada.Strings.Fixed.Index (Bare, "[");
                     Named   : constant String :=
                       (if Opening > 0 and then Bare (Bare'Last) = ']'
                        then Trim (Bare (Bare'First .. Opening - 1)) else Bare);
                     Options : constant String :=
                       (if Opening > 0 and then Bare (Bare'Last) = ']'
                        then Bare (Opening + 1 .. Bare'Last - 1) else "");
                     Made    : Check :=
                       (Label     => To_Unbounded_String (Named),
                        Command   => To_Unbounded_String (Command),
                        Directory => To_Unbounded_String
                                       (if Inside = 0 then ""
                                        else Trim (Head (Inside + 4 .. Head'Last))),
                        Required  => not Optional,
                        others    => <>);
                     Start_Option : Natural := Options'First;
                  begin
                     for At_Index in Options'First .. Options'Last + 1 loop
                        if At_Index > Options'Last or else Options (At_Index) = ',' then
                           declare
                              Pair  : constant String := Trim (Options (Start_Option .. At_Index - 1));
                              Equal : constant Natural := Ada.Strings.Fixed.Index (Pair, "=");
                              Key   : constant String :=
                                (if Equal = 0 then Pair else Trim (Pair (Pair'First .. Equal - 1)));
                              Value : constant String :=
                                (if Equal = 0 then "" else Trim (Pair (Equal + 1 .. Pair'Last)));
                              Count : constant Natural :=
                                (if Value'Length in 1 .. 6
                                   and then (for all C of Value => C in '0' .. '9')
                                 then Natural'Value (Value) else 0);
                           begin
                              if Key = "timeout" then
                                 Made.Timeout := Count;
                              elsif Key = "retry" then
                                 Made.Retries := Count;
                              elsif Key = "severity" then
                                 Made.Warning := Value = "warning";
                              elsif Key = "keep" then
                                 Made.Keep_Whole := Value /= "summary";
                              end if;
                           end;
                           Start_Option := At_Index + 1;
                        end if;
                     end loop;
                     Result.Items.Append (Made);
                  end;
               end if;
            end;
            Start := Index + 1;
         end if;
      end loop;
      return Result;
   end Parse_Profile;

   ---------------
   -- Normalize --
   ---------------

   function Normalize
     (Tool    : String;
      Output  : String;
      Raw_Log : String := "") return Diagnostic_List
   is
      Result : Diagnostic_List;
      Line_Number : Natural := 0;

      --  A trailing [CODE], or error[CODE] at the front: the tool's name for
      --  what it says.
      function Code_In (Said : String) return String is
         Close : constant Natural := Ada.Strings.Fixed.Index (Said, "]", Ada.Strings.Backward);
         Open  : constant Natural :=
           (if Close = 0 then 0 else Ada.Strings.Fixed.Index (Said (Said'First .. Close), "[",
                                                             Ada.Strings.Backward));
      begin
         --  A code is a word: a bracketed list of a command's arguments is
         --  not one.
         if Open > 0 and then Close > Open + 1 and then Close - Open <= 25
           and then (for all C of Said (Open + 1 .. Close - 1) =>
                       C not in ' ' | '"' | ',')
         then
            return Said (Open + 1 .. Close - 1);
         end if;
         return "";
      end Code_In;

      --  The first name in double quotes, as GNAT quotes what it means.
      function Symbol_In (Said : String) return String is
         First : constant Natural := Ada.Strings.Fixed.Index (Said, """");
         Last  : constant Natural :=
           (if First = 0 then 0 else Ada.Strings.Fixed.Index (Said (First + 1 .. Said'Last), """"));
      begin
         if First > 0 and then Last > First + 1 then
            return Said (First + 1 .. Last - 1);
         end if;
         return "";
      end Symbol_In;

      --  The places it points at: at FILE:LINE, and at line N of the same
      --  file.
      function Related_In (Said : String; File : String) return String is
         Found : Unbounded_String;
         Index : Natural := Said'First;
      begin
         loop
            declare
               At_Mark : constant Natural :=
                 Ada.Strings.Fixed.Index (Said (Index .. Said'Last), " at ");
            begin
               exit when At_Mark = 0;
               declare
                  Rest  : constant String := Said (At_Mark + 4 .. Said'Last);
                  Space : constant Natural := Ada.Strings.Fixed.Index (Rest & " ", " ");
                  Place : constant String := Rest (Rest'First .. Space - 1);
               begin
                  if Starts (Rest, "line ") then
                     declare
                        After : constant String := Rest (Rest'First + 5 .. Rest'Last);
                        Stop  : Natural := After'First;
                     begin
                        while Stop <= After'Last and then After (Stop) in '0' .. '9' loop
                           Stop := Stop + 1;
                        end loop;
                        if Stop > After'First then
                           Append (Found, (if Found = Null_Unbounded_String then "" else ";")
                                   & File & ":" & After (After'First .. Stop - 1));
                        end if;
                     end;
                  elsif Ada.Strings.Fixed.Index (Place, ":") > Place'First
                    and then Place (Ada.Strings.Fixed.Index (Place, ":") + 1 .. Place'Last)'Length > 0
                    and then Place (Ada.Strings.Fixed.Index (Place, ":") + 1) in '0' .. '9'
                  then
                     Append (Found, (if Found = Null_Unbounded_String then "" else ";")
                             & Trim (Place));
                  end if;
                  Index := At_Mark + 4;
               end;
            end;
            exit when Index > Said'Last;
         end loop;
         return To_String (Found);
      end Related_In;

      --  A number at the front of a text, and what follows its colon.
      procedure Number
        (Text  : String;
         Value : out Natural;
         Rest  : out Natural)
      is
         Index : Natural := Text'First;
      begin
         Value := 0;
         Rest := 0;
         while Index <= Text'Last and then Text (Index) in '0' .. '9' loop
            if Value < 100_000_000 then
               Value := Value * 10 + (Character'Pos (Text (Index)) - Character'Pos ('0'));
            end if;
            Index := Index + 1;
         end loop;
         if Index > Text'First and then Index <= Text'Last and then Text (Index) = ':'
         then
            Rest := Index + 1;
         end if;
      end Number;

      --  Give the diagnostic before, found with no place, the place a
      --  line under it names: FILE:LINE, or FILE:LINE:COL.
      procedure Place_Last (Place : String) is
         Colon : constant Natural := Ada.Strings.Fixed.Index (Place, ":");
         At_Line, After_Line, At_Column, After_Column : Natural;
      begin
         if Result.Items.Is_Empty or else Result.Items.Last_Element.File /= Null_Unbounded_String
           or else Colon <= Place'First or else Colon = Place'Last
         then
            return;
         end if;
         Number (Place (Colon + 1 .. Place'Last) & ":", At_Line, After_Line);
         At_Column := 0;
         if After_Line > 0 and then After_Line <= Place'Last then
            Number (Place (After_Line .. Place'Last) & ":", At_Column, After_Column);
         end if;
         if At_Line > 0 then
            declare
               Last : Diagnostic := Result.Items.Last_Element;
            begin
               Last.File := To_Unbounded_String (Place (Place'First .. Colon - 1));
               Last.Line := At_Line;
               Last.Column := At_Column;
               Result.Items.Replace_Element (Result.Items.Last_Index, Last);
            end;
         end if;
      end Place_Last;

      procedure Found (File : String; Line, Column : Natural; Said : String) is
         Message  : constant String := Trim (Said);
         Severity : constant String :=
           (if Starts (Lower (Message), "warning:") or else Starts (Lower (Message), "warning ")
              or else Starts (Message, "(style)")
            then "warning"
            elsif Starts (Lower (Message), "note:") or else Starts (Lower (Message), "info:")
            then "note"
            else "error");
         Body_Text : constant String :=
           (if Starts (Lower (Message), "warning:") then Trim (Message (Message'First + 8 .. Message'Last))
            elsif Starts (Lower (Message), "error:") then Trim (Message (Message'First + 6 .. Message'Last))
            elsif Starts (Lower (Message), "note:") then Trim (Message (Message'First + 5 .. Message'Last))
            else Message);
      begin
         Result.Items.Append
           (Diagnostic'(Tool     => To_Unbounded_String (Tool),
                        Severity => To_Unbounded_String (Severity),
                        File     => To_Unbounded_String (File),
                        Line     => Line,
                        Column   => Column,
                        Message  => To_Unbounded_String (Body_Text),
                        Code     => To_Unbounded_String (Code_In (Message)),
                        Symbol   => To_Unbounded_String (Symbol_In (Message)),
                        Related  => To_Unbounded_String (Related_In (Message, File)),
                        Raw      => To_Unbounded_String
                          (if Raw_Log = "" then ""
                           else Raw_Log & ":" & Trim (Natural'Image (Line_Number)))));
      end Found;
   begin
      for Raw of Lines_Of (Output) loop
         Line_Number := Line_Number + 1;
         declare
            Line  : constant String := Trim (Raw);
            Colon : constant Natural := Ada.Strings.Fixed.Index (Line, ":");
         begin
            if Colon > Line'First and then Colon < Line'Last
              and then Line (Colon + 1) in '0' .. '9'
              and then Ada.Strings.Fixed.Index (Line (Line'First .. Colon - 1), " ") = 0
            then
               declare
                  At_Line, At_Column : Natural;
                  After_Line, After_Column : Natural;
               begin
                  Number (Line (Colon + 1 .. Line'Last), At_Line, After_Line);
                  if After_Line > 0 then
                     Number (Line (After_Line .. Line'Last), At_Column, After_Column);
                     if After_Column > 0 then
                        Found (Line (Line'First .. Colon - 1), At_Line, At_Column,
                               Line (After_Column .. Line'Last));
                     else
                        Found (Line (Line'First .. Colon - 1), At_Line, 0,
                               Line (After_Line .. Line'Last));
                     end if;
                  end if;
               end;
            elsif Starts (Lower (Line), "error:") or else Starts (Lower (Line), "warning:")
            then
               Found ("", 0, 0, Line);

            --  rustc: error[E0308]: what, then --> FILE:LINE:COL below it.
            elsif Starts (Lower (Line), "error[") or else Starts (Lower (Line), "warning[") then
               declare
                  Close : constant Natural := Ada.Strings.Fixed.Index (Line, "]:");
               begin
                  if Close > 0 then
                     Found ("", 0, 0,
                            Line (Line'First .. Ada.Strings.Fixed.Index (Line, "[") - 1) & ": "
                            & Trim (Line (Close + 2 .. Line'Last)) & " "
                            & Line (Ada.Strings.Fixed.Index (Line, "[") .. Close));
                  end if;
               end;
            elsif Starts (Line, "--> ") or else Starts (Line, "at ") then
               --  Where the one before it is: rustc's --> FILE:LINE:COL, and
               --  AUnit's "at FILE:LINE" under a failure.
               Place_Last (Trim (Line (Line'First + (if Starts (Line, "at ") then 3 else 4)
                                      .. Line'Last)));

            --  AUnit: FAIL or ERROR and the test's name; pytest: FAILED
            --  PATH::TEST - why.
            elsif Starts (Line, "FAIL ") or else Starts (Line, "ERROR ") then
               Found ("", 0, 0,
                      "error: " & Trim (Line (Ada.Strings.Fixed.Index (Line, " ") + 1 .. Line'Last)));
            elsif Starts (Line, "FAILED ") and then Ada.Strings.Fixed.Index (Line, "::") > 0 then
               declare
                  Rest : constant String := Trim (Line (Line'First + 7 .. Line'Last));
               begin
                  Found (Rest (Rest'First .. Ada.Strings.Fixed.Index (Rest, "::") - 1), 0, 0,
                         "error: " & Rest (Ada.Strings.Fixed.Index (Rest, "::") + 2 .. Rest'Last));
               end;

            --  MSVC and its kin: FILE(LINE) or FILE(LINE,COL): what.
            elsif Ada.Strings.Fixed.Index (Line, "): ") > 0
              and then Ada.Strings.Fixed.Index (Line, "(") in Line'First + 1 .. Ada.Strings.Fixed.Index (Line, "): ")
            then
               declare
                  Open  : constant Natural := Ada.Strings.Fixed.Index (Line, "(");
                  Close : constant Natural := Ada.Strings.Fixed.Index (Line, "): ");
                  Inner : constant String := Line (Open + 1 .. Close - 1);
                  Comma : constant Natural := Ada.Strings.Fixed.Index (Inner, ",");
                  At_Line, At_Column, Ignored : Natural;
               begin
                  if Inner'Length > 0 and then (for all C of Inner => C in '0' .. '9' | ',') then
                     Number ((if Comma = 0 then Inner else Inner (Inner'First .. Comma - 1)) & ":",
                             At_Line, Ignored);
                     At_Column := 0;
                     if Comma > 0 then
                        Number (Inner (Comma + 1 .. Inner'Last) & ":", At_Column, Ignored);
                     end if;
                     Found (Line (Line'First .. Open - 1), At_Line, At_Column,
                            Line (Close + 3 .. Line'Last));
                  end if;
               end;
            end if;
         end;
      end loop;
      return Result;
   end Normalize;

   ----------------
   -- Profile_Of --
   ----------------

   function Profile_Of (Item : Stores.Store; Task_Id : String) return String is
      Settings : constant Records.Item := Config (Item);
      Defined  : Records.Item;
      Status   : E.Error_Info;
   begin
      Tasks.Definition (Item, Task_Id, Defined, Status);
      if E.Is_Ok (Status) then
         declare
            By_Kind : constant String :=
              Records.Get (Settings, "scalar.task.profile." & Records.Get (Defined, "kind"));
         begin
            if By_Kind /= "" then
               return By_Kind;
            end if;
         end;
      end if;
      return Records.Get (Settings, "scalar.verification.default");
   end Profile_Of;

   --  What evidence is checked against: the files as they are now.
   function File_Lines (Files : Repository.Graph) return String;

   --  The files checks judge, as they are: a document's words change no
   --  build or test, so a README edited leaves evidence standing.
   function Repository_Now (Item : Stores.Store) return String
   is (Fingerprint (File_Lines (Repository.Now (Item))));

   --  What a program says its version is: the first line of its --version,
   --  run as any check is; "unknown" where it will not say.
   function Version_Of
     (Item    : Stores.Store;
      Change  : in out Stores.Transaction;
      Rules   : Execution.Policy;
      Program : String) return String
   is
      Asked  : Execution.Policy := Rules;
      Ran    : Execution.Outcome;
      Status : E.Error_Info;
   begin
      Asked.Timeout := Positive'Min (Rules.Timeout, 20);
      Asked.Keep_Whole := False;
      Execution.Run (Item, Change, Asked, Program & " --version", "", Ran, Status);
      if E.Is_Error (Status) or else not Ran.Started or else Ran.Exit_Status /= 0 then
         return "unknown";
      end if;
      declare
         Text : constant String := To_String (Ran.Output);
         Stop : constant Natural := Ada.Strings.Fixed.Index (Text, [1 => ASCII.LF]);
         Line : constant String :=
           Trim (if Stop = 0 then Text else Text (Text'First .. Stop - 1));
      begin
         return (if Line = "" then "unknown" else Line);
      end;
   end Version_Of;

   -----------------
   -- Run_Profile --
   -----------------

   procedure Run_Profile
     (Item     : Stores.Store;
      Change   : in out Stores.Transaction;
      Profile  : String;
      Task_Id  : String;
      Evidence : out Ada.Strings.Unbounded.Unbounded_String;
      Passed   : out Boolean;
      Status   : out Model_Runner.Errors.Error_Info;
      Given    : Name_Lists.Vector := Name_Lists.Empty_Vector;
      Stands_For : String := "";
      Offline  : Boolean := False;
      Workspace : String := "";
      Within   : Natural := 0)
   is
      Settings : constant Records.Item := Config (Item);
      Text     : constant String := Records.Get (Settings, "profile." & Profile);

      --  A check's text with each {NAME} given replaced by its value -- not
      --  ${NAME}, which a template fills in when the project is made.
      function Filled (Template : String) return String is
         Result : Unbounded_String := To_Unbounded_String (Template);
      begin
         for Pair of Given loop
            declare
               Equal : constant Natural := Ada.Strings.Fixed.Index (Pair, "=");
               Mark  : constant String := "{" & Pair (Pair'First .. Equal - 1) & "}";
               Value : constant String := Pair (Equal + 1 .. Pair'Last);
               At_Index : Natural := Index (Result, Mark);
            begin
               while At_Index > 0 loop
                  Replace_Slice (Result, At_Index, At_Index + Mark'Length - 1, Value);
                  At_Index := Index (Result, Mark, At_Index + Value'Length);
               end loop;
            end;
         end loop;
         return To_String (Result);
      end Filled;
      Checks   : constant Check_List := Parse_Profile (Text);
      Rules    : Execution.Policy := Execution.Policy_Of (Item);
      Number   : Natural;
      Diagnostics : Natural := 0;
      State    : Stores.State_Snapshot;
   begin
      Evidence := Null_Unbounded_String;
      Passed := False;
      Rules.No_Network := Rules.No_Network or else Offline;

      if Text = "" then
         Status := E.Make (E.Framework_Not_Found);
         E.Add_Text (Status, "name", "profile " & Profile);
         return;
      end if;

      Stores.Allocate_Number (Item, Change, "VER", "", Number, Status);
      if E.Is_Error (Status) then
         return;
      end if;
      Evidence := To_Unbounded_String ("VER-" & Pad (Number, 6));

      declare
         Value : Records.Item :=
           Records.Create (Schemas.Evidence_Schema, 1, To_String (Evidence), 1);
      begin
         Records.Set (Value, "task", Task_Id);
         Records.Set (Value, "profile", Profile);
         if Stands_For /= "" and then Stands_For /= Profile then
            Records.Set (Value, "stands_for", Stands_For);
         end if;
         for Pair of Given loop
            declare
               Equal : constant Natural := Ada.Strings.Fixed.Index (Pair, "=");
            begin
               if Equal > Pair'First and then Pair (Equal + 1 .. Pair'Last) /= "" then
                  Records.Set (Value, "given." & Pair (Pair'First .. Equal - 1),
                               Pair (Equal + 1 .. Pair'Last));
               end if;
            end;
         end loop;
         Records.Set (Value, "started_at", Timestamp);
         Records.Set (Value, "configuration_revision", Image (Records.Revision (Settings)));
         Records.Set
           (Value, "configuration_fingerprint",
            Records.Get (Settings, "configuration_fingerprint"));
         Records.Set
           (Value, "checks_fingerprint", Configurations.Verification_Fingerprint (Settings));
         Records.Set
           (Value, "environment_fingerprint",
            Fingerprint (Model_Runner.Platform.Passed_Environment
                           (To_String (Rules.Environment))));
         --  Each variable's own, so that a change is said by name.
         for Line of Lines_Of (Model_Runner.Platform.Passed_Environment (To_String (Rules.Environment)))
         loop
            declare
               Equal : constant Natural := Ada.Strings.Fixed.Index (Line, "=");
            begin
               if Equal > Line'First then
                  Records.Set (Value, "environment." & Line (Line'First .. Equal - 1),
                               Fingerprint (Line (Equal + 1 .. Line'Last)));
               end if;
            end;
         end loop;
         Records.Set (Value, "network", (if Rules.Network then "allowed" else "not allowed"));

         --  Evidence taken for a requirement itself names its revision.
         if Task_Id /= "" and then Stores.Exists (Item, Requirements_Area, Task_Id) then
            declare
               Held : Intent.Entity;
               Read : E.Error_Info;
            begin
               Intent.Read (Item, Intent.Requirement, Task_Id, Held, Read);
               if E.Is_Ok (Read) then
                  Records.Set (Value, "requirement." & Task_Id, Image (Held.Revision));
                  Records.Set (Value, "meaning." & Task_Id, To_String (Held.Meaning));
               end if;
            end;
         elsif Task_Id /= "" then
            declare
               View : Records.Item;
               Read : E.Error_Info;
            begin
               Tasks.Effective (Item, Task_Id, View, Read);
               Records.Set (Value, "generation", Records.Get (View, "runtime.generation"));
               for Requirement of Lines_Of (Records.Get (View, "definition.requirements")) loop
                  declare
                     Held : Intent.Entity;
                  begin
                     Intent.Read (Item, Intent.Requirement, Requirement, Held, Read);
                     if E.Is_Ok (Read) then
                        Records.Set (Value, "requirement." & Requirement,
                                     Image (Held.Revision));
                        Records.Set (Value, "meaning." & Requirement,
                                     To_String (Held.Meaning));
                     end if;

                     --  The specifications it is linked to, by what they mean.
                     for Relation in Intent.Link_Kind loop
                        for Target of Intent.Links (Item, Intent.Requirement, Requirement, Relation)
                        loop
                           if Starts (Target, "SPEC-") then
                              Intent.Read (Item, Intent.Specification, Target, Held, Read);
                              if E.Is_Ok (Read) then
                                 Records.Set (Value, "specification_meaning." & Target,
                                              To_String (Held.Meaning));
                              end if;
                           end if;
                        end loop;
                     end loop;
                  end;
               end loop;

               --  And the decisions that govern it, by what they mean.
               for Index in 1 .. Records.Field_Count (View) loop
                  declare
                     Field : constant String := Records.Field_Name (View, Index);
                     Held  : Intent.Entity;
                  begin
                     if Starts (Field, "decision.") then
                        Intent.Read (Item, Intent.Decision, Field (Field'First + 9 .. Field'Last),
                                     Held, Read);
                        if E.Is_Ok (Read) then
                           Records.Set (Value, "decision_meaning." & Field (Field'First + 9 .. Field'Last),
                                        To_String (Held.Meaning));
                        end if;
                     end if;
                  end;
               end loop;
            end;
         end if;

         --  What it was checked with: each program's version, as it says
         --  it, and the adapters the configuration names.
         declare
            Asked : Name_Lists.Vector;
         begin
            for Index in 1 .. Length (Checks) loop
               declare
                  Words : constant Name_Lists.Vector :=
                    Execution.Words_Of (To_String (Element (Checks, Index).Command));
               begin
                  if not Words.Is_Empty and then not Asked.Contains (Words.First_Element) then
                     Asked.Append (Words.First_Element);
                     Records.Set (Value, "tool." & Words.First_Element,
                                  Version_Of (Item, Change, Rules, Words.First_Element));
                  end if;
               end;
            end loop;
            for Index in 1 .. Records.Field_Count (Settings) loop
               declare
                  Field : constant String := Records.Field_Name (Settings, Index);
               begin
                  if Starts (Field, "adapter.") then
                     Records.Set (Value, Field, Records.Get (Settings, Field));

                     --  Its version: the adapters are the harness's own, so
                     --  theirs is the harness's.
                     Records.Set (Value, "adapter_version." & Field (Field'First + 8 .. Field'Last),
                                  Records.Get (Settings, Field) & " " & Model_Runner.Version);
                  end if;
               end;
            end loop;
            Records.Set (Value, "template_version", Records.Get (Settings, "template_version"));
            Records.Set (Value, "harness_version", Model_Runner.Version);
         end;

         --  The same checks, run a moment ago on the same files with the
         --  same configuration, environment and values: their result is
         --  this run's -- kept as that, naming the run it is -- not taken
         --  again. Several tasks completed at once run the suite once.
         if Workspace = "" then
            declare
               Now   : constant String := Repository_Now (Item);
               Names : constant Name_Lists.Vector := Stores.Names (Item, Verification_Area);
               Seen  : Natural := 0;
            begin
               for Position in reverse 1 .. Natural (Names.Length) loop
                  exit when Seen >= 20;
                  Seen := Seen + 1;
                  declare
                     Name  : constant String := Names (Position);
                     Id    : constant String :=
                       (if Name'Length > 4 and then Name (Name'Last - 3 .. Name'Last) = ".rec"
                        then Name (Name'First .. Name'Last - 4) else Name);
                     Prior : Records.Item;
                     Read  : E.Error_Info;
                     Same  : Boolean;

                     --  Whether a value given to the checks is one a command
                     --  names: one none names changes nothing they do.
                     function Used (Field : String) return Boolean is
                        Name : constant String := Field (Field'First + 6 .. Field'Last);
                     begin
                        return Name = "scope" or else (for some Index in 1 .. Length (Checks) =>
                                  Ada.Strings.Fixed.Index
                                    (To_String (Element (Checks, Index).Command), "${" & Name & "}") > 0);
                     end Used;
                  begin
                     Stores.Read (Item, Verification_Area, Id, Prior, Read);
                     Same := E.Is_Ok (Read)
                       and then Records.Get (Prior, "workspace") = ""
                       and then Records.Get (Prior, "state_changed") = ""
                       and then Records.Get (Prior, "passed") /= ""
                       and then Records.Get (Prior, "profile") = Profile
                       and then Records.Get (Prior, "repository_revision") = Now
                       and then Records.Get (Prior, "scope_files") = ""
                       and then (for all Field of Name_Lists.Vector'
                                   (["checks_fingerprint", "configuration_fingerprint",
                                     "environment_fingerprint", "network"]) =>
                                   Records.Get (Prior, Field) = Records.Get (Value, Field));
                     --  The same values given to its commands, none more.
                     if Same then
                        for Index in 1 .. Records.Field_Count (Prior) loop
                           if Starts (Records.Field_Name (Prior, Index), "given.")
                             and then Used (Records.Field_Name (Prior, Index))
                           then
                              Same := Same and then Records.Get (Value, Records.Field_Name (Prior, Index))
                                                    = Records.Get (Prior, Records.Field_Name (Prior, Index));
                           end if;
                        end loop;
                        for Index in 1 .. Records.Field_Count (Value) loop
                           if Starts (Records.Field_Name (Value, Index), "given.")
                             and then Used (Records.Field_Name (Value, Index))
                           then
                              Same := Same and then Records.Has (Prior, Records.Field_Name (Value, Index));
                           end if;
                        end loop;
                     end if;
                     if Same then
                        for Index in 1 .. Records.Field_Count (Prior) loop
                           declare
                              Field : constant String := Records.Field_Name (Prior, Index);
                           begin
                              if Starts (Field, "check.") or else Starts (Field, "parameters.")
                                or else Starts (Field, "diagnostic.") or else Starts (Field, "tool.")
                              then
                                 Records.Set (Value, Field, Records.Get (Prior, Field));
                              end if;
                           end;
                        end loop;
                        Passed := Records.Get (Prior, "passed") = "true";
                        Records.Set (Value, "reused_from", Id);
                        Records.Set (Value, "repository_revision", Now);
                        Records.Set (Value, "workspace_revision", Now);
                        Records.Set (Value, "passed", (if Passed then "true" else "false"));
                        Records.Set (Value, "ended_at", Timestamp);
                        Stores.Put (Change, Verification_Area, To_String (Evidence), Value);
                        return;
                     end if;
                  end;
               end loop;
            end;
         end if;

         Passed := True;
         Stores.Snapshot_State (Item, State);
         for Index in 1 .. Length (Checks) loop
            declare
               Next    : constant Check := Element (Checks, Index);
               Ran     : Execution.Outcome;
               Good    : Boolean := False;
               Tries   : Natural := 0;
               Program : constant Name_Lists.Vector :=
                 Execution.Words_Of (To_String (Next.Command));
               Own     : Execution.Policy := Rules;
               Event   : Unbounded_String;
            begin
               --  Its own deadline and keeping, and as many tries as it may
               --  have.
               if Next.Timeout > 0 then
                  Own.Timeout := Next.Timeout;
               end if;
               --  Not past the time the run has left.
               if Within > 0 then
                  Own.Timeout := Positive'Max (1, Natural'Min (Own.Timeout, Within));
               end if;
               Own.Keep_Whole := Next.Keep_Whole;
               loop
                  Tries := Tries + 1;
                  Execution.Run
                    (Item, Change, Own, Filled (To_String (Next.Command)),
                     Filled (To_String (Next.Directory)), Ran, Status, Base => Workspace);
                  if E.Is_Error (Status) then
                     return;
                  end if;

                  --  Stopped by whoever started it: not a failure of what
                  --  it checks, so nothing is judged and no evidence kept.
                  if Ran.Cancelled then
                     Evidence := Null_Unbounded_String;
                     Status := E.Make (E.Generation_Cancelled);
                     declare
                        Changed, Left : Name_Lists.Vector;
                        Said          : Unbounded_String;
                     begin
                        Stores.Restore_State (Item, State, Changed, Left);
                        for Path of Left loop
                           Append (Said, (if Said = Null_Unbounded_String then "" else ", ") & Path);
                        end loop;
                        E.Add_Text (Status, "detail", To_String (Next.Label) & " was cancelled"
                                    & (if Said = Null_Unbounded_String then ""
                                       else "; what it changed in the state could not all be put back: "
                                            & To_String (Said)));
                     end;
                     return;
                  end if;
                  Good := Ran.Started and then not Ran.Timed_Out and then Ran.Exit_Status = 0;
                  exit when Good or else Tries > Next.Retries;
               end loop;
               if Next.Required and then not Good and then not Next.Warning then
                  Passed := False;
               end if;

               Records.Set
                 (Value, "check." & Pad (Index, 4),
                  To_String (Next.Label) & Tab & To_String (Next.Command) & Tab
                  & Integer'Image (Ran.Exit_Status) & Tab & Image (Ran.Seconds) & Tab
                  & (if Good then "passed" elsif Ran.Timed_Out then "timed out"
                     else "failed")
                  & Tab & (if Next.Required then "required" else "optional")
                  & Tab & To_String (Ran.Raw_Log)
                  & Tab & (if Next.Warning then "warning" else "error")
                  & Tab & Image (Tries));
               Records.Set
                 (Value, "parameters." & Pad (Index, 4),
                  "command=" & Filled (To_String (Next.Command))
                  & ", directory=" & Filled (To_String (Next.Directory))
                  & ", timeout=" & Image (Own.Timeout)
                  & ", retry=" & Image (Next.Retries)
                  & ", keep=" & (if Next.Keep_Whole then "whole" else "summary"));

               --  What happened, as an event of its own: a build, or a test.
               Events.Emit
                 (Item, Change,
                  (if Ada.Strings.Fixed.Index
                        (Ada.Characters.Handling.To_Lower (To_String (Next.Label)), "build") > 0
                   then Events.Build_Completed
                   elsif Good then Events.Test_Completed
                   else Events.Test_Failed),
                  To_String (Evidence),
                  To_String (Next.Label) & (if Good then " passed" else " failed"),
                  Event, Status);
               if E.Is_Error (Status) then
                  return;
               end if;

               declare
                  Said : constant Diagnostic_List :=
                    Normalize ((if Program.Is_Empty then "" else Program.First_Element),
                               To_String (Ran.Output), To_String (Ran.Raw_Log));
               begin
                  for Place in 1 .. Length (Said) loop
                     declare
                        One : constant Diagnostic := Element (Said, Place);
                     begin
                        Diagnostics := Diagnostics + 1;
                        Records.Set
                          (Value, "diagnostic." & Pad (Diagnostics, 5),
                           To_String (One.Tool) & Tab & To_String (One.Severity) & Tab
                           & To_String (One.File) & Tab & Image (One.Line) & Tab
                           & Image (One.Column) & Tab & To_String (One.Message)
                           & Tab & To_String (One.Code) & Tab & To_String (One.Symbol)
                           & Tab & To_String (One.Related) & Tab & To_String (One.Raw));
                     end;
                  end loop;
               end;
            end;
         end loop;

         --  The project's state is not the checks' to change: what they
         --  changed is put back, and they did not pass.
         declare
            Changed, Left : Name_Lists.Vector;
            Named         : Unbounded_String;
         begin
            Stores.Restore_State (Item, State, Changed, Left);
            if not Changed.Is_Empty then
               Passed := False;
               for Path of Changed loop
                  Append (Named, (if Named = Null_Unbounded_String then "" else [1 => ASCII.LF])
                                 & Path);
               end loop;
               --  And what of it is still as the checks left it.
               for Path of Left loop
                  Append (Named, [1 => ASCII.LF] & "not put back: " & Path);
               end loop;
               Records.Set (Value, "state_changed", To_String (Named));
            end if;
         end;

         --  The files as the checks left them: a build writes sources of
         --  its own -- Alire's config/ is one -- and evidence taken before
         --  it would be out of date the moment it was recorded.
         Records.Set (Value, "repository_revision", Repository_Now (Item));
         Records.Set (Value, "files", File_Lines (Repository.Now (Item)));
         Records.Set
           (Value, "workspace_revision",
            (if Workspace = "" then Repository_Now (Item)
             else Repository.Graph_Fingerprint
                    (Repository.Scan (Workspace, Repository.Roots_Of (Item)))));
         if Workspace /= "" then
            Records.Set (Value, "workspace", Workspace);
         elsif Records.Get (Value, "given.scope") in "certain_tests" | "component_tests"
           and then Records.Get (Value, "given.tests") /= ""
         then
            --  Evidence for some tests stays current while what changes
            --  afterwards does not reach them: the files it was taken on.
            Records.Set (Value, "scope_files", File_Lines (Repository.Now (Item)));
         end if;
         Records.Set (Value, "passed", (if Passed then "true" else "false"));
         Records.Set (Value, "ended_at", Timestamp);
         Stores.Put (Change, Verification_Area, To_String (Evidence), Value);
      end;
   end Run_Profile;

   --------------------
   -- Diagnostics_Of --
   --------------------

   function Diagnostics_Of
     (Item     : Stores.Store;
      Evidence : String) return Diagnostic_List
   is
      Result : Diagnostic_List;
      Value  : Records.Item;
      Status : E.Error_Info;
      Files  : Repository.Graph;
      Loaded : Boolean := False;

      --  A file a tool named by its name alone, as the project's one file
      --  of that name where there is one: tests.adb is tests/src/tests.adb.
      function In_Project (Named : String) return String is
         Found : Unbounded_String;
         Count : Natural := 0;
      begin
         if Named = "" or else Ada.Strings.Fixed.Index (Named, "/") > 0 then
            return Named;
         end if;
         if not Loaded then
            Files := Repository.Now (Item);
            Loaded := True;
         end if;
         for Index in 1 .. Repository.File_Count (Files) loop
            declare
               Path : constant String := To_String (Repository.File_At (Files, Index).Path);
            begin
               if Path = Named
                 or else (Path'Length > Named'Length
                          and then Path (Path'Last - Named'Length .. Path'Last) = "/" & Named)
               then
                  Found := To_Unbounded_String (Path);
                  Count := Count + 1;
               end if;
            end;
         end loop;
         return (if Count = 1 then To_String (Found) else Named);
      end In_Project;
   begin
      Stores.Read (Item, Verification_Area, Evidence, Value, Status);
      if E.Is_Error (Status) then
         return Result;
      end if;
      for Index in 1 .. Records.Field_Count (Value) loop
         declare
            Field : constant String := Records.Field_Name (Value, Index);
         begin
            if Starts (Field, "diagnostic.") then
               declare
                  Text  : constant String := Records.Get (Value, Field);
                  Parts : Name_Lists.Vector;
                  Start : Natural := Text'First;
               begin
                  for Place in Text'First .. Text'Last + 1 loop
                     if Place > Text'Last or else Text (Place) = Tab then
                        Parts.Append (Text (Start .. Place - 1));
                        Start := Place + 1;
                     end if;
                  end loop;
                  --  Six fields as evidence first kept them, ten since. A
                  --  build tool's own summary -- "Command [...] failed",
                  --  "Build failed" -- is no diagnostic of the project's.
                  --  Nor is one said twice, as a tool that reports a
                  --  failure again in its summary says it.
                  if Natural (Parts.Length) in 6 | 10
                    and then not (Parts (3) = ""
                                  and then (Starts (Parts (6), "Command [")
                                            or else Starts (Parts (6), "Build failed")
                                            or else Starts (Parts (6), "Compilation failed")
                                            or else Starts (Parts (6), "compilation of")))
                    and then not (for some Held of Result.Items =>
                                    To_String (Held.File) = In_Project (Parts (3))
                                    and then Image (Held.Line) = Parts (4)
                                    and then To_String (Held.Message) = Parts (6))
                  then
                     Result.Items.Append
                       (Diagnostic'(Tool     => To_Unbounded_String (Parts (1)),
                                    Severity => To_Unbounded_String (Parts (2)),
                                    File     => To_Unbounded_String (In_Project (Parts (3))),
                                    Line     => Natural'Value (Parts (4)),
                                    Column   => Natural'Value (Parts (5)),
                                    Message  => To_Unbounded_String (Parts (6)),
                                    Code     => To_Unbounded_String
                                      (if Natural (Parts.Length) = 10 then Parts (7) else ""),
                                    Symbol   => To_Unbounded_String
                                      (if Natural (Parts.Length) = 10 then Parts (8) else ""),
                                    Related  => To_Unbounded_String
                                      (if Natural (Parts.Length) = 10 then Parts (9) else ""),
                                    Raw      => To_Unbounded_String
                                      (if Natural (Parts.Length) = 10 then Parts (10) else "")));
                  end if;
               end;
            end if;
         end;
      end loop;
      return Result;
   end Diagnostics_Of;

   --  The files as they are, one "FINGERPRINT<TAB>PATH" line each: what a
   --  scoped evidence is later compared with.
   function File_Lines (Files : Repository.Graph) return String is
      Result : Unbounded_String;
   begin
      for Index in 1 .. Repository.File_Count (Files) loop
         declare
            One : constant Repository.File_Entry := Repository.File_At (Files, Index);
         begin
            if Repository."/=" (One.Role, Repository.Documentation) then
               Append (Result, (if Result = Null_Unbounded_String then "" else [1 => ASCII.LF])
                               & To_String (One.Fingerprint) & Tab & To_String (One.Path));
            end if;
         end;
      end loop;
      return To_String (Result);
   end File_Lines;

   --  Whether evidence taken for some tests is untouched by what has
   --  changed since: it recorded the files as they were, and nothing that
   --  changed reaches any of its tests. A change that cannot be traced, or
   --  that reaches the whole suite, reaches them.
   function Outside_Scope (Item : Stores.Store; Value : Records.Item) return Boolean is
      use type Traceability.Scope;
      Recorded : constant Name_Lists.Vector := Lines_Of (Records.Get (Value, "scope_files"));
      Files    : constant Repository.Graph := Repository.Now (Item);
      Now      : constant Name_Lists.Vector := Lines_Of (File_Lines (Files));
      Tests    : Name_Lists.Vector;
      Changed  : Name_Lists.Vector;

      function Path_Of (Line : String) return String is
         Stop : constant Natural := Ada.Strings.Fixed.Index (Line, [1 => Tab]);
      begin
         return (if Stop = 0 then Line else Line (Stop + 1 .. Line'Last));
      end Path_Of;
   begin
      declare
         Given : constant String := Records.Get (Value, "given.tests");
         Start : Positive := Given'First;
      begin
         for Index in Given'Range loop
            if Given (Index) = ' ' or else Index = Given'Last then
               declare
                  Word : constant String :=
                    Given (Start .. (if Given (Index) = ' ' then Index - 1 else Index));
               begin
                  if Word /= "" then
                     Tests.Append (Word);
                  end if;
               end;
               Start := Index + 1;
            end if;
         end loop;
      end;
      if Recorded.Is_Empty or else Tests.Is_Empty then
         return False;
      end if;

      for Line of Now loop
         if not Recorded.Contains (Line) then
            Changed.Append (Path_Of (Line));
         end if;
      end loop;
      for Line of Recorded loop
         if not Now.Contains (Line) and then not Changed.Contains (Path_Of (Line)) then
            Changed.Append (Path_Of (Line));
         end if;
      end loop;
      if Changed.Is_Empty then
         return True;
      end if;

      declare
         Selected : constant Traceability.Selection :=
           Traceability.Select_Tests
             (Item, Traceability.Impact_Of (Traceability.Build (Item, Files), Changed));
      begin
         if Selected.Width = Traceability.Full_Suite then
            return False;
         end if;
         for Test of Selected.Tests loop
            if Tests.Contains (Test) then
               return False;
            end if;
         end loop;
      end;
      return True;
   end Outside_Scope;

   ----------------
   -- Why_Failed --
   ----------------

   function Why_Failed
     (Item     : Stores.Store;
      Evidence : String;
      Lines    : Positive := 6) return Name_Lists.Vector
   is
      Held   : Records.Item;
      Read   : E.Error_Info;
      Result : Name_Lists.Vector;
      Tails  : Name_Lists.Vector;

      function Split_On (Text : String; Separator : Character) return Name_Lists.Vector is
         Found : Name_Lists.Vector;
         Start : Natural := Text'First;
      begin
         for Index in Text'First .. Text'Last + 1 loop
            if Index > Text'Last or else Text (Index) = Separator then
               Found.Append (Text (Start .. Index - 1));
               Start := Index + 1;
            end if;
         end loop;
         return Found;
      end Split_On;

      function Last_Lines (Text : String) return String is
         Seen : Natural := 0;
      begin
         for Index in reverse Text'Range loop
            if Text (Index) = ASCII.LF and then Index < Text'Last then
               Seen := Seen + 1;
               if Seen = Lines then
                  return Text (Index + 1 .. Text'Last);
               end if;
            end if;
         end loop;
         return Text;
      end Last_Lines;
   begin
      Stores.Read (Item, Verification_Area, Evidence, Held, Read);
      if E.Is_Error (Read) then
         return Result;
      end if;
      for Index in 1 .. Records.Field_Count (Held) loop
         declare
            Field : constant String := Records.Field_Name (Held, Index);
            Parts : constant Name_Lists.Vector :=
              Split_On (Records.Get (Held, Field), ASCII.HT);
         begin
            if Field'Length > 6 and then Field (Field'First .. Field'First + 5) = "check."
              and then Natural (Parts.Length) >= 7
              and then Parts (5) /= "passed" and then Parts (6) = "required"
            then
               declare
                  Log  : Results.Result;
                  Got  : E.Error_Info;
                  Text : Unbounded_String :=
                    To_Unbounded_String
                      (Parts (1) & " (" & Parts (2) & ") " & Parts (5)
                       & (if Parts (5) = "failed" then ", ending with" & Parts (3) else "")
                       & "; its log is " & Parts (7));
               begin
                  Results.Read (Item, Parts (7), Log, Got);
                  if E.Is_Ok (Got) and then Length (Log.Payload) > 0 then
                     declare
                        Whole : constant String := To_String (Log.Payload);

                        --  The line that says what went wrong -- an error's
                        --  or an exception's -- where the ending does not.
                        function Cause return String is
                           Found : Unbounded_String;
                           Start : Positive := Whole'First;
                        begin
                           for At_Index in Whole'First .. Whole'Last + 1 loop
                              if At_Index > Whole'Last or else Whole (At_Index) = ASCII.LF then
                                 declare
                                    Line : constant String :=
                                      Ada.Strings.Fixed.Trim (Whole (Start .. At_Index - 1), Ada.Strings.Both);
                                 begin
                                    if Ada.Strings.Fixed.Index (Line, "Error:") > 0
                                      or else Ada.Strings.Fixed.Index (Line, "Exception:") > 0
                                      or else Ada.Strings.Fixed.Index (Line, "error:") > 0
                                      or else Ada.Strings.Fixed.Index (Line, "ERROR:") > 0
                                    then
                                       Found := To_Unbounded_String (Line);
                                    end if;
                                 end;
                                 Start := At_Index + 1;
                              end if;
                           end loop;
                           return To_String (Found);
                        end Cause;

                        Ending : constant String :=
                          Ada.Strings.Fixed.Trim (Last_Lines (Whole), Ada.Strings.Right);
                        Tail : constant String :=
                          (if Cause /= "" and then Ada.Strings.Fixed.Index (Ending, Cause) = 0
                           then Cause & ASCII.LF & "..." & ASCII.LF & Ending else Ending);
                     begin
                        --  The same ending as a check's above: said once.
                        if Tails.Contains (Tail) then
                           Append (Text, ", ending as the one above");
                        else
                           Tails.Append (Tail);
                           Append (Text, ":" & ASCII.LF & Tail);
                        end if;
                     end;
                  end if;
                  Result.Append (To_String (Text));
               end;
            end if;
         end;
      end loop;
      return Result;
   end Why_Failed;

   ----------------
   -- Is_Current --
   ----------------

   function Is_Current
     (Item          : Stores.Store;
      Evidence      : String;
      Reasons       : out Name_Lists.Vector;
      Configuration : String := "") return Boolean
   is
      Value    : Records.Item;
      Status   : E.Error_Info;
      Settings : constant Records.Item := Config (Item);
   begin
      Reasons.Clear;
      Stores.Read (Item, Verification_Area, Evidence, Value, Status);
      if E.Is_Error (Status) then
         Reasons.Append (Evidence & " is not there");
         return False;
      end if;

      if Records.Get (Value, "workspace") /= "" then
         Reasons.Append (Evidence & " was taken in a workspace, before its work was taken in");
      elsif Records.Get (Value, "repository_revision") /= Repository_Now (Item)
        and then not Outside_Scope (Item, Value)
      then
         --  Which, where the evidence kept the files it was taken on.
         declare
            Was     : constant Name_Lists.Vector := Lines_Of (Records.Get (Value, "files"));
            Now     : constant Name_Lists.Vector := Lines_Of (File_Lines (Repository.Now (Item)));
            Changed : Unbounded_String;
            Count   : Natural := 0;
            procedure Add (Line : String) is
               Stop : constant Natural := Ada.Strings.Fixed.Index (Line, [1 => Tab]);
               Path : constant String := (if Stop = 0 then Line else Line (Stop + 1 .. Line'Last));
            begin
               Count := Count + 1;
               if Count <= 5 and then Ada.Strings.Fixed.Index (To_String (Changed), Path) = 0 then
                  Append (Changed, (if Changed = Null_Unbounded_String then "" else ", ") & Path);
               end if;
            end Add;
         begin
            if not Was.Is_Empty then
               for Line of Now loop
                  if not Was.Contains (Line) then
                     Add (Line);
                  end if;
               end loop;
               for Line of Was loop
                  if not Now.Contains (Line) then
                     Add (Line);
                  end if;
               end loop;
            end if;
            Reasons.Append ("the files have changed since " & Evidence
                            & (if Changed = Null_Unbounded_String then ""
                               else ": " & To_String (Changed) & (if Count > 5 then " and others" else "")));
         end;
      end if;
      --  Only what bears on verification: a change of agent or of its
      --  permissions leaves evidence as it was.
      if Records.Get (Value, "checks_fingerprint") /= "" then
         if Records.Get (Value, "checks_fingerprint")
              /= (if Configuration /= "" then Configuration
                  else Configurations.Verification_Fingerprint (Settings))
         then
            Reasons.Append ("the configuration of its checks has changed since " & Evidence);
         end if;

      --  Taken before what bears on checks was told apart: held to nothing
      --  of the configuration, rather than to all of it.
      elsif Records.Get (Value, "verification_fingerprint") /= "" then
         null;
      elsif Records.Get (Value, "configuration_fingerprint")
              /= Records.Get (Settings, "configuration_fingerprint")
      then
         Reasons.Append ("the configuration has changed since " & Evidence);
      end if;

      --  The environment its checks were given, as it is passed now.
      declare
         Rules : constant Execution.Policy := Execution.Policy_Of (Item);
      begin
         if Records.Get (Value, "environment_fingerprint") /= ""
           and then Records.Get (Value, "environment_fingerprint")
                      /= Fingerprint (Model_Runner.Platform.Passed_Environment
                                        (To_String (Rules.Environment)))
         then
            --  Which of it, where the evidence says each.
            declare
               Differ : Unbounded_String;
               Now    : constant String :=
                 Model_Runner.Platform.Passed_Environment (To_String (Rules.Environment));
            begin
               for Line of Lines_Of (Now) loop
                  declare
                     Equal : constant Natural := Ada.Strings.Fixed.Index (Line, "=");
                  begin
                     if Equal > Line'First
                       and then Records.Has (Value, "environment." & Line (Line'First .. Equal - 1))
                       and then Records.Get (Value, "environment." & Line (Line'First .. Equal - 1))
                                  /= Fingerprint (Line (Equal + 1 .. Line'Last))
                     then
                        Append (Differ, (if Differ = Null_Unbounded_String then "" else ", ")
                                        & Line (Line'First .. Equal - 1));
                     end if;
                  end;
               end loop;
               Reasons.Append ("the environment its checks are given has changed since " & Evidence
                               & (if Differ = Null_Unbounded_String then ""
                                  else ": " & To_String (Differ) & " differs -- a session started"
                                       & " from another shell has its own"));
            end;
         end if;

         --  The tools, where the policy holds evidence to the toolchain it
         --  was taken with: each asked again, and any that answers
         --  differently makes it stale.
         if Records.Get (Settings, "scalar.verification.toolchain") = "strict" then
            declare
               Scratch : Stores.Transaction;
            begin
               for Index in 1 .. Records.Field_Count (Value) loop
                  declare
                     Field : constant String := Records.Field_Name (Value, Index);
                  begin
                     if Starts (Field, "tool.")
                       and then Version_Of (Item, Scratch, Rules, Field (Field'First + 5 .. Field'Last))
                                  /= Records.Get (Value, Field)
                     then
                        Reasons.Append (Field (Field'First + 5 .. Field'Last)
                                        & " has changed since " & Evidence);
                     end if;
                  end;
               end loop;
            end;
         end if;
      end;
      for Index in 1 .. Records.Field_Count (Value) loop
         declare
            Field : constant String := Records.Field_Name (Value, Index);
         begin
            if Starts (Field, "specification_meaning.") or else Starts (Field, "decision_meaning.")
            then
               declare
                  Cut  : constant Natural := Ada.Strings.Fixed.Index (Field, ".");
                  Id   : constant String := Field (Cut + 1 .. Field'Last);
                  Held : Intent.Entity;
                  Read : E.Error_Info;
               begin
                  Intent.Read (Item, (if Starts (Field, "decision_") then Intent.Decision
                                      else Intent.Specification), Id, Held, Read);
                  if E.Is_Error (Read)
                    or else To_String (Held.Meaning) /= Records.Get (Value, Field)
                  then
                     Reasons.Append (Id & " has changed its meaning since " & Evidence);
                  end if;
               end;
            elsif Starts (Field, "requirement.") then
               declare
                  Id   : constant String := Field (Field'First + 12 .. Field'Last);
                  Held : Intent.Entity;
                  Read : E.Error_Info;
               begin
                  Intent.Read (Item, Intent.Requirement, Id, Held, Read);
                  --  What matters is what it means: a move through its
                  --  lifecycle is a revision too, and changes nothing the
                  --  evidence was gathered against.
                  if E.Is_Error (Read)
                    or else To_String (Held.Meaning)
                            /= Records.Get (Value, "meaning." & Id)
                  then
                     Reasons.Append (Id & " has changed its meaning since " & Evidence);
                  end if;
               end;
            end if;
         end;
      end loop;
      return Reasons.Is_Empty;
   end Is_Current;

   ------------
   -- Latest --
   ------------

   function Latest
     (Item    : Stores.Store;
      Task_Id : String;
      Profile : String) return String
   is
      Result : Unbounded_String;
   begin
      for Name of Stores.Names (Item, Verification_Area) loop
         declare
            Value  : Records.Item;
            Status : E.Error_Info;
         begin
            Stores.Read (Item, Verification_Area, Name, Value, Status);
            if E.Is_Ok (Status) and then Records.Get (Value, "task") = Task_Id
              and then (Records.Get (Value, "profile") = Profile
                        or else Records.Get (Value, "stands_for") = Profile)
            then
               Result := To_Unbounded_String (Name);
            end if;
         end;
      end loop;
      return To_String (Result);
   end Latest;

   ------------
   -- Choose --
   ------------

   function Choose
     (Item    : Stores.Store;
      Task_Id : String;
      Changed : Name_Lists.Vector) return Choice
   is
      use type Traceability.Scope;
      Result    : Choice;
      Settings  : constant Records.Item := Config (Item);
      Own       : constant String := Profile_Of (Item, Task_Id);
      Defined   : Records.Item;
      Read      : E.Error_Info;
      Selected  : Traceability.Selection;
      Tests     : Unbounded_String;
   begin
      Tasks.Definition (Item, Task_Id, Defined, Read);
      if Changed.Is_Empty then
         Selected :=
           (Width  => Traceability.Full_Suite,
            Reason => To_Unbounded_String ("nothing it changed can be traced"),
            others => <>);
      else
         declare
            Graph   : constant Traceability.Graph :=
              Traceability.Build (Item, Repository.Now (Item));
         begin
            Selected := Traceability.Select_Tests
              (Item, Traceability.Impact_Of (Graph, Changed));
         end;
      end if;

      declare
         Width : constant String :=
           (case Selected.Width is
              when Traceability.Certain_Tests   => "certain",
              when Traceability.Component_Tests => "component",
              when Traceability.Full_Suite      => "full");
         Kind  : constant String := Records.Get (Defined, "kind");
         Named : constant String :=
           (if Width = "full" then ""
            elsif Records.Get (Settings, "scalar.verification.scope." & Kind & "." & Width) /= ""
            then Records.Get (Settings, "scalar.verification.scope." & Kind & "." & Width)
            else Records.Get (Settings, "scalar.verification.scope." & Width));
      begin
         Result.Scope := To_Unbounded_String
           (case Selected.Width is
              when Traceability.Certain_Tests   => "certain_tests",
              when Traceability.Component_Tests => "component_tests",
              when Traceability.Full_Suite      => "full_suite");
         Result.Reason := Selected.Reason;
         if Named /= "" and then Records.Get (Settings, "profile." & Named) /= "" then
            Result.Profile := To_Unbounded_String (Named);
            Result.Stands_For := To_Unbounded_String (Own);
         else
            Result.Profile := To_Unbounded_String (Own);
            --  Nothing narrower to run: what runs is the whole suite, and
            --  said as that.
            if Width /= "full" then
               Result.Scope := To_Unbounded_String ("full_suite");
               Result.Reason := To_Unbounded_String
                 ("no narrower profile is configured, so "
                  & (if Own = "" then "none" else Own) & " runs whole");
            end if;
         end if;
      end;

      for Test of Selected.Tests loop
         Append (Tests, (if Tests = Null_Unbounded_String then "" else " ") & Test);
      end loop;
      Result.Given.Append ("tests=" & To_String (Tests));
      Result.Given.Append ("scope=" & To_String (Result.Scope));
      Result.Given.Append ("component=" & Records.Get (Defined, "component"));
      Result.Given.Append ("reason=" & To_String (Result.Reason));
      return Result;
   end Choose;

   -----------
   -- Gates --
   -----------

   function Gates (Item : Stores.Store; Task_Id : String) return Gate_List is
      Result   : Gate_List;
      Defined  : Records.Item;
      Read     : E.Error_Info;

      procedure Judge (Name : String; Passed : Boolean; Reason : String) is
      begin
         Result.Items.Append
           (Gate'(Name   => To_Unbounded_String (Name),
                  Passed => Passed,
                  Reason => To_Unbounded_String (if Passed then "" else Reason)));
      end Judge;
      --  The files the task's work changed, as the harness saw them -- and
      --  its completed children's: work split among them is its work.
      function Changed_Files return Name_Lists.Vector is
         Result : Name_Lists.Vector;

         procedure Gather (Id : String) is
            State  : Records.Item;
            Status : E.Error_Info;
         begin
            Stores.Read (Item, Tasks_Area, Id & ".state", State, Status);
            for Path of Lines_Of (Records.Get (State, "changed_files")) loop
               if not Result.Contains (Path) then
                  Result.Append (Path);
               end if;
            end loop;
         end Gather;
      begin
         Gather (Task_Id);
         for Child of Tasks.Children (Item, Task_Id) loop
            if Tasks.State_Of (Item, Child) = "complete" then
               Gather (Child);
            end if;
         end loop;
         return Result;
      end Changed_Files;

      Changed : constant Name_Lists.Vector := Changed_Files;
   begin
      Tasks.Definition (Item, Task_Id, Defined, Read);
      for Name of Tasks.Gate_Names (Item, Records.Get (Defined, "kind")) loop
         if Name = "verification" then
            declare
               Profile  : constant String := Profile_Of (Item, Task_Id);
               Evidence : constant String :=
                 (if Profile = "" then "" else Latest (Item, Task_Id, Profile));
               Value    : Records.Item;
               Status   : E.Error_Info;
               Reasons  : Name_Lists.Vector;
            begin
               if Profile = "" then
                  Judge (Name, False, "no verification profile applies to it");
               elsif Evidence = "" then
                  Judge (Name, False, "profile " & Profile & " has not been run for it");
               else
                  Stores.Read (Item, Verification_Area, Evidence, Value, Status);
                  if Records.Get (Value, "passed") /= "true" then
                     Judge (Name, False, Evidence & " did not pass");
                  elsif not Is_Current (Item, Evidence, Reasons) then
                     Judge (Name, False, Reasons.First_Element);
                  else
                     Judge (Name, True, "");
                  end if;
               end if;
            end;
         elsif Name = "children" then
            declare
               Open : Unbounded_String;
            begin
               for Child of Tasks.Children (Item, Task_Id) loop
                  if Tasks.Holds_Parent (Item, Child, Tasks.State_Of (Item, Child)) then
                     Append (Open, (if Open = Null_Unbounded_String then "" else ", ") & Child);
                  end if;
               end loop;
               Judge (Name, Open = Null_Unbounded_String,
                      "these parts are not done: " & To_String (Open));
            end;
         elsif Name = "no_blocking_issue" then
            declare
               Value  : Records.Item;
               Status : E.Error_Info;
            begin
               Stores.Read (Item, Tasks_Area, Task_Id & ".state", Value, Status);
               Judge (Name, E.Is_Ok (Status) and then Records.Get (Value, "blocking_reasons") = "",
                      "it is blocked: " & Records.Get (Value, "blocking_reasons"));
            end;
         elsif Name = "integration" then
            declare
               Open : constant String := Workspaces.Active_For (Item, Task_Id);
            begin
               Judge (Name, Open = "", Open & " has not been taken into the project");
            end;
         elsif Name = "implementation_present" then
            Judge (Name, not Changed.Is_Empty, "its work changed no file");
         elsif Name = "traceability_sufficient" then
            --  Each requirement it serves reaches something that implements
            --  or tests it: a link of its own, or the files this task changed.
            declare
               Loose : Unbounded_String;
            begin
               for Requirement of Lines_Of (Records.Get (Defined, "requirements")) loop
                  if Changed.Is_Empty
                    and then Intent.Links (Item, Intent.Requirement, Requirement,
                                           Intent.Implementation).Is_Empty
                    and then Intent.Links (Item, Intent.Requirement, Requirement,
                                           Intent.Test).Is_Empty
                  then
                     Append (Loose, (if Loose = Null_Unbounded_String then "" else ", ")
                             & Requirement);
                  end if;
               end loop;
               Judge (Name, Loose = Null_Unbounded_String,
                      "nothing traces " & To_String (Loose)
                      & " to what implements or tests it");
            end;
         elsif Name = "documentation_current" then
            --  Source changed goes with documentation changed.
            declare
               use type Repository.File_Role;
               Source_Changed : Boolean := False;
               Docs_Changed   : Boolean := False;
               Roots          : constant Repository.Roots := Repository.Roots_Of (Item);
            begin
               for Path of Changed loop
                  Source_Changed := Source_Changed
                    or else Repository.Role_Of (Path, Roots) = Repository.Source;
                  Docs_Changed := Docs_Changed
                    or else Repository.Role_Of (Path, Roots) = Repository.Documentation;
               end loop;
               Judge (Name, not Source_Changed or else Docs_Changed,
                      "its work changed source and no documentation");
            end;
         elsif Records.Get (Config (Item), "scalar.gate." & Name) /= "" then
            --  A gate the project defines: a profile that has passed, for
            --  this task, and still applies.
            declare
               Profile  : constant String := Records.Get (Config (Item), "scalar.gate." & Name);
               Evidence : constant String := Latest (Item, Task_Id, Profile);
               Value    : Records.Item;
               Status   : E.Error_Info;
               Reasons  : Name_Lists.Vector;
            begin
               if Evidence = "" then
                  Judge (Name, False, "profile " & Profile & " has not been run for it");
               else
                  Stores.Read (Item, Verification_Area, Evidence, Value, Status);
                  if Records.Get (Value, "passed") /= "true" then
                     Judge (Name, False, Evidence & " did not pass");
                  elsif not Is_Current (Item, Evidence, Reasons) then
                     Judge (Name, False, Reasons.First_Element);
                  else
                     Judge (Name, True, "");
                  end if;
               end if;
            end;
         else
            Judge (Name, False, "no gate is called " & Name);
         end if;
      end loop;
      return Result;
   end Gates;

   -------------------
   -- Complete_Task --
   -------------------

   procedure Complete_Task
     (Item    : Stores.Store;
      Change  : in out Stores.Transaction;
      Task_Id : String;
      Status  : out Model_Runner.Errors.Error_Info)
   is
      Judged : constant Gate_List := Gates (Item, Task_Id);
      Failed : Unbounded_String;
      Defined : Records.Item;
      Was     : constant String := Tasks.State_Of (Item, Task_Id);
      By_Hand : constant Boolean := Was in "accepted" | "failed" | "blocked";
   begin
      for Next of Judged.Items loop
         --  A person completing a blocked task sets its block aside.
         --  A person completing it sets aside a block, and vouches for the
         --  work being there.
         if not Next.Passed
           and then not (Was = "blocked" and then To_String (Next.Name) = "no_blocking_issue")
           and then not (By_Hand and then To_String (Next.Name) = "implementation_present")
         then
            Append (Failed, (if Failed = Null_Unbounded_String then "" else "; ")
                            & To_String (Next.Name) & ": " & To_String (Next.Reason));
         end if;
      end loop;
      if Failed /= Null_Unbounded_String then
         Status := E.Make (E.Framework_Task_Not_Ready);
         E.Add_Text (Status, "name", Task_Id);
         E.Add_Text (Status, "detail", To_String (Failed));
         return;
      end if;

      --  Done by hand: the generation the harness would have run, recorded
      --  as what it was.
      if By_Hand then
         if Was /= "accepted" then
            Tasks.Move (Item, Change, Task_Id, "accepted", "completed by hand",
                        Status => Status, Actor => Transitions.User);
         end if;
         if E.Is_Ok (Status) or else Was = "accepted" then
            Tasks.Move (Item, Change, Task_Id, "running", "completed by hand", Status => Status);
         end if;
         if E.Is_Ok (Status) then
            Tasks.Move (Item, Change, Task_Id, "verification", "completed by hand",
                        Status => Status);
         end if;
         if E.Is_Error (Status) then
            return;
         end if;
      end if;

      Tasks.Move (Item, Change, Task_Id, "complete", "", Gates_Passed => True,
                  Status => Status);
      if E.Is_Error (Status) then
         return;
      end if;

      --  What it was completed on, and what a person set aside for it: the
      --  evidence its verification gate judged, and the gates it did not
      --  pass that completing it by hand set aside.
      declare
         Held      : Records.Item;
         Staged    : Boolean;
         Set_Aside : Unbounded_String;
         Profile   : constant String := Profile_Of (Item, Task_Id);
         Evidence  : constant String :=
           (if Profile = "" then "" else Latest (Item, Task_Id, Profile));
      begin
         --  Work given up with its workspace is none of what completes it:
         --  what it changed and took in is set aside with the rest.
         declare
            State_Now : Records.Item;
            Read      : E.Error_Info;
            Given_Up  : Boolean := False;
         begin
            Stores.Read (Item, Tasks_Area, Task_Id & ".state", State_Now, Read);
            Given_Up := By_Hand and then E.Is_Ok (Read)
              and then Records.Get (State_Now, "current_workspace") /= ""
              and then Workspaces.Active_For (Item, Task_Id) = "";
            for Next of Judged.Items loop
               if not Next.Passed
                 or else (Given_Up
                          and then To_String (Next.Name) in "implementation_present" | "integration")
               then
                  Append (Set_Aside, (if Set_Aside = Null_Unbounded_String then "" else ASCII.LF & "")
                                     & To_String (Next.Name));
               end if;
            end loop;
         end;
         Stores.Pending (Change, Tasks_Area, Task_Id & ".state", Held, Staged);
         if Staged then
            if Evidence /= "" then
               Records.Set (Held, "current_verification", Evidence);
            end if;
            if By_Hand then
               Records.Set (Held, "completed_by", "hand");
            end if;
            if Set_Aside /= Null_Unbounded_String then
               Records.Set (Held, "set_aside", To_String (Set_Aside));
            end if;
            Stores.Put (Change, Tasks_Area, Task_Id & ".state", Held);
         end if;
      end;

      --  The requirements it served are implemented once every task serving
      --  them is complete -- this one now; whether they are verified is
      --  worked out from evidence, not from this.
      Tasks.Definition (Item, Task_Id, Defined, Status);
      for Requirement of Lines_Of (Records.Get (Defined, "requirements")) loop
         declare
            Held : Intent.Entity;
            Read : E.Error_Info;
            Open : Boolean := False;
         begin
            for Other of Tasks.List (Item) loop
               if Other /= Task_Id
                 and then Tasks.State_Of (Item, Other) not in "complete" | "cancelled" | "rejected"
               then
                  declare
                     Its : Records.Item;
                     Got : E.Error_Info;
                  begin
                     Tasks.Definition (Item, Other, Its, Got);
                     Open := Open or else
                       (E.Is_Ok (Got)
                        and then Lines_Of (Records.Get (Its, "requirements")).Contains (Requirement));
                  end;
               end if;
            end loop;
            Intent.Read (Item, Intent.Requirement, Requirement, Held, Read);
            if E.Is_Ok (Read) and then To_String (Held.State) = "accepted" and then not Open then
               Intent.Move (Item, Change, Intent.Requirement, Requirement, "implemented",
                            Transitions.Ordinary_Only, Status);
               if E.Is_Error (Status) then
                  return;
               end if;
            end if;
         end;
      end loop;
      Status := E.Success;
   end Complete_Task;

   ------------------------
   -- Verify_Requirement --
   ------------------------

   --  The profile a requirement itself is verified by: the project's
   --  for requirements, or its default where it names none.
   function Requirement_Profile (Item : Stores.Store) return String is
      Named : constant String := Records.Get (Config (Item), "scalar.verification.requirements");
   begin
      return (if Named /= "" then Named else Records.Get (Config (Item), "scalar.verification.default"));
   end Requirement_Profile;

   procedure Verify_Requirement
     (Item        : Stores.Store;
      Change      : in out Stores.Transaction;
      Requirement : String;
      Evidence    : out Ada.Strings.Unbounded.Unbounded_String;
      Passed      : out Boolean;
      Status      : out Model_Runner.Errors.Error_Info)
   is
      Profile : constant String := Requirement_Profile (Item);
      Given   : Name_Lists.Vector;
      Tests   : Unbounded_String;
   begin
      Evidence := Null_Unbounded_String;
      Passed := False;
      if Profile = "" then
         Status := E.Make (E.Framework_Input_Missing);
         E.Add_Text (Status, "name", "a profile to verify requirements by: /reconfigure"
                     & " scalar.verification.requirements=PROFILE names one, or"
                     & " scalar.verification.default a profile for everything");
         return;
      elsif not Stores.Exists (Item, Requirements_Area, Requirement) then
         Status := E.Make (E.Framework_Not_Found);
         E.Add_Text (Status, "name", Requirement);
         return;
      end if;
      for Test of Intent.Links (Item, Intent.Requirement, Requirement, Intent.Test) loop
         Append (Tests, (if Tests = Null_Unbounded_String then "" else " ") & Test);
      end loop;
      Given.Append ("requirement=" & Requirement);
      Given.Append ("tests=" & To_String (Tests));
      Run_Profile (Item, Change, Profile, Requirement, Evidence, Passed, Status, Given => Given);
   end Verify_Requirement;

   -----------------------------
   -- Reevaluate_Requirements --
   -----------------------------

   --  Whether a piece of evidence ran tests: taken by a profile whose
   --  capability is to run them, and with no check's log saying none ran.
   --  What a piece of evidence says of tests: ran some, ran a runner that
   --  found none (and the log saying so), or was no test run at all.
   type Test_Showing is (Tests_Ran, Found_None, Not_Tests);

   Last_Empty_Log : Unbounded_String;

   function Ran_Tests (Item : Stores.Store; Value : Records.Item) return Boolean;

   function Showing (Item : Stores.Store; Value : Records.Item) return Test_Showing is
      Capable : constant String :=
        Records.Get (Config (Item), "scalar.profile_capability." & Records.Get (Value, "profile"));
   begin
      if Capable /= "run_tests" then
         return Not_Tests;
      end if;
      return (if Ran_Tests (Item, Value) then Tests_Ran else Found_None);
   end Showing;

   function Ran_Tests (Item : Stores.Store; Value : Records.Item) return Boolean is
      Profile : constant String := Records.Get (Value, "profile");
      Capable : constant String :=
        Records.Get (Config (Item), "scalar.profile_capability." & Profile);
   begin
      if Capable /= "run_tests" then
         return False;
      end if;
      for Index in 1 .. Records.Field_Count (Value) loop
         declare
            Field : constant String := Records.Field_Name (Value, Index);
            Line  : constant String := Records.Get (Value, Field);
            Last  : constant Natural := Ada.Strings.Fixed.Index (Line, "RES-", Ada.Strings.Backward);
         begin
            if Starts (Field, "check.") and then Last > 0 then
               declare
                  Stop : Natural := Last;
                  Log  : Results.Result;
                  Got  : E.Error_Info;
               begin
                  while Stop < Line'Last and then Line (Stop + 1) /= Tab loop
                     Stop := Stop + 1;
                  end loop;
                  Results.Read (Item, Line (Last .. Stop), Log, Got);
                  if E.Is_Ok (Got) then
                     declare
                        Said : constant String :=
                          Ada.Characters.Handling.To_Lower (To_String (Log.Payload));
                     begin
                        --  What the common runners say when there was
                        --  nothing to run.
                        if Ada.Strings.Fixed.Index (Said, "total tests run:   0") > 0
                          or else Ada.Strings.Fixed.Index (Said, "total tests run: 0") > 0
                          or else Ada.Strings.Fixed.Index (Said, "collected 0 items") > 0
                          or else Ada.Strings.Fixed.Index (Said, "no tests ran") > 0
                          or else Ada.Strings.Fixed.Index (Said, "no tests were found") > 0
                        then
                           Last_Empty_Log := To_Unbounded_String (Line (Last .. Stop));
                           return False;
                        end if;
                     end;
                  end if;
               end;
            end if;
         end;
      end loop;
      return True;
   end Ran_Tests;

   --------------------
   -- Found_No_Tests --
   --------------------

   function Found_No_Tests (Item : Stores.Store; Evidence : String) return Boolean is
      Value : Records.Item;
      Read  : E.Error_Info;
   begin
      Stores.Read (Item, Verification_Area, Evidence, Value, Read);
      return E.Is_Ok (Read) and then Showing (Item, Value) = Found_None;
   end Found_No_Tests;

   -------------
   -- Support --
   -------------

   function Support
     (Item          : Stores.Store;
      Requirement   : String;
      Configuration : String;
      Why           : out Unbounded_String) return String
   is
      Everything : constant Name_Lists.Vector := Tasks.List (Item);

      --  The profile the project verifies requirements themselves by.
      Policy_Profile : constant String :=
        Records.Get (Config (Item), "scalar.verification.requirements");

      --  Nothing, with why.
      function Lacks (Text : String) return String is
      begin
         Why := To_Unbounded_String (Text);
         return "";
      end Lacks;

      --  Whether evidence shows each acceptance criterion that says how it
      --  is shown -- a criterion ending [check: LABEL] names the check whose
      --  passing shows it -- by that check having passed in it.
      function Criteria_Shown (Requirement : String; Value : Records.Item) return Boolean is
         Held : Intent.Entity;
         Read : E.Error_Info;
      begin
         Intent.Read (Item, Intent.Requirement, Requirement, Held, Read);
         for Criterion of Lines_Of (To_String (Held.Criteria)) loop
            declare
               Mark  : constant Natural := Ada.Strings.Fixed.Index (Criterion, "[check:");
               Close : constant Natural := Ada.Strings.Fixed.Index (Criterion, "]", Ada.Strings.Backward);
            begin
               if Mark > 0 and then Close > Mark then
                  declare
                     Label  : constant String := Trim (Criterion (Mark + 7 .. Close - 1));
                     Passed : Boolean := False;
                  begin
                     for Index in 1 .. Records.Field_Count (Value) loop
                        declare
                           Field : constant String := Records.Field_Name (Value, Index);
                           Line  : constant String := Records.Get (Value, Field);
                           Tab_1 : constant Natural := Ada.Strings.Fixed.Index (Line, [1 => Tab]);
                        begin
                           Passed := Passed
                             or else (Starts (Field, "check.") and then Tab_1 > Line'First
                                      and then Line (Line'First .. Tab_1 - 1) = Label
                                      and then Ada.Strings.Fixed.Index
                                                 (Line, Tab & "passed" & Tab) > 0);
                        end;
                     end loop;
                     if not Passed then
                        return False;
                     end if;
                  end;
               end if;
            end;
         end loop;
         return True;
      end Criteria_Shown;

      --  The latest current, passing evidence of any complete task
      --  serving it that ran tests: taken over the project as it is now,
      --  it stands for the earlier tasks' evidence the later work made
      --  stale -- a test task's run over the implementation it tests.
      function Standing_Evidence return String is
         Best : Unbounded_String;
      begin
         for Id of Everything loop
            declare
               Defined : Records.Item;
               Read    : E.Error_Info;
            begin
               Tasks.Definition (Item, Id, Defined, Read);
               if E.Is_Ok (Read)
                 and then Lines_Of (Records.Get (Defined, "requirements")).Contains (Requirement)
                 and then Tasks.State_Of (Item, Id) = "complete"
               then
                  declare
                     Evidence : constant String := Latest (Item, Id, Profile_Of (Item, Id));
                     Value    : Records.Item;
                     Reasons  : Name_Lists.Vector;
                  begin
                     if Evidence /= "" then
                        Stores.Read (Item, Verification_Area, Evidence, Value, Read);
                        if E.Is_Ok (Read) and then Records.Get (Value, "passed") = "true"
                          and then Is_Current (Item, Evidence, Reasons, Configuration)
                          and then Showing (Item, Value) = Tests_Ran
                          and then (Best = Null_Unbounded_String or else Evidence > To_String (Best))
                        then
                           Best := To_Unbounded_String (Evidence);
                        end if;
                     end if;
                  end;
               end if;
            end;
         end loop;
         return To_String (Best);
      end Standing_Evidence;

      --  The latest current run of the project's tests taken for no task
      --  -- check full -- whether it passed or not: a passing one stands
      --  for stale task evidence as a serving task's does; a failing one
      --  says the tests do not pass on the files as they are.
      Project_Passed : Unbounded_String;
      Project_Failed : Unbounded_String;
      --  The latest whole-suite run passed and ran no test: an empty suite.
      Project_Empty  : Unbounded_String;
      Empty_Run      : Boolean := False;

      procedure Find_Project_Runs is
         Latest  : Unbounded_String;
         Good    : Boolean := False;
         Reasons : Name_Lists.Vector;
      begin
         --  The newest only: what an older one was run on is older still.
         for Name of Stores.Names (Item, Verification_Area) loop
            declare
               Value   : Records.Item;
               Read    : E.Error_Info;
               Id      : constant String :=
                 (if Name'Length > 4 and then Name (Name'Last - 3 .. Name'Last) = ".rec"
                  then Name (Name'First .. Name'Last - 4) else Name);
            begin
               if Latest = Null_Unbounded_String or else Id > To_String (Latest) then
                  Stores.Read (Item, Verification_Area, Id, Value, Read);
                  --  A run of the whole suite: for no task, or chosen so,
                  --  or run with no tests picked out -- task verify and a
                  --  requirement's check among them.
                  if E.Is_Ok (Read)
                    and then (Records.Get (Value, "task") = ""
                              or else Records.Get (Value, "given.scope") = "full_suite"
                              or else Records.Get (Value, "given.tests") = "")
                    and then Records.Get (Value, "workspace") = ""
                    and then Records.Get (Config (Item), "scalar.profile_capability."
                                                         & Records.Get (Value, "profile"))
                             = "run_tests"
                  then
                     Latest := To_Unbounded_String (Id);
                     Good := Records.Get (Value, "passed") = "true"
                       and then Showing (Item, Value) = Tests_Ran;
                     Empty_Run := Records.Get (Value, "passed") = "true"
                       and then Showing (Item, Value) = Found_None;
                  end if;
               end if;
            end;
         end loop;
         if Latest /= Null_Unbounded_String
           and then not Is_Current (Item, To_String (Latest), Reasons, Configuration)
         then
            Latest := Null_Unbounded_String;
         end if;
         if Latest /= Null_Unbounded_String then
            if Good then
               Project_Passed := Latest;
            elsif Empty_Run then
               Project_Empty := Latest;
            else
               Project_Failed := Latest;
            end if;
         end if;
      end Find_Project_Runs;

      Standing_Of_Tasks : constant String := Standing_Evidence;
      Standing : Unbounded_String := To_Unbounded_String (Standing_Of_Tasks);
      Stood_For : Boolean := False;

      Found : Unbounded_String;
      Any   : Boolean := False;
      Tested : Boolean := False;
      Empty_Suite : Unbounded_String;
      --  Something implements it: a linked file the project holds -- a
      --  link to one it does not shows nothing.
      --  A linked symbol counts where the repository's graph holds it.
      function Linked_Here return Boolean is
         Links : constant Name_Lists.Vector :=
           Intent.Links (Item, Intent.Requirement, Requirement, Intent.Implementation);
      begin
         if (for some Target of Links =>
               Ada.Directories.Exists
                 (Hostkit.Fs.Join (Ada.Directories.Containing_Directory (Stores.Root (Item)), Target)))
         then
            return True;
         end if;
         for Target of Links loop
            if Ada.Strings.Fixed.Index (Target, "/") = 0
              and then Repository.Find_Symbols (Repository.Now (Item), Target).Contains (Target)
            then
               return True;
            end if;
         end loop;
         return False;
      end Linked_Here;
      Built : Boolean := Linked_Here;
      --  Whether what a run failed on lies wholly outside this
      --  requirement's files -- those linked to it as implementing or
      --  testing it, and those the work serving it changed -- as the run
      --  names them: then the failure is another's, not this one's.
      function Failed_Elsewhere (Evidence : String) return Boolean is
         Own     : Name_Lists.Vector;
         Failing : Name_Lists.Vector;
         Found   : constant Diagnostic_List := Diagnostics_Of (Item, Evidence);
      begin
         for Kind in Intent.Implementation .. Intent.Test loop
            if Kind in Intent.Implementation | Intent.Test then
               for Target of Intent.Links (Item, Intent.Requirement, Requirement, Kind) loop
                  Own.Append (Target);
               end loop;
            end if;
         end loop;
         for Id of Everything loop
            declare
               Defined : Records.Item;
               State   : Records.Item;
               Got     : E.Error_Info;
            begin
               Tasks.Definition (Item, Id, Defined, Got);
               if E.Is_Ok (Got)
                 and then Lines_Of (Records.Get (Defined, "requirements")).Contains (Requirement)
               then
                  Stores.Read (Item, Tasks_Area, Id & ".state", State, Got);
                  if E.Is_Ok (Got) then
                     for Path of Lines_Of (Records.Get (State, "changed_files")) loop
                        Own.Append (Path);
                     end loop;
                  end if;
               end if;
            end;
         end loop;
         for Index in 1 .. Length (Found) loop
            if Length (Element (Found, Index).File) > 0 then
               Failing.Append (To_String (Element (Found, Index).File));
            end if;
         end loop;
         return not Own.Is_Empty and then not Failing.Is_Empty
           and then Natural (Failing.Length) = Length (Found)
           and then (for all Path of Failing =>
                       not (for some Mine of Own =>
                              Path = Mine
                              or else (Path'Length > Mine'Length
                                       and then Path (Path'Last - Mine'Length + 1 .. Path'Last) = Mine)
                              or else (Mine'Length > Path'Length
                                       and then Mine (Mine'Last - Path'Length + 1 .. Mine'Last) = Path)));
      end Failed_Elsewhere;

      --  Whether a task serves the requirement.
      function Serves_It (Id : String) return Boolean is
         Defined : Records.Item;
         Read    : E.Error_Info;
      begin
         Tasks.Definition (Item, Id, Defined, Read);
         return E.Is_Ok (Read) and then Lines_Of (Records.Get (Defined, "requirements")).Contains (Requirement);
      end Serves_It;

      --  A task serving it that failed, and how it is tried again: what a
      --  failed run of the suite does not say.
      function Failed_Server return String is
      begin
         for Id of Everything loop
            if Tasks.State_Of (Item, Id) = "failed" and then Serves_It (Id) then
               return "; " & Id & ", which serves it, failed: /task accept " & Id & " tries it again";
            end if;
         end loop;
         return "";
      end Failed_Server;
   begin
      Find_Project_Runs;
      --  Served only by tasks let go: that first, with how one comes back.
      if (for some Id of Everything => Serves_It (Id))
        and then (for all Id of Everything =>
                    not Serves_It (Id) or else Tasks.State_Of (Item, Id) in "cancelled" | "rejected")
      then
         for Id of Everything loop
            if Serves_It (Id) then
               return Lacks (Id & ", the task that serves it, was " & Tasks.State_Of (Item, Id) & ": /task "
                             & (if Tasks.State_Of (Item, Id) = "rejected" then "reconsider " else "reopen ")
                             & Id & " takes it back, or /task new TITLE kind=KIND requirements=" & Requirement
                             & " makes another");
            end if;
         end loop;
      end if;
      --  A suite that ran nothing passed nothing: said as that, with the
      --  way on -- a test that shows it -- not as a failure to fix.
      --  Work still open for it is the reason first: its task undone says
      --  more than a suite that has nothing to run yet.
      if Project_Empty /= Null_Unbounded_String and then Standing_Of_Tasks = ""
        and then not (for some Id of Everything =>
                        Tasks.State_Of (Item, Id) not in "complete" | "cancelled" | "rejected"
                        and then Serves_It (Id))
      then
         return Lacks (To_String (Project_Empty) & ", the latest run of the project's whole suite,"
                       & " passed and ran no test: the suite is empty"
                       --  A test linked already: it runs with the suite.
                       & (if not Intent.Links (Item, Intent.Requirement, Requirement, Intent.Test).Is_Empty
                          then "; its linked test is not in what the suite runs yet -- add it to the suite, then"
                               & " /check full"
                          --  A candidate is accepted first: work for it waits until then.
                          elsif Intent.State_Of (Item, Intent.Requirement, Requirement) = "candidate"
                          then "; it is a candidate -- /req accept " & Requirement & " first, then /task new TITLE"
                               & " kind=test requirements=" & Requirement & " writes a test that shows it"
                          else "; /task new TITLE kind=test requirements=" & Requirement & " writes a test that"
                               & " shows it, /req link " & Requirement & " test FILE ties one there is, then"
                               & " /check full"));
      end if;
      if Project_Failed /= Null_Unbounded_String then
         declare
            Value  : Records.Item;
            Read   : E.Error_Info;
            For_Task : Unbounded_String;
            Serves : Unbounded_String;
            Served : Name_Lists.Vector;
            Elsewhere : Boolean := False;
         begin
            Stores.Read (Item, Verification_Area, To_String (Project_Failed), Value, Read);
            if E.Is_Ok (Read) then
               For_Task := To_Unbounded_String (Records.Get (Value, "task"));
            end if;
            if For_Task /= Null_Unbounded_String then
               declare
                  Defined : Records.Item;
               begin
                  Tasks.Definition (Item, To_String (For_Task), Defined, Read);
                  if E.Is_Ok (Read) then
                     Served := Lines_Of (Records.Get (Defined, "requirements"));
                     for One of Served loop
                        Append (Serves, (if Serves = Null_Unbounded_String then "" else ", ") & One);
                     end loop;
                  end if;
               end;
            end if;
            --  What failed, where the run says where: when none of it is a
            --  file of this requirement's, the run stands for it as a passing
            --  one would, its own tests having passed in it.
            if Failed_Elsewhere (To_String (Project_Failed)) then
               Elsewhere := True;
               Standing := Project_Failed;
            end if;
            if Elsewhere then
               null;
            else
               return Lacks (To_String (Project_Failed) & ", the latest run of the project's whole"
                             & " suite on the files as they are"
                             & (if For_Task = Null_Unbounded_String then ""
                                else " (for " & To_String (For_Task)
                                     & (if Serves = Null_Unbounded_String then ""
                                        else ", which serves " & To_String (Serves)) & ")")
                             & ", did not pass; fix what failed, then /check full"
                             & Failed_Server);
            end if;
         end;
      end if;
      if Project_Passed /= Null_Unbounded_String
        and then (Standing = Null_Unbounded_String or else Project_Passed > Standing)
      then
         Standing := Project_Passed;
      end if;
      for Id of Everything loop
         declare
            Defined : Records.Item;
            Read    : E.Error_Info;
            State   : constant String := Tasks.State_Of (Item, Id);
         begin
            Tasks.Definition (Item, Id, Defined, Read);
            if E.Is_Ok (Read)
              and then Lines_Of (Records.Get (Defined, "requirements")).Contains (Requirement)
              and then State not in "cancelled" | "rejected"
            then
               Any := True;
               if State /= Tasks.Complete then
                  --  The way on first -- the work done -- and taking what is
                  --  there as done only after, for code written already.
                  return Lacks (Id & " serves it and "
                                & (if State = Tasks.Failed then "has failed" else "is " & State)
                                & "; it is verified once that is complete"
                                & (if State = Tasks.Candidate
                                   then ": /task accept " & Id & ", then /work " & Id & " does it"
                                   elsif State = Tasks.Failed
                                   then ": /task accept " & Id & " tries it again"
                                   elsif State in "accepted" | "blocked"
                                   then ": /work " & Id & " does it"
                                   else "")
                                & (if State in "accepted" | "blocked" | "failed" | "candidate"
                                   then " (or, for code that is there already, /task complete " & Id
                                        & " takes it as done, its checks passing)"
                                   else ""));
               end if;

               --  Something implements it: a linked implementation, or
               --  files a task serving it changed.
               declare
                  Runtime_Value : Records.Item;
                  Got           : E.Error_Info;
               begin
                  Stores.Read (Item, Tasks_Area, Id & ".state", Runtime_Value, Got);
                  Built := Built
                    or else (E.Is_Ok (Got)
                             and then Records.Get (Runtime_Value, "changed_files") /= "");
               end;
               declare
                  Evidence : constant String :=
                    Latest (Item, Id, Profile_Of (Item, Id));
                  Value    : Records.Item;
                  Reasons  : Name_Lists.Vector;
               begin
                  if Evidence = "" then
                     return Lacks (Id & " has no evidence; /task verify " & Id & " takes it");
                  end if;
                  Stores.Read (Item, Verification_Area, Evidence, Value, Read);
                  --  Stale or failed, and a later whole run passed over the
                  --  files as they are: that stands for it.
                  if Standing /= Null_Unbounded_String and then To_String (Standing) > Evidence
                    and then (not Is_Current (Item, Evidence, Reasons, Configuration)
                              or else Records.Get (Value, "passed") /= "true")
                  then
                     --  Stale, and stood for by later evidence over it.
                     Stood_For := True;
                     goto Next_Task;
                  end if;
                  if Records.Get (Value, "passed") /= "true"
                    and then Failed_Elsewhere (Evidence)
                    and then Is_Current (Item, Evidence, Reasons, Configuration)
                  then
                     --  Failed only on another's files: its own tests passed.
                     Tested := True;
                     Append (Found, (if Found = Null_Unbounded_String then "" else ", ") & Evidence);
                     goto Next_Task;
                  elsif Records.Get (Value, "passed") /= "true" then
                     return Lacks (Evidence & ", " & Id & "'s latest, did not pass;"
                                   & " /task verify " & Id & " takes it again");
                  elsif not Is_Current (Item, Evidence, Reasons, Configuration) then
                     return Lacks (Evidence & ", " & Id & "'s latest, no longer applies"
                                   & (if Reasons.Is_Empty then ""
                                      else ": " & Reasons.First_Element)
                                   & "; /task verify " & Id & " takes it again");
                  elsif not Criteria_Shown (Requirement, Value) then
                     return Lacks (Evidence & " does not show a criterion's named check"
                                   & " passing");
                  end if;
                  case Showing (Item, Value) is
                     when Tests_Ran  => Tested := True;
                     when Found_None => Empty_Suite := Last_Empty_Log;
                     when Not_Tests  => null;
                  end case;
                  Append (Found, (if Found = Null_Unbounded_String then "" else ", ")
                                 & Evidence);
               end;
            end if;
         end;
         <<Next_Task>>
      end loop;
      if Stood_For then
         Tested := True;
         if Ada.Strings.Fixed.Index (To_String (Found), To_String (Standing)) = 0 then
            Append (Found, (if Found = Null_Unbounded_String then "" else ", ")
                           & To_String (Standing));
         end if;
      end if;
      if not Any then
         return Lacks ("no task serves it");
      elsif not Built then
         --  Linked to a file that is gone: that said, not that none is linked.
         for Target of Intent.Links (Item, Intent.Requirement, Requirement, Intent.Implementation) loop
            if Ada.Strings.Fixed.Index (Target, "/") > 0
              and then not Ada.Directories.Exists
                             (Hostkit.Fs.Join (Ada.Directories.Containing_Directory (Stores.Root (Item)), Target))
            then
               return Lacks ("its linked implementation " & Target & " is gone: /scan shows where it went, and /req"
                             & " link " & Requirement & " implementation FILE follows it, /req unlink "
                             & Requirement & " implementation " & Target & " taking the old one off");
            end if;
         end loop;
         return Lacks ("no implementation is known for it: no task serving it changed a file, and no"
                       & " file is linked as its implementation; where the code is there already, /req link "
                       & Requirement & " implementation FILE names it, and /check " & Requirement
                       & " then judges it");
      end if;

      --  Where the project verifies requirements themselves, by its
      --  profile: that evidence, current and passing, as well.
      if Policy_Profile /= "" then
         declare
            Own     : constant String := Latest (Item, Requirement, Policy_Profile);
            Value   : Records.Item;
            Read    : E.Error_Info;
            Reasons : Name_Lists.Vector;
         begin
            if Own = "" then
               return Lacks ("the project verifies requirements by " & Policy_Profile
                             & ", which has not been run for it");
            end if;
            Stores.Read (Item, Verification_Area, Own, Value, Read);
            if Records.Get (Value, "passed") /= "true"
              or else not Is_Current (Item, Own, Reasons, Configuration)
            then
               return Lacks (Own & ", its own verification, did not pass or no longer"
                             & " applies");
            end if;
            case Showing (Item, Value) is
               when Tests_Ran  => Tested := True;
               when Found_None => Empty_Suite := Last_Empty_Log;
               when Not_Tests  => null;
            end case;
            Append (Found, ", " & Own);
         end;
      end if;
      --  A build, or a suite that ran nothing, shows it is there, not
      --  that it does what it says.
      if not Tested and then Empty_Suite /= Null_Unbounded_String then
         return Lacks ("its tests ran and found none to run (" & To_String (Empty_Suite)
                       & "): a test that exercises it -- /task new TITLE kind=test"
                       & " requirements=" & Requirement & " -- then check "
                       & Requirement & " verifies it");
      elsif not Tested then
         return Lacks ("no evidence for it ran tests: a build shows it is there, not that it"
                       & " does what it says; check " & Requirement & " runs the tests of the"
                       & " tasks serving it, where their kind's profile runs tests"
                       & " (profile_capability run_tests)");
      end if;
      Why := Null_Unbounded_String;
      return To_String (Found);
   end Support;

   ------------------
   -- Passed_After --
   ------------------

   function Passed_After (Item : Stores.Store; Evidence : String) return Boolean is
   begin
      for Name of Stores.Names (Item, Verification_Area) loop
         declare
            Id    : constant String :=
              (if Name'Length > 4 and then Name (Name'Last - 3 .. Name'Last) = ".rec"
               then Name (Name'First .. Name'Last - 4) else Name);
            Value : Records.Item;
            Read  : E.Error_Info;
         begin
            if Id > Evidence then
               Stores.Read (Item, Verification_Area, Id, Value, Read);
               if E.Is_Ok (Read) and then Records.Get (Value, "passed") = "true"
                 and then Records.Get (Value, "workspace") = ""
                 and then (Records.Get (Value, "task") = ""
                           or else Records.Get (Value, "given.scope") = "full_suite"
                           or else Records.Get (Value, "given.tests") = "")
                 and then Showing (Item, Value) = Tests_Ran
               then
                  return True;
               end if;
            end if;
         end;
      end loop;
      return False;
   end Passed_After;

   ----------------------
   -- Why_Not_Verified --
   ----------------------

   function Why_Not_Verified (Item : Stores.Store; Requirement : String) return String is
      Why     : Unbounded_String;
      Ignored : constant String := Support (Item, Requirement, "", Why);
      pragma Unreferenced (Ignored);
   begin
      return To_String (Why);
   end Why_Not_Verified;

   procedure Reevaluate_Requirements
     (Item    : Stores.Store;
      Change  : in out Stores.Transaction;
      Changed : out Name_Lists.Vector;
      Status  : out Model_Runner.Errors.Error_Info;
      Configuration : String := "")
   is
      Everything : constant Name_Lists.Vector := Tasks.List (Item);

      function Supporting (Requirement : String) return String is
         Why : Unbounded_String;
      begin
         return Support (Item, Requirement, Configuration, Why);
      end Supporting;

      Event : Unbounded_String;
   begin
      Changed.Clear;
      Status := E.Success;

      --  An accepted requirement every task serving it has completed is
      --  implemented -- come back from blocked, say, after they did.
      for Requirement of Intent.List (Item, Intent.Requirement, "accepted") loop
         declare
            --  Done while the requirement meant something else: a task that
            --  completed before a revision changed what it says.
            function Done_For_Other_Words (Id : String) return Boolean is
               Runtime_Value : Records.Item;
               Got           : E.Error_Info;
               Held          : Intent.Entity;
            begin
               Stores.Read (Item, Tasks_Area, Id & ".state", Runtime_Value, Got);
               Intent.Read (Item, Intent.Requirement, Requirement, Held, Got);
               return Records.Get (Runtime_Value, "served." & Requirement) /= ""
                 and then Records.Get (Runtime_Value, "served." & Requirement)
                            /= To_String (Held.Meaning);
            end Done_For_Other_Words;

            Serving : Natural := 0;
            Open    : Boolean := False;
         begin
            for Id of Everything loop
               declare
                  Defined : Records.Item;
                  Read    : E.Error_Info;
                  State   : constant String := Tasks.State_Of (Item, Id);
               begin
                  Tasks.Definition (Item, Id, Defined, Read);
                  if E.Is_Ok (Read)
                    and then Lines_Of (Records.Get (Defined, "requirements")).Contains (Requirement)
                    and then State not in "cancelled" | "rejected"
                  then
                     Serving := Serving + 1;
                     Open := Open or else State /= Tasks.Complete or else Done_For_Other_Words (Id);
                  end if;
               end;
            end loop;
            if Serving > 0 and then not Open then
               Intent.Move (Item, Change, Intent.Requirement, Requirement, "implemented",
                            Transitions.Ordinary_Only, Status);
               if E.Is_Error (Status) then
                  return;
               end if;
               Changed.Append (Requirement);
            end if;
         end;
      end loop;

      for Requirement of Intent.List (Item, Intent.Requirement, "implemented") loop
         declare
            Evidence : constant String := Supporting (Requirement);
            Value    : Records.Item;
            Staged   : Boolean;
         begin
            if Evidence /= "" then
               Intent.Move (Item, Change, Intent.Requirement, Requirement, "verified",
                            Transitions.Ordinary_Only, Status);
               if E.Is_Error (Status) then
                  return;
               end if;
               Stores.Pending (Change, Requirements_Area, Requirement, Value, Staged);
               Records.Set (Value, "verified_by", Evidence);
               Stores.Put (Change, Requirements_Area, Requirement, Value);
               Changed.Append (Requirement);
            end if;
         end;
      end loop;

      for Requirement of Intent.List (Item, Intent.Requirement, "verified") loop
         if Supporting (Requirement) = "" then
            Intent.Move (Item, Change, Intent.Requirement, Requirement, "implemented",
                         [Transitions.Ordinary => True, Transitions.Invalidation => True,
                          others => False],
                         Status);
            if E.Is_Ok (Status) then
               Events.Emit
                 (Item, Change, Events.Requirement_Verification_Invalidated,
                  Requirement, "its evidence no longer applies", Event, Status);
            end if;
            if E.Is_Error (Status) then
               return;
            end if;
            Changed.Append (Requirement);
         end if;
      end loop;
   end Reevaluate_Requirements;

end Model_Runner.Framework.Verification;
