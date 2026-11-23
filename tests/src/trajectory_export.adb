with Ada.Streams;
with Ada.Streams.Stream_IO;
with Ada.Strings.Unbounded;
with Ada.Text_IO;
with Ada.Unchecked_Deallocation;
with GNAT.SHA256;
with Hostkit.Descriptors;
with Hostkit.Fs;
with Jsonlib.Documents;
with Jsonlib.Errors;
with Jsonlib.Parsers;
with Jsonlib.Serializers;
with Model_Runner.Trajectories;

package body Trajectory_Export is
   package E renames Model_Runner.Errors;
   package T renames Model_Runner.Trajectories;
   package J renames Jsonlib.Documents;
   package IO renames Ada.Streams.Stream_IO;
   package D renames Hostkit.Descriptors;
   use Ada.Strings.Unbounded;
   use type J.Value_Kind;
   use type J.Node;
   use type Jsonlib.Errors.Error_Code;
   use type IO.Count;
   use type D.Transfer_Outcome;
   use type Ada.Streams.Stream_Element_Offset;
   use type Hostkit.Fs.Entry_Kind;

   function Kind (Doc : J.Document; Node : J.Node) return J.Value_Kind
   is (if Node = J.No_Node then J.Null_Value else J.Kind (Doc, Node));

   function Field (Doc : J.Document; Object : J.Node; Name : String) return J.Node
   is (if Kind (Doc, Object) = J.Object_Value then J.Member (Doc, Object, Name) else J.No_Node);

   function Text (Doc : J.Document; Object : J.Node; Name : String) return String is
      Node : constant J.Node := Field (Doc, Object, Name);
   begin
      return (if Kind (Doc, Node) = J.String_Value then J.As_String (Doc, Node) else "");
   end Text;

   function Hash (Value : String) return Boolean
   is (Value'Length = 64 and then (for all C of Value => C in '0' .. '9' | 'a' .. 'f'));

   function Read (Path : String; Most : Positive) return String is
      File : IO.File_Type;
      type Buffer_Access is access Ada.Streams.Stream_Element_Array;
      procedure Free is new Ada.Unchecked_Deallocation (Ada.Streams.Stream_Element_Array, Buffer_Access);
      Buffer : Buffer_Access;
      Last : Ada.Streams.Stream_Element_Offset;
   begin
      if Hostkit.Fs.Is_Link (Path) or else Hostkit.Fs.Kind_Of (Path) /= Hostkit.Fs.Ordinary_File_Entry then
         return "";
      end if;
      Hostkit.Fs.Open_Stream (File, IO.In_File, Path);
      if IO.Size (File) > IO.Count (Most) then
         IO.Close (File);
         return "";
      end if;
      Buffer := new Ada.Streams.Stream_Element_Array (1 .. Ada.Streams.Stream_Element_Offset (IO.Size (File)));
      IO.Read (File, Buffer.all, Last);
      IO.Close (File);
      if Last /= Buffer.all'Last then
         Free (Buffer);
         return "";
      end if;
      declare
         Bytes : String (1 .. Natural (Last)) with Import, Address => Buffer.all'Address;
         Result : constant String := Bytes;
      begin
         Free (Buffer);
         return Result;
      end;
   exception
      when others =>
         if IO.Is_Open (File) then
            IO.Close (File);
         end if;
         Free (Buffer);
         return "";
   end Read;

   function Provenance_Complete (Metadata : String) return Boolean is
      Doc : J.Document;
      Error : Jsonlib.Errors.Error_Info;
      Model_Found : Boolean := False;
   begin
      Jsonlib.Parsers.Parse (Metadata, Doc, Error);
      if Error.Code /= Jsonlib.Errors.No_Error then
         return False;
      end if;
      declare
         Root : constant J.Node := J.Root (Doc);
         Info : constant J.Node := Field (Doc, Root, "metadata");
         P : constant J.Node := Field (Doc, Root, "provenance");
         Artifacts : constant J.Node := Field (Doc, P, "artifacts");
         Settings : constant J.Node := Field (Doc, P, "settings");
      begin
         if not Hash (Text (Doc, Info, "harness_sha256"))
           or else Text (Doc, Info, "model_fingerprint") = ""
           or else Kind (Doc, Field (Doc, Info, "template_source")) /= J.String_Value
           or else Kind (Doc, Field (Doc, Info, "tools")) /= J.Array_Value
           or else not Hash (Text (Doc, P, "model_sha256"))
           or else Kind (Doc, Settings) /= J.Object_Value
           or else Kind (Doc, Field (Doc, Settings, "sampling")) /= J.Object_Value
           or else Text (Doc, Settings, "architecture") = ""
           or else Text (Doc, Settings, "backend") = ""
           or else Kind (Doc, Artifacts) /= J.Array_Value or else J.Length (Doc, Artifacts) = 0
         then
            return False;
         end if;
         for Index in 1 .. J.Length (Doc, Artifacts) loop
            declare
               A : constant J.Node := J.Element (Doc, Artifacts, Index);
               Role : constant String := Text (Doc, A, "role");
            begin
               if not Hash (Text (Doc, A, "sha256")) or else Text (Doc, A, "path") = ""
                 or else Role not in "model" | "model_shard" | "auxiliary" | "adapter"
                 or else (Role = "adapter" and then Text (Doc, A, "scale") = "")
               then
                  return False;
               end if;
               if Role = "model" then
                  if Model_Found or else Text (Doc, A, "sha256") /= Text (Doc, P, "model_sha256") then
                     return False;
                  end if;
                  Model_Found := True;
               end if;
            end;
         end loop;
      end;
      return Model_Found;
   end Provenance_Complete;

   function Verification_Bound
     (Doc : J.Document; V : J.Node; Capture_SHA, Proof, Metadata : String) return Boolean
   is
      function F (Name : String) return J.Node is (Field (Doc, V, Name));
      function Value (Name : String) return String is (Text (Doc, V, Name));
      Start : J.Document;
      Error : Jsonlib.Errors.Error_Info;
   begin
      if Kind (Doc, V) /= J.Object_Value or else Kind (Doc, F ("schema_version")) /= J.Integer_Value
        or else J.As_Integer (Doc, F ("schema_version")) /= 1
        or else Value ("capture_sha256") /= Capture_SHA
        or else Kind (Doc, F ("independent")) /= J.Boolean_Value
        or else not J.As_Boolean (Doc, F ("independent"))
        or else Value ("task_id") = "" or else Value ("task_family") = "" or else Value ("project_revision") = ""
        or else Value ("split") not in "train" | "validation" | "test"
        or else Kind (Doc, F ("expected_outputs")) /= J.Array_Value
        or else J.Length (Doc, F ("expected_outputs")) = 0
        or else not Hash (Value ("verifier_sha256")) or else not Hash (Value ("verifier_result_sha256"))
        or else Proof = "" or else GNAT.SHA256.Digest (Proof) /= Value ("verifier_result_sha256")
        or else Value ("result") not in "passed" | "failed" | "refused" | "exhausted"
      then
         return False;
      end if;
      for Index in 1 .. J.Length (Doc, F ("expected_outputs")) loop
         declare
            One : constant J.Node := J.Element (Doc, F ("expected_outputs"), Index);
         begin
            if Kind (Doc, One) /= J.String_Value or else J.As_String (Doc, One) = "" then
               return False;
            end if;
         end;
      end loop;
      Jsonlib.Parsers.Parse (Metadata, Start, Error);
      if Error.Code /= Jsonlib.Errors.No_Error then
         return False;
      end if;
      declare
         P : constant J.Node := Field (Start, J.Root (Start), "provenance");
         Task_Id : constant String := Text (Start, P, "task_id");
         Revision : constant String := Text (Start, P, "project_revision");
      begin
         return (Task_Id = "" or else Task_Id = Value ("task_id"))
           and then (Revision = "" or else Revision = Value ("project_revision"));
      end;
   end Verification_Bound;

   procedure Check_Document (Doc : J.Document; Status : out E.Error_Info) is
      Root : constant J.Node := J.Root (Doc);
      function F (Name : String) return J.Node is (Field (Doc, Root, Name));
      Children : constant J.Node := F ("children");
      Seen : array (1 .. 1_024) of Boolean := [others => False];
      Remaining : Natural := T.Byte_Limit'Last;
      Root_Checked : T.Validation;
      Exact, Proven : Boolean := True;
      Verified, Eligible : Boolean := False;
      function Flag (Name : String) return Boolean is (J.As_Boolean (Doc, F (Name)));
      procedure Refuse (Detail : String) is
      begin
         Status := E.Make (E.IO_Read_Failed);
         E.Add_Text (Status, "detail", Detail);
      end Refuse;

      procedure Stream
        (Raw, Path, Parent : String; Call : Long_Long_Integer; Chain : String; Depth : Natural;
         Checked : out T.Validation)
      is
         Links, Metadata : J.Document;
         Error : Jsonlib.Errors.Error_Info;
      begin
         if Depth > 32 or else Raw'Length > Remaining then
            Refuse ("embedded trajectory family exceeds its depth or byte limit");
            return;
         end if;
         Remaining := Remaining - Raw'Length;
         T.Validate_Content (Raw, Checked, Status);
         if E.Is_Error (Status) then
            return;
         end if;
         if Chain /= "" and then To_String (Checked.Last_Digest) /= Chain then
            Refuse ("embedded child chain does not match its parent");
            return;
         end if;
         if Parent /= "" then
            Jsonlib.Parsers.Parse (To_String (Checked.Metadata), Metadata, Error);
            declare
               M : constant J.Node := Field (Metadata, J.Root (Metadata), "metadata");
               C : constant J.Node := Field (Metadata, M, "parent_call");
            begin
               if Text (Metadata, M, "parent_episode") /= Parent or else Kind (Metadata, C) /= J.Integer_Value
                 or else J.As_Integer (Metadata, C) /= Call
               then
                  Refuse ("embedded helper does not identify its parent call");
                  return;
               end if;
            end;
         end if;
         Exact := Exact and then Checked.Exact_Tokens;
         Proven := Proven and then Provenance_Complete (To_String (Checked.Metadata));
         Jsonlib.Parsers.Parse (To_String (Checked.Children), Links, Error);
         for Index in 1 .. J.Length (Links, J.Root (Links)) loop
            declare
               Link : constant J.Node := J.Element (Links, J.Root (Links), Index);
               Target : constant String := Text (Links, Link, "path");
               Found : Natural := 0;
               Child_Checked : T.Validation;
            begin
               for Child in 1 .. J.Length (Doc, Children) loop
                  if Text (Doc, J.Element (Doc, Children, Child), "source_path") = Target then
                     if Found /= 0 then
                        Refuse ("duplicate embedded helper identity");
                        return;
                     end if;
                     Found := Child;
                  end if;
               end loop;
               if Found = 0 or else Seen (Found) or else Target = Path then
                  Refuse ("missing, repeated or cyclic embedded helper");
                  return;
               end if;
               Seen (Found) := True;
               declare
                  C : constant J.Node := J.Element (Doc, Children, Found);
                  Content : constant String := Text (Doc, C, "jsonl");
               begin
                  if GNAT.SHA256.Digest (Content) /= Text (Doc, C, "capture_sha256") then
                     Refuse ("embedded helper content digest mismatch");
                     return;
                  end if;
                  Stream (Content, Target, Path,
                    J.As_Integer (Links, Field (Links, Link, "call")), Text (Links, Link, "sha256"),
                    Depth + 1, Child_Checked);
                  if E.Is_Error (Status) then
                     return;
                  end if;
                  if To_String (Child_Checked.Last_Digest) /= Text (Doc, C, "capture_chain_sha256") then
                     Refuse ("embedded helper's declared chain does not match its content");
                     return;
                  end if;
               end;
            end;
         end loop;
      end Stream;
   begin
      Status := E.Success;
      if Kind (Doc, Root) /= J.Object_Value or else Kind (Doc, F ("schema_version")) /= J.Integer_Value
        or else J.As_Integer (Doc, F ("schema_version")) /= 1
        or else Text (Doc, Root, "format") /= "model_runner-trajectory-export"
        or else not Hash (Text (Doc, Root, "capture_sha256"))
        or else not Hash (Text (Doc, Root, "capture_chain_sha256"))
        or else Kind (Doc, F ("events")) /= J.Array_Value or else Kind (Doc, Children) /= J.Array_Value
        or else J.Length (Doc, Children) > Seen'Length
      then
         Refuse ("invalid trajectory export header");
         return;
      end if;
      if Kind (Doc, F ("content_included")) /= J.Boolean_Value
        or else Kind (Doc, F ("capture_complete")) /= J.Boolean_Value
        or else Kind (Doc, F ("exact_tokens")) /= J.Boolean_Value
        or else Kind (Doc, F ("provenance_complete")) /= J.Boolean_Value
        or else Kind (Doc, F ("supervised_eligible")) /= J.Boolean_Value
        or else Kind (Doc, F ("rl_ready")) /= J.Boolean_Value
      then
         Refuse ("export is missing an explicit eligibility flag");
         return;
      end if;
      if Flag ("rl_ready") then
         Refuse ("trajectory capture does not establish RL readiness");
         return;
      end if;
      if not Flag ("content_included") then
         if J.Length (Doc, F ("events")) /= 0 or else J.Length (Doc, Children) /= 0
           or else Flag ("supervised_eligible") or else Text (Doc, Root, "verifier_result") /= ""
         then
            Refuse ("redacted exports cannot contain raw evidence or qualify for training");
         end if;
         return;
      end if;
      declare
         Raw : Unbounded_String;
      begin
         for Index in 1 .. J.Length (Doc, F ("events")) loop
            declare
               Event : constant J.Node := J.Element (Doc, F ("events"), Index);
            begin
               if Kind (Doc, Event) /= J.String_Value then
                  Refuse ("export must preserve each exact event line as bytes");
                  return;
               end if;
               declare
                  Line : constant String := J.As_String (Doc, Event);
               begin
                  if Line'Length + 1 > T.Byte_Limit'Last - Length (Raw)
                    or else (for some C of Line => C = ASCII.LF)
                  then
                     Refuse ("invalid exported event boundary or size");
                     return;
                  end if;
                  Append (Raw, Line & ASCII.LF);
               end;
            end;
         end loop;
         if GNAT.SHA256.Digest (To_String (Raw)) /= Text (Doc, Root, "capture_sha256") then
            Refuse ("exported root content digest mismatch");
            return;
         end if;
         Stream (To_String (Raw), Text (Doc, Root, "source_path"), "", 0,
           Text (Doc, Root, "capture_chain_sha256"), 0, Root_Checked);
      end;
      if E.Is_Error (Status) then
         return;
      end if;
      for Index in 1 .. J.Length (Doc, Children) loop
         if not Seen (Index) then
            Refuse ("export contains an unbound helper stream");
            return;
         end if;
      end loop;
      if Kind (Doc, F ("verification")) = J.Object_Value then
         Verified := Verification_Bound (Doc, F ("verification"), Text (Doc, Root, "capture_sha256"),
           Text (Doc, Root, "verifier_result"), To_String (Root_Checked.Metadata));
         if not Verified then
            Refuse ("export verification is not bound to its embedded evidence");
            return;
         end if;
      end if;
      Eligible := Exact and then Proven and then Verified
        and then Text (Doc, F ("verification"), "result") = "passed"
        and then To_String (Root_Checked.Outcome) = "answered"
        and then Root_Checked.Selected_Tokens > 0 and then Root_Checked.Unanswered_Calls = 0;
      if not Flag ("capture_complete") or else Flag ("exact_tokens") /= Exact
        or else Flag ("provenance_complete") /= Proven or else Flag ("supervised_eligible") /= Eligible
        or else Text (Doc, Root, "outcome") /= To_String (Root_Checked.Outcome)
      then
         Refuse ("export eligibility or outcome disagrees with its actual evidence");
      end if;
      if E.Is_Ok (Status) and then
        (Kind (Doc, F ("event_count")) /= J.Integer_Value
         or else J.As_Integer (Doc, F ("event_count")) /= Long_Long_Integer (Root_Checked.Events)
         or else Kind (Doc, F ("generation_count")) /= J.Integer_Value
         or else J.As_Integer (Doc, F ("generation_count")) /= Long_Long_Integer (Root_Checked.Generations))
      then
         Refuse ("export counts disagree with their actual evidence");
      end if;
   exception
      when others =>
         Refuse ("cannot validate trajectory export");
   end Check_Document;

   procedure Validate_Export (Path : String; Status : out E.Error_Info) is
      Doc : J.Document;
      Error : Jsonlib.Errors.Error_Info;
   begin
      Jsonlib.Parsers.Parse (Read (Path, 128 * 1_024 * 1_024), Doc, Error);
      if Error.Code /= Jsonlib.Errors.No_Error then
         Status := E.Make (E.IO_Read_Failed);
         E.Add_Text (Status, "path", Path);
         return;
      end if;
      Check_Document (Doc, Status);
   exception
      when others =>
         Status := E.Make (E.IO_Read_Failed);
         E.Add_Text (Status, "path", Path);
   end Validate_Export;

   procedure Export
     (Episode_Path, Output_Path, Verification_Path : String; Include_Content : Boolean;
      Status : out E.Error_Info)
   is
      Checked : T.Validation;
      Manifest, Verdict : J.Document;
      Root : constant J.Node := J.New_Object (Manifest);
      Events : constant J.Node := J.New_Array (Manifest);
      Children : constant J.Node := J.New_Array (Manifest);
      Error : Jsonlib.Errors.Error_Info;
      Proof : Unbounded_String;
      Exact, Proven : Boolean;
      Verified : Boolean := False;
      Remaining : Natural := T.Byte_Limit'Last;
      Collected : Natural := 0;
      Output : D.Descriptor := D.Invalid;

      procedure Refuse (Detail : String) is
      begin
         Status := E.Make (E.IO_Read_Failed);
         E.Add_Text (Status, "path", Episode_Path);
         E.Add_Text (Status, "detail", Detail);
      end Refuse;
      procedure Put (Name, Value : String) is
      begin
         J.Insert (Manifest, Root, Name, J.New_String (Manifest, Value));
      end Put;
      procedure Flag (Name : String; Value : Boolean) is
      begin
         J.Insert (Manifest, Root, Name, J.New_Boolean (Manifest, Value));
      end Flag;

      procedure Collect (Path, Chain : String; Is_Root : Boolean; Depth : Natural := 0) is
         Raw : constant String := Read (Path, Positive'Max (1, Remaining));
         Local : T.Validation;
         Links : J.Document;
         Error : Jsonlib.Errors.Error_Info;
      begin
         if Depth > 32 or else Collected = 1_024 or else Raw'Length > Remaining then
            Refuse ("capture family exceeds export limits");
            return;
         end if;
         T.Validate_Content (Raw, Local, Status);
         if E.Is_Error (Status) then
            return;
         end if;
         if To_String (Local.Last_Digest) /= Chain
           or else (Is_Root and then Local.File_Digest /= Checked.File_Digest)
         then
            Refuse ("capture changed after validation");
            return;
         end if;
         Collected := Collected + 1;
         Remaining := Remaining - Raw'Length;
         Exact := Exact and then Local.Exact_Tokens;
         Proven := Proven and then Provenance_Complete (To_String (Local.Metadata));
         if Is_Root then
            declare
               First : Positive := Raw'First;
            begin
               for Index in Raw'Range loop
                  if Raw (Index) = ASCII.LF then
                     J.Append (Manifest, Events, J.New_String (Manifest, Raw (First .. Index - 1)));
                     First := Index + 1;
                  end if;
               end loop;
            end;
         else
            declare
               Child : constant J.Node := J.New_Object (Manifest);
            begin
               J.Insert (Manifest, Child, "source_path", J.New_String (Manifest, Hostkit.Fs.Canonical_Path (Path)));
               J.Insert (Manifest, Child, "capture_sha256", J.New_String (Manifest, To_String (Local.File_Digest)));
               J.Insert (Manifest, Child, "capture_chain_sha256", J.New_String (Manifest, Chain));
               J.Insert (Manifest, Child, "jsonl", J.New_String (Manifest, Raw));
               J.Append (Manifest, Children, Child);
            end;
         end if;
         Jsonlib.Parsers.Parse (To_String (Local.Children), Links, Error);
         for Index in 1 .. J.Length (Links, J.Root (Links)) loop
            declare
               Link : constant J.Node := J.Element (Links, J.Root (Links), Index);
            begin
               Collect (Text (Links, Link, "path"), Text (Links, Link, "sha256"), False, Depth + 1);
               exit when E.Is_Error (Status);
            end;
         end loop;
      end Collect;
   begin
      T.Validate (Episode_Path, Checked, Status);
      if E.Is_Error (Status) then
         return;
      elsif Output_Path = "" then
         Refuse ("export requires a new destination");
         return;
      end if;
      Exact := Checked.Exact_Tokens;
      Proven := Provenance_Complete (To_String (Checked.Metadata));
      J.Set_Root (Manifest, Root);
      J.Insert (Manifest, Root, "schema_version", J.New_Integer (Manifest, 1));
      Put ("format", "model_runner-trajectory-export");
      Put ("source_path", Hostkit.Fs.Canonical_Path (Episode_Path));
      Put ("capture_sha256", To_String (Checked.File_Digest));
      Put ("capture_chain_sha256", To_String (Checked.Last_Digest));
      Put ("outcome", To_String (Checked.Outcome));
      J.Insert (Manifest, Root, "event_count", J.New_Integer (Manifest, Long_Long_Integer (Checked.Events)));
      J.Insert (Manifest, Root, "generation_count", J.New_Integer (Manifest, Long_Long_Integer (Checked.Generations)));
      if Include_Content then
         Collect (Episode_Path, To_String (Checked.Last_Digest), True);
         if E.Is_Error (Status) then
            return;
         end if;
      end if;
      J.Insert (Manifest, Root, "events", Events);
      J.Insert (Manifest, Root, "children", Children);
      if Verification_Path /= "" then
         Jsonlib.Parsers.Parse (Read (Verification_Path, 1_048_576), Verdict, Error);
         if Error.Code = Jsonlib.Errors.No_Error then
            Proof := To_Unbounded_String
              (Read (Text (Verdict, J.Root (Verdict), "verifier_result_path"), 4 * 1_024 * 1_024));
         end if;
         Verified := Error.Code = Jsonlib.Errors.No_Error
           and then Verification_Bound (Verdict, J.Root (Verdict), To_String (Checked.File_Digest),
             To_String (Proof), To_String (Checked.Metadata));
         if not Verified then
            Refuse ("independent verdict is missing or does not bind its task, capture and actual result");
            return;
         end if;
         J.Insert (Manifest, Root, "verification", J.Copy (Manifest, Verdict, J.Root (Verdict)));
      else
         J.Insert (Manifest, Root, "verification", J.New_Null (Manifest));
      end if;
      Put ("verifier_result", (if Include_Content then To_String (Proof) else ""));
      Flag ("capture_complete", Checked.Complete);
      Flag ("exact_tokens", Exact);
      Flag ("content_included", Include_Content);
      Flag ("provenance_complete", Proven);
      Flag ("supervised_eligible", Include_Content and then Exact and then Proven and then Verified
        and then Text (Verdict, J.Root (Verdict), "result") = "passed"
        and then To_String (Checked.Outcome) = "answered"
        and then Checked.Selected_Tokens > 0 and then Checked.Unanswered_Calls = 0);
      Flag ("rl_ready", False);
      Put ("verification_trust", "externally supplied independent verdict; model self-reports are not verification");
      Check_Document (Manifest, Status);
      if E.Is_Error (Status) then
         return;
      end if;
      declare
         JSON : constant String := Jsonlib.Serializers.To_String (Manifest) & ASCII.LF;
         Bytes : Ada.Streams.Stream_Element_Array (1 .. Ada.Streams.Stream_Element_Offset (JSON'Length))
           with Import, Address => JSON'Address;
         At_Byte : Ada.Streams.Stream_Element_Offset := Bytes'First;
         Last : Ada.Streams.Stream_Element_Offset;
      begin
         if JSON'Length > 128 * 1_024 * 1_024 then
            Status := E.Make (E.IO_Input_Too_Large);
            return;
         end if;
         if not D.Open_File (Output_Path & ".partial", D.Open_Write_Exclusive, Output)
           or else not Hostkit.Fs.Make_Private (Output_Path & ".partial")
         then
            D.Close (Output);
            Status := E.Make (E.IO_Write_Failed);
            E.Add_Text (Status, "path", Output_Path);
            return;
         end if;
         while At_Byte <= Bytes'Last loop
            if D.Write (Output, Bytes (At_Byte .. Bytes'Last), Last) /= D.Transfer_Ok or else Last < At_Byte then
               D.Close (Output);
               Status := E.Make (E.IO_Write_Failed);
               E.Add_Text (Status, "path", Output_Path);
               return;
            end if;
            At_Byte := Last + 1;
         end loop;
         if not D.Close (Output)
           or else not Hostkit.Fs.Move_No_Replace (Output_Path & ".partial", Output_Path)
         then
            Status := E.Make (E.IO_Write_Failed);
            E.Add_Text (Status, "path", Output_Path);
         end if;
      end;
   exception
      when others =>
         D.Close (Output);
         Refuse ("trajectory export failed; no training eligibility is established");
   end Export;

   procedure Run
     (Mode, Episode_Path, Output_Path, Verification_Path : String;
      Include_Content : Boolean; Clean : out Boolean)
   is
      Checked : T.Validation;
      Status : E.Error_Info;
   begin
      if Mode in "validate" | "validate-export"
        and then (Output_Path /= "" or else Verification_Path /= "" or else Include_Content)
      then
         Status := E.Make (E.CLI_Option_Combination);
      elsif Mode = "validate" then
         T.Validate (Episode_Path, Checked, Status);
      elsif Mode = "validate-export" then
         Validate_Export (Episode_Path, Status);
      elsif Mode = "export" then
         Export (Episode_Path, Output_Path, Verification_Path, Include_Content, Status);
      else
         Status := E.Make (E.CLI_Invalid_Option_Value);
      end if;
      Clean := E.Is_Ok (Status);
      Ada.Text_IO.Put_Line
        ("trajectories: " & (if Clean then "complete" else "refused: " & Status.Code'Image));
   end Run;
end Trajectory_Export;
