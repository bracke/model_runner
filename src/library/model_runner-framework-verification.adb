with Ada.Characters.Handling;
with Ada.Strings.Fixed;

with Model_Runner.Framework.Configurations;
with Model_Runner.Framework.Events;
with Model_Runner.Framework.Execution;
with Model_Runner.Framework.Intent;
with Model_Runner.Framework.Records;
with Model_Runner.Framework.Repository;
with Model_Runner.Framework.Schemas;
with Model_Runner.Framework.Tasks;
with Model_Runner.Framework.Traceability;
with Model_Runner.Framework.Transitions;
with Model_Runner.Framework.Workspaces;
with Model_Runner.Platform;

package body Model_Runner.Framework.Verification is

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
      Value  : Records.Item;
      Status : E.Error_Info;
   begin
      Configurations.Read (Item, Value, Status);
      return (if E.Is_Ok (Status) then Value else Records.Create ("", 1, "", 0));
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

      procedure Found (File : String; Line, Column : Natural; Said : String) is
         Message  : constant String := Trim (Said);
         Severity : constant String :=
           (if Starts (Lower (Message), "warning:") or else Starts (Message, "(style)")
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
   function Repository_Now (Item : Stores.Store) return String
   is (Repository.Graph_Fingerprint
         (Repository.Now (Item)));

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
      Offline  : Boolean := False)
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
           (Value, "environment_fingerprint",
            Fingerprint (Model_Runner.Platform.Passed_Environment
                           (To_String (Rules.Environment))));
         Records.Set (Value, "network", (if Rules.Network then "allowed" else "not allowed"));

         if Task_Id /= "" then
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
                  end if;
               end;
            end loop;
            Records.Set (Value, "template_version", Records.Get (Settings, "template_version"));
         end;

         Passed := True;
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
               Own.Keep_Whole := Next.Keep_Whole;
               loop
                  Tries := Tries + 1;
                  Execution.Run
                    (Item, Change, Own, Filled (To_String (Next.Command)),
                     Filled (To_String (Next.Directory)), Ran, Status);
                  if E.Is_Error (Status) then
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

         --  The files as the checks left them: a build writes sources of
         --  its own -- Alire's config/ is one -- and evidence taken before
         --  it would be out of date the moment it was recorded.
         Records.Set (Value, "repository_revision", Repository_Now (Item));
         Records.Set (Value, "workspace_revision", Repository_Now (Item));
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
                  --  Six fields as evidence first kept them, ten since.
                  if Natural (Parts.Length) in 6 | 10 then
                     Result.Items.Append
                       (Diagnostic'(Tool     => To_Unbounded_String (Parts (1)),
                                    Severity => To_Unbounded_String (Parts (2)),
                                    File     => To_Unbounded_String (Parts (3)),
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

      if Records.Get (Value, "repository_revision") /= Repository_Now (Item) then
         Reasons.Append ("the files have changed since " & Evidence);
      end if;
      if Records.Get (Value, "configuration_fingerprint")
           /= (if Configuration /= "" then Configuration
               else Records.Get (Settings, "configuration_fingerprint"))
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
            Reasons.Append ("the environment has changed since " & Evidence);
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
            if Starts (Field, "requirement.") then
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
            if Width /= "full" then
               Append (Result.Reason, "; no narrower profile is configured, so "
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
      --  The files the task's work changed, as the harness saw them.
      function Changed_Files return Name_Lists.Vector is
         State  : Records.Item;
         Status : E.Error_Info;
      begin
         Stores.Read (Item, Tasks_Area, Task_Id & ".state", State, Status);
         return Lines_Of (Records.Get (State, "changed_files"));
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
                  if Tasks.State_Of (Item, Child) not in "complete" | "cancelled" then
                     Append (Open, (if Open = Null_Unbounded_String then "" else ", ") & Child);
                  end if;
               end loop;
               Judge (Name, Open = Null_Unbounded_String,
                      "these children are not done: " & To_String (Open));
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
   begin
      for Next of Judged.Items loop
         if not Next.Passed then
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

      Tasks.Move (Item, Change, Task_Id, "complete", "", Gates_Passed => True,
                  Status => Status);
      if E.Is_Error (Status) then
         return;
      end if;

      --  The requirements it served are implemented now; whether they are
      --  verified is worked out from evidence, not from this.
      Tasks.Definition (Item, Task_Id, Defined, Status);
      for Requirement of Lines_Of (Records.Get (Defined, "requirements")) loop
         declare
            Held : Intent.Entity;
            Read : E.Error_Info;
         begin
            Intent.Read (Item, Intent.Requirement, Requirement, Held, Read);
            if E.Is_Ok (Read) and then To_String (Held.State) = "accepted" then
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

   -----------------------------
   -- Reevaluate_Requirements --
   -----------------------------

   procedure Reevaluate_Requirements
     (Item    : Stores.Store;
      Change  : in out Stores.Transaction;
      Changed : out Name_Lists.Vector;
      Status  : out Model_Runner.Errors.Error_Info;
      Configuration : String := "")
   is
      Everything : constant Name_Lists.Vector := Tasks.List (Item);

      --  The evidence that shows a requirement verified now, or nothing
      --  when something is missing.
      function Supporting (Requirement : String) return String is
         Found : Unbounded_String;
         Any   : Boolean := False;
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
                  Any := True;
                  if State /= "complete" then
                     return "";
                  end if;
                  declare
                     Evidence : constant String :=
                       Latest (Item, Id, Profile_Of (Item, Id));
                     Value    : Records.Item;
                     Reasons  : Name_Lists.Vector;
                  begin
                     if Evidence = "" then
                        return "";
                     end if;
                     Stores.Read (Item, Verification_Area, Evidence, Value, Read);
                     if Records.Get (Value, "passed") /= "true"
                       or else not Is_Current (Item, Evidence, Reasons, Configuration)
                     then
                        return "";
                     end if;
                     Append (Found, (if Found = Null_Unbounded_String then "" else ", ")
                                    & Evidence);
                  end;
               end if;
            end;
         end loop;
         return (if Any then To_String (Found) else "");
      end Supporting;

      Event : Unbounded_String;
   begin
      Changed.Clear;
      Status := E.Success;

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
