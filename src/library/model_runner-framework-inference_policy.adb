with Ada.Characters.Handling;
with Ada.Strings.Fixed;

with Model_Runner.Framework.Configurations;
with Model_Runner.Framework.Tasks;

package body Model_Runner.Framework.Inference_Policy is

   use Ada.Strings.Unbounded;
   use type Model_Runner.Templates.Thinking_Choice;
   use type Model_Runner.Templates.Reasoning_Effort;
   use type Model_Runner.Sampling.Real;

   package E renames Model_Runner.Errors;
   package Tm renames Model_Runner.Templates;

   Prefix : constant String := "scalar.inference.";

   function Starts (Text, Start : String) return Boolean
   is (Text'Length >= Start'Length
       and then Text (Text'First .. Text'First + Start'Length - 1) = Start);

   function Trim (Text : String) return String
   is (Ada.Strings.Fixed.Trim (Text, Ada.Strings.Both));

   function Image (Value : Natural) return String
   is (Trim (Natural'Image (Value)));

   --  A real as a setting is written: to six places, its trailing noughts
   --  left off -- 0.2, not 2.00000E-01. Six, not three: the policy file
   --  carries it to a runner apart, and min_p=0.0004 reached it as 0.0.
   function Real_Image (Value : Real) return String is
      Millionths : constant Natural := Natural (Long_Float'Rounding (Long_Float (Value) * 1_000_000.0));
      Whole      : constant String := Image (Millionths / 1_000_000);
      Part       : constant String := Image (Millionths mod 1_000_000 + 1_000_000);
      Last       : Natural := Part'Last;
   begin
      while Last > Part'First + 1 and then Part (Last) = '0' loop
         Last := Last - 1;
      end loop;
      return (if Last = Part'First + 1 and then Part (Last) = '0' then Whole & ".0"
              else Whole & "." & Part (Part'First + 1 .. Last));
   end Real_Image;

   --  A real as a setting takes it: digits, a point and digits, no sign, no
   --  exponent.
   function Real_Of (Text : String; Value : out Real) return Boolean is
      Points : Natural := 0;
   begin
      Value := 0.0;
      if Text'Length = 0 or else Text'Length > 12 or else Text (Text'First) = '.' or else Text (Text'Last) = '.'
      then
         return False;
      end if;
      for C of Text loop
         if C = '.' then
            Points := Points + 1;
         elsif C not in '0' .. '9' then
            return False;
         end if;
      end loop;
      if Points > 1 then
         return False;
      end if;
      Value := Real (Long_Float'Value (Text));
      return True;
   end Real_Of;

   function Natural_Of (Text : String; Value : out Natural) return Boolean is
   begin
      Value := 0;
      if Text'Length = 0 or else Text'Length > 7 or else (for some C of Text => C not in '0' .. '9') then
         return False;
      end if;
      Value := Natural'Value (Text);
      return True;
   end Natural_Of;

   --  A profile's, a kind's or a role's name, as the settings take one.
   function Is_Name (Text : String) return Boolean
   is (Text'Length in 1 .. 64
       and then (for all C of Text => C in 'a' .. 'z' | '0' .. '9' | '_' | '-'));

   ---------------
   -- Mode_Word --
   ---------------

   function Mode_Word (Mode : Policy_Mode) return String
   is (case Mode is
          when Fixed        => "fixed",
          when Profile_Mode => "profile",
          when Adaptive     => "adaptive");

   -------------------
   -- Activity_Word --
   -------------------

   function Activity_Word (Doing : Activity) return String
   is (case Doing is
          when Task_Work             => "task_work",
          when Verification_Analysis => "verification_analysis",
          when Failure_Recovery      => "failure_recovery",
          when Result_Reporting      => "result_reporting");

   -----------------
   -- Source_Word --
   -----------------

   function Source_Word (From : Source) return String
   is (case From is
          when Capability      => "capability",
          when Invocation      => "invocation",
          when Task_Setting    => "task",
          when Project         => "project",
          when Profile_Default => "profile",
          when Model_Default   => "default");

   function Source_Of (Word : String; From : out Source) return Boolean is
   begin
      for One in Source loop
         if Source_Word (One) = Word then
            From := One;
            return True;
         end if;
      end loop;
      From := Model_Default;
      return False;
   end Source_Of;

   --  Whether a setting is said in a set of overrides.
   function Has (Item : Overrides; Which : Setting) return Boolean
   is (case Which is
          when Temperature  => Item.Has_Temperature,
          when Top_K        => Item.Has_Top_K,
          when Top_P        => Item.Has_Top_P,
          when Min_P        => Item.Has_Min_P,
          when Thinking     => Item.Thinking /= Tm.Thinking_Unstated,
          when Effort       => Item.Effort /= Tm.Effort_Unstated,
          when Output_Limit => Item.Output_Limit > 0);

   --  One setting of From put into Into.
   procedure Take (Into : in out Overrides; From : Overrides; Which : Setting) is
   begin
      case Which is
         when Temperature =>
            Into.Has_Temperature := True;
            Into.Temperature := From.Temperature;
         when Top_K =>
            Into.Has_Top_K := True;
            Into.Top_K := From.Top_K;
         when Top_P =>
            Into.Has_Top_P := True;
            Into.Top_P := From.Top_P;
         when Min_P =>
            Into.Has_Min_P := True;
            Into.Min_P := From.Min_P;
         when Thinking =>
            Into.Thinking := From.Thinking;
         when Effort =>
            Into.Effort := From.Effort;
         when Output_Limit =>
            Into.Output_Limit := From.Output_Limit;
      end case;
   end Take;

   --------------------
   -- Built_In_Names --
   --------------------

   function Built_In_Names return Name_Lists.Vector
   is (["analysis", "architecture", "coding", "testing", "debugging", "exploration", "reporting",
        "verification", "documents"]);

   --------------
   -- Built_In --
   --------------

   function Built_In (Name : String; Found : out Boolean) return Overrides is
      function Made (Temperature : Real; Effort : Reasoning_Effort) return Overrides
      is ((No_Overrides with delta Has_Temperature => True, Temperature => Temperature, Effort => Effort));
   begin
      Found := True;
      --  First measures, not findings: what each is worth is for the
      --  benchmark of each model to say. The probability filters are left
      --  as the sampler has them.
      if Name = "analysis" then
         return Made (0.2, Tm.Effort_High);
      elsif Name = "architecture" then
         return Made (0.3, Tm.Effort_High);
      elsif Name = "coding" then
         return Made (0.2, Tm.Effort_Medium);
      elsif Name = "testing" then
         return Made (0.2, Tm.Effort_Medium);
      elsif Name = "debugging" then
         return Made (0.2, Tm.Effort_High);
      elsif Name = "exploration" then
         return Made (0.5, Tm.Effort_Medium);
      elsif Name = "reporting" then
         return Made (0.0, Tm.Effort_Low);
      elsif Name = "verification" then
         return Made (0.2, Tm.Effort_High);
      --  Measured, unlike the rest: a helper writing prose without thinking
      --  was a third faster, all its runs complete. Only that is changed.
      elsif Name = "documents" then
         return (No_Overrides with delta Thinking => Tm.Thinking_Off);
      end if;
      Found := False;
      return No_Overrides;
   end Built_In;

   ----------------------
   -- Is_Profile_Field --
   ----------------------

   function Is_Profile_Field (Field : String) return Boolean
   is (Field in "temperature" | "top_k" | "top_p" | "min_p" | "reasoning" | "thinking" | "max_tokens");

   -----------
   -- Parse --
   -----------

   function Parse
     (Text         : String;
      Result       : out Overrides;
      Profile_Name : out Unbounded_String) return String
   is
      Start : Natural := Text'First;

      function One (Word : String) return String is
         Equals : constant Natural := Ada.Strings.Fixed.Index (Word, "=");
      begin
         if Equals = 0 then
            return "a setting is NAME=VALUE, not " & Word;
         end if;
         declare
            Name  : constant String := Word (Word'First .. Equals - 1);
            Value : constant String := Word (Equals + 1 .. Word'Last);
            Got   : Real;
            Count : Natural;
         begin
            if Name = "profile" then
               if not Is_Name (Value) then
                  return "a profile's name is small letters, digits, _ and -, not " & Value;
               end if;
               Profile_Name := To_Unbounded_String (Value);
            elsif Name = "temperature" then
               if not Real_Of (Value, Got) or else Got > 5.0 then
                  return "temperature is a number from 0 to 5, as 0.2, not " & Value;
               end if;
               Result.Has_Temperature := True;
               Result.Temperature := Got;
            elsif Name = "top_k" then
               if not Natural_Of (Value, Count) then
                  return "top_k is a whole number, 0 for no limit, not " & Value;
               end if;
               Result.Has_Top_K := True;
               Result.Top_K := Count;
            elsif Name = "top_p" then
               if not Real_Of (Value, Got) or else Got <= 0.0 or else Got > 1.0 then
                  return "top_p is above 0 and at most 1, as 0.95, not " & Value;
               end if;
               Result.Has_Top_P := True;
               Result.Top_P := Got;
            elsif Name = "min_p" then
               if not Real_Of (Value, Got) or else Got > 1.0 then
                  return "min_p is from 0 to 1, as 0.05, not " & Value;
               end if;
               Result.Has_Min_P := True;
               Result.Min_P := Got;
            elsif Name = "reasoning" then
               Result.Effort := Tm.Effort_Unstated;
               for Level in Tm.Effort_Minimal .. Tm.Effort_High loop
                  if Tm.Effort_Word (Level) = Value then
                     Result.Effort := Level;
                  end if;
               end loop;
               if Result.Effort = Tm.Effort_Unstated then
                  return "reasoning is minimal, low, medium or high, not " & Value;
               end if;
            elsif Name = "thinking" then
               if Value = "on" then
                  Result.Thinking := Tm.Thinking_On;
               elsif Value = "off" then
                  Result.Thinking := Tm.Thinking_Off;
               else
                  return "thinking is on or off, not " & Value;
               end if;
            elsif Name = "max_tokens" then
               if not Natural_Of (Value, Count) or else Count = 0 then
                  return "max_tokens is a whole number of tokens above 0, not " & Value;
               end if;
               Result.Output_Limit := Count;
            else
               return "there is no inference setting " & Name
                 & "; they are profile, temperature, top_k, top_p, min_p, reasoning, thinking and max_tokens";
            end if;
         end;
         return "";
      end One;
   begin
      Result := No_Overrides;
      Profile_Name := Null_Unbounded_String;
      for Index in Text'First .. Text'Last + 1 loop
         if Index > Text'Last or else Text (Index) in ' ' | ASCII.HT | ASCII.LF | ',' then
            if Index > Start then
               declare
                  Said : constant String := One (Text (Start .. Index - 1));
               begin
                  if Said /= "" then
                     return Said;
                  end if;
               end;
            end if;
            Start := Index + 1;
         end if;
      end loop;
      return "";
   end Parse;

   -----------
   -- Image --
   -----------

   function Image (Item : Overrides) return String is
      Result : Unbounded_String;

      procedure Add (Word : String) is
      begin
         Append (Result, (if Result = Null_Unbounded_String then "" else " ") & Word);
      end Add;
   begin
      if Item.Has_Temperature then
         Add ("temperature=" & Real_Image (Item.Temperature));
      end if;
      if Item.Has_Top_K then
         Add ("top_k=" & Image (Item.Top_K));
      end if;
      if Item.Has_Top_P then
         Add ("top_p=" & Real_Image (Item.Top_P));
      end if;
      if Item.Has_Min_P then
         Add ("min_p=" & Real_Image (Item.Min_P));
      end if;
      if Item.Effort /= Tm.Effort_Unstated then
         Add ("reasoning=" & Tm.Effort_Word (Item.Effort));
      end if;
      if Item.Thinking /= Tm.Thinking_Unstated then
         Add ("thinking=" & (if Item.Thinking = Tm.Thinking_On then "on" else "off"));
      end if;
      if Item.Output_Limit > 0 then
         Add ("max_tokens=" & Image (Item.Output_Limit));
      end if;
      return To_String (Result);
   end Image;

   --  The word a setting is written NAME= with.
   function Field_Word (Which : Setting) return String
   is (case Which is
          when Temperature  => "temperature",
          when Top_K        => "top_k",
          when Top_P        => "top_p",
          when Min_P        => "min_p",
          when Thinking     => "thinking",
          when Effort       => "reasoning",
          when Output_Limit => "max_tokens");

   --  A profile's fields, as a configuration sets them, read into one set.
   function Project_Fields (Config : Records.Item; Name : String) return Overrides is
      Start  : constant String := Prefix & "profile." & Name & ".";
      Result : Overrides := No_Overrides;
   begin
      for Index in 1 .. Records.Field_Count (Config) loop
         declare
            Field : constant String := Records.Field_Name (Config, Index);
            Got   : Overrides;
            Named : Unbounded_String;
         begin
            if Starts (Field, Start) and then Field'Length > Start'Length
              and then Records.Get (Config, Field) /= ""
              and then Parse (Field (Field'First + Start'Length .. Field'Last) & "=" & Records.Get (Config, Field),
                              Got, Named) = ""
            then
               for Which in Setting loop
                  if Has (Got, Which) then
                     Take (Result, Got, Which);
                  end if;
               end loop;
            end if;
         end;
      end loop;
      return Result;
   end Project_Fields;

   ----------------
   -- Is_Profile --
   ----------------

   function Is_Profile (Config : Records.Item; Name : String) return Boolean is
      Start : constant String := Prefix & "profile." & Name & ".";
   begin
      if Built_In_Names.Contains (Name) then
         return True;
      end if;
      for Index in 1 .. Records.Field_Count (Config) loop
         if Starts (Records.Field_Name (Config, Index), Start)
           and then Records.Get (Config, Records.Field_Name (Config, Index)) /= ""
         then
            return True;
         end if;
      end loop;
      return False;
   end Is_Profile;

   ---------------------
   -- Setting_Problem --
   ---------------------

   function Setting_Problem (Name, Value : String) return String is
      Rest : constant String := (if Starts (Name, Prefix) then Name (Name'First + Prefix'Length .. Name'Last) else "");

      function Named_Profile return String
      is (if Is_Name (Value) then ""
          else "a profile's name is small letters, digits, _ and -, not " & Value);
   begin
      if not Starts (Name, Prefix) or else Value = "" then
         return "";
      elsif Rest = "mode" then
         return (if Value in "fixed" | "profile" | "adaptive" then ""
                 else "scalar.inference.mode is fixed, profile or adaptive, not " & Value);
      elsif Rest = "adapts" then
         return (if Value in "both" | "reasoning" | "temperature" then ""
                 else "scalar.inference.adapts is both, reasoning or temperature, not " & Value);
      elsif Rest = "default" then
         return Named_Profile;
      elsif Rest = "helpers" then
         return (if Value = "none" then "" else Named_Profile);
      elsif Starts (Rest, "task.") and then Rest'Length > 5 then
         return Named_Profile;
      elsif Starts (Rest, "role.") and then Rest'Length > 5 then
         return Named_Profile;
      elsif Starts (Rest, "activity.") and then Rest'Length > 9 then
         declare
            Word : constant String := Rest (Rest'First + 9 .. Rest'Last);
         begin
            if not (for some Doing in Activity => Activity_Word (Doing) = Word) then
               return "there is no activity " & Word
                 & "; they are task_work, verification_analysis, failure_recovery and result_reporting";
            end if;
            return (if Value = "task" then "" else Named_Profile);
         end;
      elsif Starts (Rest, "profile.") then
         declare
            Tail : constant String := Rest (Rest'First + 8 .. Rest'Last);
            Dot  : constant Natural := Ada.Strings.Fixed.Index (Tail, ".", Ada.Strings.Backward);
            Got  : Overrides;
            Said : Unbounded_String;
         begin
            if Dot = 0 or else Dot = Tail'First or else Dot = Tail'Last then
               return "a profile's field is scalar.inference.profile.NAME.FIELD";
            elsif not Is_Name (Tail (Tail'First .. Dot - 1)) then
               return "a profile's name is small letters, digits, _ and -, not " & Tail (Tail'First .. Dot - 1);
            elsif not Is_Profile_Field (Tail (Dot + 1 .. Tail'Last)) then
               return "a profile has no field " & Tail (Dot + 1 .. Tail'Last)
                 & "; its fields are temperature, top_k, top_p, min_p, reasoning, thinking and max_tokens";
            end if;
            return Parse (Tail (Dot + 1 .. Tail'Last) & "=" & Value, Got, Said);
         end;
      end if;
      return "nothing reads " & Name & "; the inference settings are scalar.inference.mode, default, adapts,"
        & " helpers, task.KIND, role.ROLE, activity.ACTIVITY and profile.NAME.FIELD";
   end Setting_Problem;

   ---------------------------
   -- Configuration_Problem --
   ---------------------------

   function Configuration_Problem (Config : Records.Item) return String is
      function Get (Field : String) return String is (Records.Get (Config, Field));
   begin
      if Get (Prefix & "mode") = "profile" and then Get (Prefix & "default") = "" then
         return "scalar.inference.mode is profile, and scalar.inference.default names no profile";
      end if;
      for Index in 1 .. Records.Field_Count (Config) loop
         declare
            Name  : constant String := Records.Field_Name (Config, Index);
            Value : constant String := Get (Name);
            Rest  : constant String :=
              (if Starts (Name, Prefix) then Name (Name'First + Prefix'Length .. Name'Last) else "");
         begin
            if Rest = "" or else Value = "" then
               null;
            elsif Setting_Problem (Name, Value) /= "" then
               return Name & ": " & Setting_Problem (Name, Value);
            elsif (Rest = "default" or else (Rest = "helpers" and then Value /= "none") or else Starts (Rest, "task.")
                   or else Starts (Rest, "role.") or else (Starts (Rest, "activity.") and then Value /= "task"))
              and then not Is_Profile (Config, Value)
            then
               return Name & " names the profile " & Value & ", which is not there";
            elsif Starts (Rest, "task.") and then Get ("task_kind." & Rest (Rest'First + 5 .. Rest'Last)) = "" then
               return Name & " is for a task kind that is not there";
            elsif Starts (Rest, "profile.") then
               --  Its fields together, as the sampler takes them.
               declare
                  Tail   : constant String := Rest (Rest'First + 8 .. Rest'Last);
                  Dot    : constant Natural := Ada.Strings.Fixed.Index (Tail, ".", Ada.Strings.Backward);
                  Named  : constant String := Tail (Tail'First .. Dot - 1);
                  Found  : Boolean;
                  Fields : Overrides := Built_In (Named, Found);
                  Own    : constant Overrides := Project_Fields (Config, Named);
                  Tried  : Model_Runner.Sampling.Configuration;
                  Status : E.Error_Info;
               begin
                  for Which in Setting loop
                     if Has (Own, Which) then
                        Take (Fields, Own, Which);
                     end if;
                  end loop;
                  if Fields.Has_Temperature then
                     Tried.Temperature := Fields.Temperature;
                  end if;
                  if Fields.Has_Top_K then
                     Tried.Top_K := Fields.Top_K;
                  end if;
                  if Fields.Has_Top_P then
                     Tried.Top_P := Fields.Top_P;
                  end if;
                  if Fields.Has_Min_P then
                     Tried.Min_P := Fields.Min_P;
                  end if;
                  Model_Runner.Sampling.Validate (Tried, Status);
                  if E.Is_Error (Status) then
                     return "the profile " & Named & " does not make a sampling the sampler takes: "
                       & E.Text_Of (Status, "field");
                  end if;
               end;
            end if;
         end;
      end loop;
      return "";
   end Configuration_Problem;

   ----------------
   -- Select_For --
   ----------------

   function Select_For (Item : Stores.Store; Task_Id : String) return Selection is
      Config  : Records.Item;
      Defined : Records.Item;
      Read    : E.Error_Info;
      Result  : Selection;
   begin
      Configurations.Read (Item, Config, Read);
      if E.Is_Error (Read) then
         return Result;
      end if;
      Result.Revision := Records.Revision (Config);
      declare
         Mode : constant String := Records.Get (Config, Prefix & "mode");
      begin
         Result.Mode := (if Mode = "adaptive" then Adaptive elsif Mode = "profile" then Profile_Mode else Fixed);
      end;
      Tasks.Definition (Item, Task_Id, Defined, Read);
      if E.Is_Error (Read) then
         return Result;
      end if;
      declare
         Named : Unbounded_String;
      begin
         --  Kept to what reads: the field was checked as it was given.
         if Parse (Records.Get (Defined, "inference"), Result.Task_Settings, Named) /= "" then
            Result.Task_Settings := No_Overrides;
            Named := Null_Unbounded_String;
         end if;
         if Named /= Null_Unbounded_String then
            Result.Profile := Named;
            Result.Task_Named := True;
         elsif Result.Mode = Profile_Mode then
            Result.Profile := To_Unbounded_String (Records.Get (Config, Prefix & "default"));
         elsif Result.Mode = Adaptive then
            Result.Profile :=
              To_Unbounded_String (Records.Get (Config, Prefix & "task." & Records.Get (Defined, "kind")));
         end if;
      end;
      return Result;
   end Select_For;

   ---------------
   -- For_Child --
   ---------------

   function For_Child
     (Item : Stores.Store; Parent : Selection; Role : String; Documents_Only : Boolean := False) return Selection
   is
      Config : Records.Item;
      Read   : E.Error_Info;
   begin
      if Parent.Task_Named or else (Parent.Mode /= Adaptive and then not Documents_Only) then
         return Parent;
      end if;
      --  The mapping as it stood when the work was selected, as Merge reads
      --  the profiles: a reconfiguring meanwhile changes neither.
      if Parent.Revision > 0 then
         Configurations.Revision_At (Item, Parent.Revision, Config, Read);
      else
         Configurations.Read (Item, Config, Read);
      end if;
      if E.Is_Error (Read) then
         return Parent;
      end if;
      --  Its role's own mapping, in adaptive mode; else, in any mode, the
      --  one for helpers that write only documents -- documents unless the
      --  project names another, or none: a model names its helpers' roles
      --  as it likes -- investigator, documentation writer -- and a mapping
      --  by name catches only the names it lists, where what it must write
      --  is said.
      declare
         Helpers : constant String := Records.Get (Config, Prefix & "helpers");
         Mapped  : constant String :=
           (if Parent.Mode = Adaptive and then Records.Get (Config, Prefix & "role." & Role) /= ""
            then Records.Get (Config, Prefix & "role." & Role)
            elsif not Documents_Only or else Helpers = "none" then ""
            elsif Helpers = "" then "documents"
            else Helpers);
      begin
         return (if Mapped = "" then Parent else (Parent with delta Profile => To_Unbounded_String (Mapped)));
      end;
   end For_Child;

   -----------------
   -- Is_Document --
   -----------------

   function Is_Document (Path : String) return Boolean is
      Lower : constant String := Ada.Characters.Handling.To_Lower (Path);

      function Ends (Tail : String) return Boolean
      is (Lower'Length > Tail'Length and then Lower (Lower'Last - Tail'Length + 1 .. Lower'Last) = Tail);
   begin
      return Ends (".md") or else Ends (".txt") or else Ends (".rst") or else Ends (".adoc");
   end Is_Document;

   ----------------------
   -- Activity_Of_Role --
   ----------------------

   --  Its words anywhere in it -- a model names roles as it likes: code
   --  reviewer, qa tester -- but one that writes tests works on the task.
   function Activity_Of_Role (Role : String) return Activity is
      function Has (Part : String) return Boolean is (Ada.Strings.Fixed.Index (Role, Part) > 0);
   begin
      return (if Has ("writ") or else Has ("author") then Task_Work
              elsif Has ("verif") or else Has ("review") or else Has ("test") or else Has ("check")
              then Verification_Analysis
              else Task_Work);
   end Activity_Of_Role;

   ----------------
   -- Merge_With --
   ----------------

   function Merge_With (Config : Records.Item; Chosen : Selection; Doing : Activity) return Request is
      Result : Request := (Chosen => Chosen, Doing => Doing, Profile => Chosen.Profile, others => <>);
   begin
      --  What the call is for picks its profile, where the project is
      --  adaptive and the task named none of its own: the configuration's
      --  mapping, else recovery is debugging, reporting is reporting and
      --  verification is verification -- for a task some mapping reached;
      --  one none reached stays as fixed work is.
      if Chosen.Mode = Adaptive and then not Chosen.Task_Named then
         declare
            Mapped : constant String := Records.Get (Config, Prefix & "activity." & Activity_Word (Doing));
         begin
            if Mapped /= "" then
               Result.Profile := (if Mapped = "task" then Chosen.Profile else To_Unbounded_String (Mapped));
            elsif Chosen.Profile /= Null_Unbounded_String then
               case Doing is
                  when Task_Work             => null;
                  when Verification_Analysis => Result.Profile := To_Unbounded_String ("verification");
                  when Failure_Recovery      => Result.Profile := To_Unbounded_String ("debugging");
                  when Result_Reporting      => Result.Profile := To_Unbounded_String ("reporting");
               end case;
            end if;
         end;
      end if;
      declare
         Named   : constant String := To_String (Result.Profile);
         Found   : Boolean;
         Builtin : constant Overrides := (if Named = "" then No_Overrides else Built_In (Named, Found));
         Own     : constant Overrides := (if Named = "" then No_Overrides else Project_Fields (Config, Named));
         Adapts  : constant String := Records.Get (Config, Prefix & "adapts");

         --  Whether a profile's field is taken, by which half it is of.
         function Taken (Which : Setting) return Boolean
         is (case Which is
                when Temperature | Top_K | Top_P | Min_P => Adapts /= "reasoning",
                when Thinking | Effort                    => Adapts /= "temperature",
                when Output_Limit                         => True);
      begin
         for Which in Setting loop
            if Has (Chosen.Task_Settings, Which) then
               Take (Result.Settings, Chosen.Task_Settings, Which);
               Result.Sources (Which) := Task_Setting;
            elsif not Taken (Which) then
               null;
            elsif Has (Own, Which) then
               Take (Result.Settings, Own, Which);
               Result.Sources (Which) := Project;
            elsif Has (Builtin, Which) then
               Take (Result.Settings, Builtin, Which);
               Result.Sources (Which) := Profile_Default;
            end if;
         end loop;
      end;
      return Result;
   end Merge_With;

   ----------------------
   -- Configuration_At --
   ----------------------

   procedure Configuration_At
     (Item     : Stores.Store;
      Revision : Natural;
      Config   : out Records.Item;
      Status   : out Model_Runner.Errors.Error_Info)
   is
      None : Records.Item;
   begin
      --  A revision the run was selected at is that one or nothing: a call
      --  set by another than the one its record names was never asked for.
      if Revision > 0 then
         Configurations.Revision_At (Item, Revision, Config, Status);
         return;
      end if;
      Configurations.Read (Item, Config, Status);
      if Configurations.Unreadable (Status) then
         return;
      end if;
      if E.Is_Error (Status) then
         Config := None;
         Status := E.Success;
      end if;
   end Configuration_At;

   -----------
   -- Merge --
   -----------

   procedure Merge
     (Item   : Stores.Store;
      Chosen : Selection;
      Doing  : Activity;
      Result : out Request;
      Status : out Model_Runner.Errors.Error_Info)
   is
      Config : Records.Item;
   begin
      --  The configuration at the revision the run was selected at: what a
      --  profile said then, whatever was reconfigured since.
      Configuration_At (Item, Chosen.Revision, Config, Status);
      Result := Merge_With (Config, Chosen, Doing);
   end Merge;

   ---------
   -- Fit --
   ---------

   procedure Fit
     (Asked   : Request;
      Invoked : Invocation_Settings;
      Model   : Reasoning_Controls;
      Result  : out Effective;
      Status  : out Model_Runner.Errors.Error_Info)
   is
      package Sm renames Model_Runner.Sampling;
      Wanted : Overrides renames Asked.Settings;

      --  A setting the task or the project named, not one a profile chose.
      function Named (Which : Setting) return Boolean
      is (Asked.Sources (Which) in Task_Setting | Project);

      procedure Note (Text : String) is
      begin
         Append (Result.Fallback, (if Result.Fallback = Null_Unbounded_String then "" else "; ") & Text);
      end Note;

      procedure Refuse (Which : Setting; Value, Detail : String) is
      begin
         Status := E.Make (E.Framework_Input_Invalid);
         E.Add_Text (Status, "name", (if Which = Effort then "reasoning" else "thinking"));
         E.Add_Text (Status, "value", Value);
         E.Add_Text (Status, "detail", Detail & " -- set by the " & Source_Word (Asked.Sources (Which))
                     & (if Asked.Profile = Null_Unbounded_String then ""
                        else " for the profile " & To_String (Asked.Profile)));
      end Refuse;

      --  A sampling setting: the session's where it named it, else the
      --  request's, else the session's as its model file and defaults make it.
      procedure Sample (Which : Setting; Key : Sm.Model_Key) is
      begin
         if Invoked.Given (Key) then
            Result.Sources (Which) := Invocation;
         elsif Has (Wanted, Which) then
            Result.Sources (Which) := Asked.Sources (Which);
            case Which is
               when Temperature => Result.Sampling.Temperature := Wanted.Temperature;
               when Top_K       => Result.Sampling.Top_K := Wanted.Top_K;
               when Top_P       => Result.Sampling.Top_P := Wanted.Top_P;
               when Min_P       => Result.Sampling.Min_P := Wanted.Min_P;
               when others      => null;
            end case;
         end if;
      end Sample;
   begin
      Status := E.Success;
      Result := (Asked => Asked, Sampling => Invoked.Base, others => <>);
      Sample (Temperature, Sm.Temp);
      Sample (Top_K, Sm.Top_K);
      Sample (Top_P, Sm.Top_P);
      Sample (Min_P, Sm.Min_P);

      if Invoked.Thinking /= Tm.Thinking_Unstated then
         Result.Thinking := Invoked.Thinking;
         Result.Sources (Thinking) := Invocation;
      elsif Has (Wanted, Thinking) then
         Result.Thinking := Wanted.Thinking;
         Result.Sources (Thinking) := Asked.Sources (Thinking);
      end if;
      if Invoked.Effort /= Tm.Effort_Unstated then
         Result.Effort := Invoked.Effort;
         Result.Sources (Effort) := Invocation;
      elsif Has (Wanted, Effort) then
         Result.Effort := Wanted.Effort;
         Result.Sources (Effort) := Asked.Sources (Effort);
      end if;

      --  A template that takes how much to think reads thinking off as low:
      --  a level above it from a lower source than the thinking's -- a
      --  profile's medium or high, under --no-think -- would undo it, so it
      --  is left. Thinking on is any level that thinks, and keeps it.
      if Model.Known and then Model.Effort and then Result.Thinking = Tm.Thinking_Off
        and then Result.Effort in Tm.Effort_Medium | Tm.Effort_High
        and then Result.Sources (Thinking) < Result.Sources (Effort)
      then
         Note ("reasoning " & Tm.Effort_Word (Result.Effort) & " is left: thinking is off by the "
               & Source_Word (Result.Sources (Thinking)) & ", which the template reads as low");
         Result.Effort := Tm.Effort_Unstated;
         Result.Sources (Effort) := Capability;
      end if;

      --  What the model's template reads: a model not loaded yet -- run as
      --  a process of its own -- is fitted there, with its own.
      if Model.Known and then Result.Effort /= Tm.Effort_Unstated then
         declare
            Level    : constant Reasoning_Effort := Result.Effort;
            Explicit : constant Boolean := Result.Sources (Effort) = Invocation or else Named (Effort);
            Word     : constant String := Tm.Effort_Word (Level);
         begin
            if Model.Effort then
               if not Tm.Takes_Effort (Level) then
                  if Explicit then
                     Refuse (Effort, Word, "the model's template takes low, medium or high");
                     return;
                  end if;
                  Result.Effort := Tm.Effort_Low;
                  Result.Sources (Effort) := Capability;
                  Note ("reasoning " & Word & " is low: the template takes low, medium or high");
               end if;
            elsif Model.Thinking then
               if Explicit then
                  Refuse (Effort, Word, "the model's template takes whether to think, not how much: thinking=on|off");
                  return;
               end if;
               Result.Effort := Tm.Effort_Unstated;
               Result.Sources (Effort) := Capability;
               if Result.Sources (Thinking) /= Model_Default then
                  Note ("reasoning " & Word & " is left: thinking is set, and the template takes only that");
               elsif Level = Tm.Effort_High then
                  Result.Thinking := Tm.Thinking_On;
                  Result.Sources (Thinking) := Capability;
                  Note ("reasoning high is thinking on: the template takes only whether to think");
               elsif Level in Tm.Effort_Minimal | Tm.Effort_Low then
                  Result.Thinking := Tm.Thinking_Off;
                  Result.Sources (Thinking) := Capability;
                  Note ("reasoning " & Word & " is thinking off: the template takes only whether to think");
               else
                  Note ("reasoning medium is the template's own default: it takes only whether to think");
               end if;
            else
               if Explicit then
                  Refuse (Effort, Word, "the model's template takes no reasoning control");
                  return;
               end if;
               Result.Effort := Tm.Effort_Unstated;
               Result.Sources (Effort) := Capability;
               Note ("reasoning " & Word & " is left: the template takes no reasoning control");
            end if;
         end;
      end if;
      if Model.Known and then Result.Thinking /= Tm.Thinking_Unstated
        and then Result.Sources (Thinking) in Task_Setting | Project | Profile_Default
        and then not Model.Thinking and then not Model.Effort
      then
         if Named (Thinking) then
            Refuse (Thinking, (if Result.Thinking = Tm.Thinking_On then "on" else "off"),
                    "the model's template takes no reasoning control");
            return;
         end if;
         Result.Thinking := Tm.Thinking_Unstated;
         Result.Sources (Thinking) := Capability;
         Note ("thinking is left: the template takes no reasoning control");
      end if;

      --  The reply: never more room than the session keeps for one.
      if Invoked.Output_Given then
         Result.Output_Limit := Invoked.Output_Room;
         Result.Sources (Output_Limit) := Invocation;
      elsif Wanted.Output_Limit > 0 and then Wanted.Output_Limit <= Invoked.Output_Room then
         Result.Output_Limit := Wanted.Output_Limit;
         Result.Sources (Output_Limit) := Asked.Sources (Output_Limit);
      elsif Wanted.Output_Limit > 0 then
         Result.Output_Limit := Invoked.Output_Room;
         Result.Sources (Output_Limit) := Capability;
         Note ("a reply of" & Natural'Image (Wanted.Output_Limit) & " tokens is held to the"
               & Natural'Image (Invoked.Output_Room) & " the session keeps for one");
      else
         Result.Output_Limit := Invoked.Output_Room;
      end if;

      Sm.Validate (Result.Sampling, Status);
   end Fit;

   -------------
   -- Resolve --
   -------------

   procedure Resolve
     (Item    : Stores.Store;
      Chosen  : Selection;
      Doing   : Activity;
      Invoked : Invocation_Settings;
      Model   : Reasoning_Controls;
      Result  : out Effective;
      Status  : out Model_Runner.Errors.Error_Info)
   is
      Asked : Request;
   begin
      Merge (Item, Chosen, Doing, Asked, Status);
      if E.Is_Error (Status) then
         Result := (others => <>);
         return;
      end if;
      Fit (Asked, Invoked, Model, Result, Status);
   end Resolve;

   ----------------------
   -- Check_Every_Call --
   ----------------------

   procedure Check_Every_Call
     (Item   : Stores.Store;
      Chosen : Selection;
      Model  : Reasoning_Controls;
      Status : out Model_Runner.Errors.Error_Info)
   is
      Config : Records.Item;
      Tried  : Effective;

      procedure Each_Activity (Of_Run : Selection) is
      begin
         for Doing in Activity loop
            Resolve (Item, Of_Run, Doing, (others => <>), Model, Tried, Status);
            exit when E.Is_Error (Status);
         end loop;
      end Each_Activity;
   begin
      Each_Activity (Chosen);
      if E.Is_Error (Status) or else Chosen.Task_Named then
         return;
      end if;
      --  A helper writing documents, in any mode.
      Each_Activity (For_Child (Item, Chosen, "", Documents_Only => True));
      if E.Is_Error (Status) or else Chosen.Mode /= Adaptive then
         return;
      end if;
      Configuration_At (Item, Chosen.Revision, Config, Status);
      if E.Is_Error (Status) then
         return;
      end if;
      for Index in 1 .. Records.Field_Count (Config) loop
         declare
            Field : constant String := Records.Field_Name (Config, Index);
            Roles : constant String := Prefix & "role.";
         begin
            if Starts (Field, Roles) and then Field'Length > Roles'Length then
               Each_Activity (For_Child (Item, Chosen, Field (Field'First + Roles'Length .. Field'Last)));
               exit when E.Is_Error (Status);
            end if;
         end;
      end loop;
   end Check_Every_Call;

   ---------------------
   -- Selection_Lines --
   ---------------------

   function Selection_Lines (Chosen : Selection) return String
   is ("inference_mode=" & Mode_Word (Chosen.Mode) & ASCII.LF
       & "inference_profile=" & (if Chosen.Profile = Null_Unbounded_String then "none" else To_String (Chosen.Profile))
       & (if Chosen.Task_Named then " (the task's own)" else "") & ASCII.LF
       & (if Image (Chosen.Task_Settings) = "" then ""
          else "inference_task=" & Image (Chosen.Task_Settings) & ASCII.LF)
       & "inference_revision=" & Image (Chosen.Revision));

   -------------
   -- Line_Of --
   -------------

   function Line_Of (Policy : Effective) return String is
      Greedy : constant Boolean := Model_Runner.Sampling.Is_Greedy (Policy.Sampling);

      function With_Source (Which : Setting; Value : String) return String
      is (Field_Word (Which) & "=" & Value & " (" & Source_Word (Policy.Sources (Which)) & ")");

      --  A filter a greedy draw never reads is not said to have chosen.
      function Filter (Which : Setting; Value : String) return String
      is (if Greedy then Field_Word (Which) & "=unused (greedy)" else With_Source (Which, Value));
   begin
      return "activity=" & Activity_Word (Policy.Asked.Doing)
        & " profile=" & (if Policy.Asked.Profile = Null_Unbounded_String then "none"
                         else To_String (Policy.Asked.Profile))
        & " mode=" & Mode_Word (Policy.Asked.Chosen.Mode)
        & " revision=" & Image (Policy.Asked.Chosen.Revision)
        & " " & With_Source (Temperature, Real_Image (Policy.Sampling.Temperature))
        & " " & Filter (Top_K, Image (Policy.Sampling.Top_K))
        & " " & Filter (Top_P, Real_Image (Policy.Sampling.Top_P))
        & " " & Filter (Min_P, Real_Image (Policy.Sampling.Min_P))
        & " " & With_Source (Thinking, (case Policy.Thinking is
                                           when Tm.Thinking_Unstated => "unstated",
                                           when Tm.Thinking_On       => "on",
                                           when Tm.Thinking_Off      => "off"))
        & " " & With_Source (Effort, (if Policy.Effort = Tm.Effort_Unstated then "unstated"
                                      else Tm.Effort_Word (Policy.Effort)))
        & " " & With_Source (Output_Limit, Image (Policy.Output_Limit))
        & (if Policy.Fallback = Null_Unbounded_String then ""
           else " fallback=" & To_String (Policy.Fallback));
   end Line_Of;

   -------------------
   -- Policy_Beside --
   -------------------

   function Policy_Beside (Prompt_Path : String) return String
   is (Prompt_Path & ".policy");

   --------------
   -- Image_Of --
   --------------

   function Image_Of (Asked : Request) return String is
      Result : Unbounded_String :=
        To_Unbounded_String
          ("mode=" & Mode_Word (Asked.Chosen.Mode) & ASCII.LF
           & "profile=" & To_String (Asked.Profile) & ASCII.LF
           & "selected=" & To_String (Asked.Chosen.Profile) & ASCII.LF
           & "task_named=" & (if Asked.Chosen.Task_Named then "yes" else "no") & ASCII.LF
           & "activity=" & Activity_Word (Asked.Doing) & ASCII.LF
           & "revision=" & Image (Asked.Chosen.Revision) & ASCII.LF);
      One : Overrides;
   begin
      if Image (Asked.Chosen.Task_Settings) /= "" then
         Append (Result, "task " & Image (Asked.Chosen.Task_Settings) & ASCII.LF);
      end if;
      for Which in Setting loop
         if Has (Asked.Settings, Which) then
            One := No_Overrides;
            Take (One, Asked.Settings, Which);
            Append (Result, "set " & Image (One) & " " & Source_Word (Asked.Sources (Which)) & ASCII.LF);
         end if;
      end loop;
      return To_String (Result);
   end Image_Of;

   ------------------
   -- Read_Request --
   ------------------

   function Read_Request (Text : String; Asked : out Request) return String is
      Start : Natural := Text'First;

      function Line (Said : String) return String is
         Equals : constant Natural := Ada.Strings.Fixed.Index (Said, "=");
         Key    : constant String := (if Equals = 0 then "" else Said (Said'First .. Equals - 1));
         Value  : constant String := (if Equals = 0 then "" else Said (Equals + 1 .. Said'Last));
      begin
         if Said = "" then
            return "";
         elsif Starts (Said, "set ") then
            declare
               Rest  : constant String := Said (Said'First + 4 .. Said'Last);
               Space : constant Natural := Ada.Strings.Fixed.Index (Rest, " ", Ada.Strings.Backward);
               Got   : Overrides;
               Named : Unbounded_String;
               From  : Source;
            begin
               if Space = 0 or else not Source_Of (Rest (Space + 1 .. Rest'Last), From)
                 or else Parse (Rest (Rest'First .. Space - 1), Got, Named) /= ""
               then
                  return "a setting reads set NAME=VALUE SOURCE, not " & Said;
               end if;
               for Which in Setting loop
                  if Has (Got, Which) then
                     Take (Asked.Settings, Got, Which);
                     Asked.Sources (Which) := From;
                  end if;
               end loop;
            end;
         elsif Starts (Said, "task ") then
            declare
               Named : Unbounded_String;
               Said_Wrong : constant String :=
                 Parse (Said (Said'First + 5 .. Said'Last), Asked.Chosen.Task_Settings, Named);
            begin
               if Said_Wrong /= "" then
                  return Said_Wrong;
               end if;
            end;
         elsif Key = "mode" then
            Asked.Chosen.Mode := (if Value = "adaptive" then Adaptive elsif Value = "profile" then Profile_Mode
                                  else Fixed);
         elsif Key = "profile" then
            Asked.Profile := To_Unbounded_String (Value);
         elsif Key = "selected" then
            Asked.Chosen.Profile := To_Unbounded_String (Value);
         elsif Key = "task_named" then
            Asked.Chosen.Task_Named := Value = "yes";
         elsif Key = "activity" then
            for Doing in Activity loop
               if Activity_Word (Doing) = Value then
                  Asked.Doing := Doing;
               end if;
            end loop;
         elsif Key = "revision" then
            declare
               Got : Natural;
            begin
               if Natural_Of (Value, Got) then
                  Asked.Chosen.Revision := Got;
               end if;
            end;
         else
            return "a policy has no line " & Said;
         end if;
         return "";
      end Line;
   begin
      Asked := (others => <>);
      for Index in Text'First .. Text'Last + 1 loop
         if Index > Text'Last or else Text (Index) = ASCII.LF then
            declare
               Said : constant String := Line (Trim (Text (Start .. Index - 1)));
            begin
               if Said /= "" then
                  return Said;
               end if;
            end;
            Start := Index + 1;
         end if;
      end loop;
      return "";
   end Read_Request;

end Model_Runner.Framework.Inference_Policy;
