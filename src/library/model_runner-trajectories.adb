with Ada.Characters.Handling;
with Ada.Directories;
with Ada.Environment_Variables;
with Ada.Strings.Fixed;
with Ada.Task_Attributes;
with Ada.Unchecked_Deallocation;
with GNAT.SHA256;
with Hostkit.Fs;
with Hostkit.Locks;
with Hostkit.Path_Text;
with Jsonlib.Documents;
with Jsonlib.Errors;
with Jsonlib.Parsers;
with Jsonlib.Serializers;

package body Model_Runner.Trajectories is
   package E renames Model_Runner.Errors;
   package J renames Jsonlib.Documents;
   package IO renames Ada.Streams.Stream_IO;
   use Ada.Strings.Unbounded;
   use type Ada.Streams.Stream_Element_Offset;
   use type Hostkit.Locks.Lock_Outcome;
   use type Hostkit.Fs.Entry_Kind;
   use type IO.Count;
   use type J.Value_Kind;
   use type Jsonlib.Errors.Error_Code;
   use type J.Node;

   function Value_Kind_Of (From : J.Document; Item : J.Node) return J.Value_Kind
   is (if Item = J.No_Node then J.Null_Value else J.Kind (From, Item));

   package Parents is new Ada.Task_Attributes (Lineage, (others => <>));
   function Current return Lineage is (Parents.Value);
   procedure Enter (Context : Lineage) is
   begin
      Parents.Set_Value (Context);
   end Enter;

   type Child_Entry is record
      Used : Boolean := False;
      Parent : Unbounded_String;
      Call : Natural := 0;
      Path : Unbounded_String;
      Digest : Unbounded_String;
      Complete : Boolean := False;
   end record;
   type Child_Array is array (1 .. 1_024) of Child_Entry;

   --  Only bounded lineage metadata is shared. Each task writes its own file.
   protected Children is
      procedure Register (Parent : String; Call : Natural; Slot : out Natural);
      procedure Publish (Slot : Natural; Path, Digest : String; Complete : Boolean);
      procedure Take (Parent : String; JSON : out Unbounded_String; Complete : out Boolean);
   private
      Rows : Child_Array;
      Overflow : Boolean := False;
   end Children;

   protected body Children is
      procedure Register (Parent : String; Call : Natural; Slot : out Natural) is
      begin
         Slot := 0;
         for Index in Rows'Range loop
            if not Rows (Index).Used then
               Rows (Index) := (Used => True, Parent => To_Unbounded_String (Parent),
                 Call => Call, others => <>);
               Slot := Index;
               return;
            end if;
         end loop;
         Overflow := True;
      end Register;

      procedure Publish (Slot : Natural; Path, Digest : String; Complete : Boolean) is
      begin
         if Slot in Rows'Range and then Rows (Slot).Used then
            Rows (Slot).Path := To_Unbounded_String (Path);
            Rows (Slot).Digest := To_Unbounded_String (Digest);
            Rows (Slot).Complete := Complete;
         end if;
      end Publish;

      procedure Take (Parent : String; JSON : out Unbounded_String; Complete : out Boolean) is
      begin
         JSON := Null_Unbounded_String;
         Complete := not Overflow;
         for Row of Rows loop
            if Row.Used and then To_String (Row.Parent) = Parent then
               Append (JSON, (if Length (JSON) = 0 then "" else ",")
                 & "{""path"":" & Quote (To_String (Row.Path)) & ",""sha256"":"
                 & Quote (To_String (Row.Digest)) & ",""call"":" & Number (Long_Long_Integer (Row.Call)) & "}");
               Complete := Complete and then Row.Complete;
               Row := (others => <>);
            end if;
         end loop;
         if (for all Row of Rows => not Row.Used) then
            Overflow := False;
         end if;
         JSON := "[" & JSON & "]";
      end Take;
   end Children;

   function Number (Value : Long_Long_Integer) return String
   is (Ada.Strings.Fixed.Trim (Value'Image, Ada.Strings.Both));

   function Quote (Text : String) return String is
      Doc : J.Document;
   begin
      J.Set_Root (Doc, J.New_String (Doc, Text));
      return Jsonlib.Serializers.To_String (Doc);
   end Quote;

   function Hex_Bytes (Bytes : String) return String is
      Hex : constant String := "0123456789abcdef";
      Result : String (1 .. Bytes'Length * 2);
   begin
      for Index in Bytes'Range loop
         Result ((Index - Bytes'First) * 2 + 1) := Hex (Character'Pos (Bytes (Index)) / 16 + 1);
         Result ((Index - Bytes'First) * 2 + 2) := Hex (Character'Pos (Bytes (Index)) mod 16 + 1);
      end loop;
      return Result;
   end Hex_Bytes;

   function Word (Kind : Event_Kind) return String
   is (Ada.Characters.Handling.To_Lower (Kind'Image));

   function Digest (Previous : String; Sequence : Positive; Kind, Payload : String) return String
   is (GNAT.SHA256.Digest
         (Previous & ASCII.LF & Number (Long_Long_Integer (Sequence)) & ASCII.LF & Kind & ASCII.LF & Payload));

   function Configured return Options is
      Result : Options;
      function Limit (Name : String; Default, Most : Positive; Least : Positive := 1) return Positive is
         Text : constant String := Ada.Environment_Variables.Value (Name, "");
         Value : Natural := 0;
      begin
         if Text = "" then
            return Default;
         end if;
         for C of Text loop
            if C not in '0' .. '9' or else Value > (Most - (Character'Pos (C) - Character'Pos ('0'))) / 10 then
               Result.Invalid := True;
               return Default;
            end if;
            Value := Value * 10 + Character'Pos (C) - Character'Pos ('0');
         end loop;
         if Value < Least or else Value > Most then
            Result.Invalid := True;
            return Default;
         end if;
         return Value;
      end Limit;
   begin
      Result.Directory := To_Unbounded_String (Ada.Environment_Variables.Value ("MODEL_RUNNER_CAPTURE_DIR", ""));
      if Length (Current.Parent) > 0 then
         Result.Max_Bytes := Current.Max_Bytes;
         Result.Max_Episodes := Current.Max_Episodes;
         if Length (Result.Directory) = 0 then
            Result.Directory := Current.Directory;
         end if;
      end if;
      if Length (Result.Directory) > 0 then
         Result.Provenance := Current.Provenance;
         Result.Max_Bytes := Limit ("MODEL_RUNNER_CAPTURE_MAX_BYTES", Result.Max_Bytes, Byte_Limit'Last, 1_024);
         Result.Max_Episodes := Limit ("MODEL_RUNNER_CAPTURE_MAX_EPISODES", Result.Max_Episodes, Episode_Limit'Last);
      end if;
      return Result;
   end Configured;

   procedure Latch (Item : in out Recorder; Code : E.Error_Code; Detail : String) is
   begin
      if E.Is_Ok (Item.Error) then
         Item.Error := E.Make (Code);
         E.Add_Text (Item.Error, "path", To_String (Item.Name));
         E.Add_Text (Item.Error, "detail", Detail);
      end if;
   end Latch;

   function Path (Item : Recorder) return String is (To_String (Item.Name));
   function Active (Item : Recorder) return Boolean is (IO.Is_Open (Item.File) and then E.Is_Ok (Item.Error));

   procedure Append (Item : in out Recorder; Kind : Event_Kind; Payload : String) is
   begin
      if not Active (Item) then
         return;
      end if;
      if Payload'Length > 4 * 1_024 * 1_024 or else Payload'Length > Item.Limit - Item.Written then
         Latch (Item, E.IO_Input_Too_Large, "trajectory byte limit reached; capture is incomplete");
         return;
      end if;
      declare
         Next : constant Positive := Item.Sequence + 1;
         Hash : constant String := Digest (Item.Previous, Next, Word (Kind), Payload);
         Line : constant String := "{""sequence"":" & Number (Long_Long_Integer (Next))
           & ",""kind"":" & Quote (Word (Kind)) & ",""payload"":" & Quote (Payload)
           & ",""sha256"":" & Quote (Hash) & "}" & ASCII.LF;
         Bytes : Ada.Streams.Stream_Element_Array (1 .. Ada.Streams.Stream_Element_Offset (Line'Length));
      begin
         if Line'Length > 4 * 1_024 * 1_024 or else Line'Length > Item.Limit - Item.Written then
            Latch (Item, E.IO_Input_Too_Large, "trajectory byte limit reached; capture is incomplete");
            return;
         end if;
         for Index in Line'Range loop
            Bytes (Ada.Streams.Stream_Element_Offset (Index)) := Character'Pos (Line (Index));
         end loop;
         IO.Write (Item.File, Bytes);
         Item.Previous := Hash;
         Item.Sequence := Next;
         Item.Written := Item.Written + Line'Length;
      end;
   exception
      when others =>
         Latch (Item, E.IO_Write_Failed, "trajectory write failed; capture is incomplete");
   end Append;

   procedure Open
     (Item : in out Recorder; Settings : Options; Metadata : String; Status : out E.Error_Info)
   is
      Lock : Hostkit.Locks.Lock;
      Root : constant String := To_String (Settings.Directory);
      Place : Unbounded_String;
      Good : Boolean;
   begin
      Finalize (Item);
      Item.Name := Null_Unbounded_String;
      Item.Error := E.Success;
      Item.Previous := [others => '0'];
      Item.Sequence := 0;
      Item.Written := 0;
      Item.Limit := Settings.Max_Bytes;
      Status := E.Success;
      if Length (Current.Parent) > 0 then
         Children.Register (To_String (Current.Parent), Current.Parent_Call, Item.Registration);
         if Item.Registration = 0 then
            Latch (Item, E.IO_Input_Too_Large, "active trajectory lineage limit reached");
            Status := Item.Error;
            return;
         end if;
      end if;
      if Root = "" then
         return;
      elsif Settings.Invalid then
         Latch (Item, E.CLI_Invalid_Environment_Value, "invalid trajectory capture limits");
         Status := Item.Error;
         return;
      end if;
      if Hostkit.Fs.Kind_Of (Root) = Hostkit.Fs.Missing_Entry then
         Good := Hostkit.Fs.Create_Path (Root) and then Hostkit.Fs.Make_Private (Root);
         if not Good then
            Latch (Item, E.IO_Open_Failed, "cannot create private trajectory directory");
         end if;
      elsif Hostkit.Fs.Is_Link (Root) or else Hostkit.Fs.Directory_Accessible_By_Others (Root) then
         Latch (Item, E.IO_Open_Failed, "trajectory directory must be private and not a link");
      end if;
      if E.Is_Error (Item.Error) then
         Status := Item.Error;
         return;
      end if;
      if Hostkit.Locks.Acquire (Root & "/capture.lock", Hostkit.Locks.Lock_Exclusive, True, Lock)
        /= Hostkit.Locks.Lock_Ok
      then
         Latch (Item, E.IO_Open_Failed, "cannot reserve a trajectory slot");
         Status := Item.Error;
         return;
      end if;
      for Slot in 1 .. Settings.Max_Episodes loop
         declare
            Candidate : constant String := Root & "/episode-" & Number (Long_Long_Integer (Slot));
         begin
            if Hostkit.Fs.Kind_Of (Candidate) = Hostkit.Fs.Missing_Entry
              and then not Hostkit.Fs.Is_Link (Candidate)
            then
               if Hostkit.Fs.Create_Directory (Candidate) and then Hostkit.Fs.Make_Private (Candidate) then
                  Place := To_Unbounded_String (Candidate);
               end if;
               exit;
            end if;
         end;
      end loop;
      if Length (Place) = 0 then
         Latch (Item, E.IO_Input_Too_Large, "trajectory retention slots exhausted; no old episode was deleted");
      else
         Item.Name := To_Unbounded_String
           (Ada.Directories.Compose (Hostkit.Fs.Canonical_Path (To_String (Place)), "events.jsonl"));
         Hostkit.Fs.Create_Stream (Item.File, IO.Out_File, Path (Item) & ".partial");
      end if;
      Hostkit.Locks.Release (Lock);
      if Active (Item) then
         Append (Item, Episode_Start,
           "{""schema_version"":1,""metadata"":" & Metadata & ",""provenance"":"
           & (if Length (Settings.Provenance) = 0 then "{}" else To_String (Settings.Provenance)) & "}");
      end if;
      Status := Item.Error;
   exception
      when others =>
         Hostkit.Locks.Release (Lock);
         Latch (Item, E.IO_Open_Failed, "cannot open trajectory capture");
         Status := Item.Error;
   end Open;

   procedure Input
     (Item : in out Recorder; Prompt : String; Tokens : Model_Runner.Tokenizer.Token_Array)
   is
      Held : Unbounded_String;
   begin
      if not Active (Item) then
         return;
      end if;
      for Token of Tokens loop
         Append (Held, (if Length (Held) = 0 then "" else ",") & Number (Long_Long_Integer (Token)));
      end loop;
      Append (Item, Model_Input,
        "{""prompt"":" & Quote (Prompt) & ",""tokens"" :[" & To_String (Held) & "],""loss_mask"":0}");
   end Input;

   procedure Selected
     (Item : in out Recorder; Token : Model_Runner.Tokenizer.Token_Id; Piece : String; Terminal : Boolean)
   is
   begin
      if not Active (Item) then
         return;
      end if;
      Append (Item, Selected_Token,
        "{""id"":" & Number (Long_Long_Integer (Token)) & ",""piece_hex"":" & Quote (Hex_Bytes (Piece))
        & ",""terminal"":" & (if Terminal then "true" else "false") & ",""loss_mask"":1}");
   end Selected;

   procedure Finish (Item : in out Recorder; Payload : String; Status : out E.Error_Info) is
      Links : Unbounded_String;
      Complete : Boolean;
      Doc, Linked : J.Document;
      Error : Jsonlib.Errors.Error_Info;
   begin
      if not IO.Is_Open (Item.File) then
         Children.Publish (Item.Registration, Path (Item), Item.Previous, False);
         Item.Registration := 0;
         Status := Item.Error;
         return;
      end if;
      Children.Take (Path (Item), Links, Complete);
      if not Complete then
         Latch (Item, E.IO_Write_Failed, "a helper trajectory is incomplete or missing");
      end if;
      if Active (Item) then
         Jsonlib.Parsers.Parse (Payload, Doc, Error);
         if Error.Code /= Jsonlib.Errors.No_Error or else Value_Kind_Of (Doc, J.Root (Doc)) /= J.Object_Value then
            Latch (Item, E.IO_Write_Failed, "invalid trajectory outcome payload");
         else
            Jsonlib.Parsers.Parse (To_String (Links), Linked, Error);
            J.Insert (Doc, J.Root (Doc), "children", J.Copy (Doc, Linked, J.Root (Linked)));
            Append (Item, Episode_End, Jsonlib.Serializers.To_String (Doc));
         end if;
      end if;
      if IO.Is_Open (Item.File) then
         IO.Close (Item.File);
      end if;
      if E.Is_Ok (Item.Error) and then Length (Item.Name) > 0
        and then not Hostkit.Fs.Move_No_Replace (Path (Item) & ".partial", Path (Item))
      then
         Latch (Item, E.IO_Write_Failed, "cannot publish completed trajectory");
      end if;
      Children.Publish (Item.Registration, Path (Item), Item.Previous, E.Is_Ok (Item.Error));
      Item.Registration := 0;
      Status := Item.Error;
   exception
      when others =>
         Latch (Item, E.IO_Write_Failed, "cannot finish trajectory capture");
         Children.Publish (Item.Registration, Path (Item), Item.Previous, False);
         Item.Registration := 0;
         Status := Item.Error;
   end Finish;

   overriding procedure Finalize (Item : in out Recorder) is
      Links : Unbounded_String;
      Complete : Boolean;
   begin
      Children.Publish (Item.Registration, Path (Item), Item.Previous, False);
      Item.Registration := 0;
      if Length (Item.Name) > 0 then
         Children.Take (Path (Item), Links, Complete);
      end if;
      if IO.Is_Open (Item.File) then
         IO.Close (Item.File);
      end if;
   exception
      when others =>
         null;
   end Finalize;

   procedure Validate_Content
     (Content : String; Result : out Validation; Status : out E.Error_Info;
      Max_Bytes : Byte_Limit := Byte_Limit'Last)
   is
      Previous : String (1 .. 64) := [others => '0'];
      Begun, Ended, Generating, Has_Input : Boolean := False;
      Exact : Boolean := True;
      Selected, Committed, Open_Calls : Natural := 0;
      Last_Selected : Long_Long_Integer := -1;
      Terminal, Was_Committed : Boolean := False;
      Next_Call, Next_Result : Natural := 1;
      Vocabulary_Size, Max_Tokens : Long_Long_Integer := 0;

      procedure Refuse (Detail : String) is
      begin
         Result.Complete := False;
         Status := E.Make (E.IO_Read_Failed);
         E.Add_Text (Status, "path", "embedded trajectory");
         E.Add_Text (Status, "detail", Detail);
      end Refuse;

      procedure Read_Line (Line : String) is
         Envelope, Data : J.Document;
         Error : Jsonlib.Errors.Error_Info;
         Root, Body_Of : J.Node;
         function Field (Name : String) return J.Node is (J.Member (Data, Body_Of, Name));
         function Int (Name : String) return Long_Long_Integer is (J.As_Integer (Data, Field (Name)));
         function Text (Name : String) return String is (J.As_String (Data, Field (Name)));
         function Is_Integer (Name : String) return Boolean is (Value_Kind_Of (Data, Field (Name)) = J.Integer_Value);
         Kind : Event_Kind;
      begin
         if Line'Length > 4 * 1_024 * 1_024 then
            Refuse ("trajectory event exceeds its four-megabyte bound");
            return;
         end if;
         Jsonlib.Parsers.Parse (Line, Envelope, Error);
         Root := J.Root (Envelope);
         if Error.Code /= Jsonlib.Errors.No_Error or else Value_Kind_Of (Envelope, Root) /= J.Object_Value
           or else J.Length (Envelope, Root) /= 4
           or else Value_Kind_Of (Envelope, J.Member (Envelope, Root, "sequence")) /= J.Integer_Value
           or else J.As_Integer (Envelope, J.Member (Envelope, Root, "sequence"))
                     /= Long_Long_Integer (Result.Events) + 1
           or else Value_Kind_Of (Envelope, J.Member (Envelope, Root, "kind")) /= J.String_Value
           or else Value_Kind_Of (Envelope, J.Member (Envelope, Root, "payload")) /= J.String_Value
           or else Value_Kind_Of (Envelope, J.Member (Envelope, Root, "sha256")) /= J.String_Value
           or else Ended
         then
            Refuse ("invalid trajectory envelope or event sequence");
            return;
         end if;
         declare
            Name : constant String := J.As_String (Envelope, J.Member (Envelope, Root, "kind"));
            Payload : constant String := J.As_String (Envelope, J.Member (Envelope, Root, "payload"));
            Hash : constant String := Digest (Previous, Result.Events + 1, Name, Payload);
            Known : Boolean := False;
         begin
            for Value in Event_Kind loop
               if Word (Value) = Name then
                  Kind := Value;
                  Known := True;
                  exit;
               end if;
            end loop;
            if not Known or else Hash /= J.As_String (Envelope, J.Member (Envelope, Root, "sha256")) then
               Refuse ("unknown event or trajectory digest mismatch");
               return;
            end if;
            Jsonlib.Parsers.Parse (Payload, Data, Error);
            Body_Of := J.Root (Data);
            if Error.Code /= Jsonlib.Errors.No_Error or else Value_Kind_Of (Data, Body_Of) /= J.Object_Value then
               Refuse ("trajectory payload must be a complete JSON object");
               return;
            end if;
            Previous := Hash;
         end;
         if not Begun and then Kind /= Episode_Start then
            Refuse ("trajectory is missing its start");
            return;
         end if;
         case Kind is
            when Episode_Start =>
               if Begun or else not Is_Integer ("schema_version") or else Int ("schema_version") /= 1
                 or else Value_Kind_Of (Data, Field ("metadata")) /= J.Object_Value
                 or else Value_Kind_Of (Data, Field ("provenance")) /= J.Object_Value
               then
                  Refuse ("invalid or repeated trajectory start");
                  return;
               end if;
               Begun := True;
               Result.Metadata := To_Unbounded_String (Jsonlib.Serializers.To_String (Data));
            when Generation_Start =>
               if Generating or else Open_Calls /= 0
                 or else not Is_Integer ("vocabulary_size") or else Int ("vocabulary_size") not in 0 .. 2 ** 31 - 1
                 or else not Is_Integer ("max_tokens")
                 or else Int ("max_tokens") not in 0 .. Long_Long_Integer (Natural'Last)
                 or else Value_Kind_Of (Data, Field ("sampling_ada")) /= J.String_Value
                 or else Value_Kind_Of (Data, Field ("request_ada")) /= J.String_Value
                 or else Value_Kind_Of (Data, Field ("grammar_constrained")) /= J.Boolean_Value
                 or else Value_Kind_Of (Data, Field ("stop_tokens")) /= J.Array_Value
                 or else Value_Kind_Of (Data, Field ("stop_strings_hex")) /= J.Array_Value
               then
                  Refuse ("generation overlaps pending work or is missing its effective controls");
                  return;
               end if;
               if J.As_Boolean (Data, Field ("grammar_constrained"))
                 and then Value_Kind_Of (Data, Field ("grammar")) /= J.Object_Value
               then
                  Refuse ("constrained generation is missing its compiled grammar");
                  return;
               end if;
               Vocabulary_Size := Int ("vocabulary_size");
               Max_Tokens := Int ("max_tokens");
               Generating := True;
               Has_Input := False;
               Selected := 0;
               Committed := 0;
               Was_Committed := True;
               Result.Generations := Result.Generations + 1;
            when Model_Input =>
               if not Generating or else Has_Input or else not Is_Integer ("loss_mask")
                 or else Int ("loss_mask") /= 0 or else Value_Kind_Of (Data, Field ("prompt")) /= J.String_Value
                 or else Value_Kind_Of (Data, Field ("tokens")) /= J.Array_Value
               then
                  Refuse ("invalid model input boundary or mask");
                  return;
               end if;
               for Index in 1 .. J.Length (Data, Field ("tokens")) loop
                  declare
                     Token : constant J.Node := J.Element (Data, Field ("tokens"), Index);
                  begin
                     if Value_Kind_Of (Data, Token) /= J.Integer_Value or else J.As_Integer (Data, Token) < 0
                       or else J.As_Integer (Data, Token) >= Vocabulary_Size
                     then
                        Refuse ("invalid input token ID");
                        return;
                     end if;
                  end;
               end loop;
               Has_Input := True;
            when Selected_Token =>
               if not Generating or else not Has_Input or else not Was_Committed or else not Is_Integer ("id")
                 or else Int ("id") < 0 or else Int ("id") >= Vocabulary_Size
                 or else Long_Long_Integer (Selected) >= Max_Tokens or else not Is_Integer ("loss_mask")
                 or else Int ("loss_mask") /= 1 or else Value_Kind_Of (Data, Field ("terminal")) /= J.Boolean_Value
                 or else Value_Kind_Of (Data, Field ("piece_hex")) /= J.String_Value
                 or else Text ("piece_hex")'Length mod 2 /= 0
                 or else (for some C of Text ("piece_hex") => C not in '0' .. '9' | 'a' .. 'f')
               then
                  Refuse ("invalid selected token, mask or byte encoding");
                  return;
               end if;
               Last_Selected := Int ("id");
               Terminal := J.As_Boolean (Data, Field ("terminal"));
               Was_Committed := False;
               Selected := Selected + 1;
               Result.Selected_Tokens := Result.Selected_Tokens + 1;
            when Committed_Token =>
               if not Generating or else Was_Committed or else Terminal
                 or else not Is_Integer ("id") or else Int ("id") /= Last_Selected
               then
                  Refuse ("commit does not match its selected token");
                  return;
               end if;
               Was_Committed := True;
               Committed := Committed + 1;
               Result.Committed_Tokens := Result.Committed_Tokens + 1;
            when Generation_End =>
               if not Generating or else not Is_Integer ("generated_tokens")
                 or else Int ("generated_tokens") /= Long_Long_Integer (Committed)
                 or else Selected < Committed or else Selected > Committed + 1
                 or else Value_Kind_Of (Data, Field ("reason")) /= J.String_Value
               then
                  Refuse ("generation end or committed-token count mismatch");
                  return;
               end if;
               Generating := False;
               Exact := Exact and then Has_Input;
            when Tool_Call =>
               if Generating or else not Is_Integer ("id") or else Int ("id") /= Long_Long_Integer (Next_Call)
                 or else Value_Kind_Of (Data, Field ("name")) /= J.String_Value
                 or else Value_Kind_Of (Data, Field ("arguments")) /= J.String_Value
               then
                  Refuse ("invalid tool call order");
                  return;
               end if;
               Next_Call := Next_Call + 1;
               Open_Calls := Open_Calls + 1;
            when Tool_Result =>
               if Generating or else Open_Calls = 0 or else not Is_Integer ("id")
                 or else Int ("id") /= Long_Long_Integer (Next_Result)
                 or else Value_Kind_Of (Data, Field ("text")) /= J.String_Value
                 or else Value_Kind_Of (Data, Field ("ending")) /= J.String_Value
               then
                  Refuse ("tool result has no matching ordered call");
                  return;
               end if;
               Next_Result := Next_Result + 1;
               Open_Calls := Open_Calls - 1;
            when Forced_Text =>
               if Generating or else not Is_Integer ("loss_mask") or else Int ("loss_mask") /= 0
                 or else Value_Kind_Of (Data, Field ("text")) /= J.String_Value
               then
                  Refuse ("forced text must be distinct from sampled tokens with mask zero");
                  return;
               end if;
            when Ineligible =>
               Exact := False;
            when Episode_End =>
               if Generating or else Value_Kind_Of (Data, Field ("reason")) /= J.String_Value
                 or else Value_Kind_Of (Data, Field ("complete")) /= J.Boolean_Value
                 or else not J.As_Boolean (Data, Field ("complete"))
                 or else Value_Kind_Of (Data, Field ("children")) /= J.Array_Value
               then
                  Refuse ("trajectory ended with an unfinished generation or incomplete footer");
                  return;
               end if;
               Ended := True;
               Result.Outcome := To_Unbounded_String (Text ("reason"));
               Result.Children := To_Unbounded_String (Jsonlib.Serializers.To_String (Data, Field ("children")));
               for Index in 1 .. J.Length (Data, Field ("children")) loop
                  declare
                     Child : constant J.Node := J.Element (Data, Field ("children"), Index);
                  begin
                     if Value_Kind_Of (Data, Child) /= J.Object_Value
                       or else Value_Kind_Of (Data, J.Member (Data, Child, "path")) /= J.String_Value
                       or else Value_Kind_Of (Data, J.Member (Data, Child, "sha256")) /= J.String_Value
                       or else Value_Kind_Of (Data, J.Member (Data, Child, "call")) /= J.Integer_Value
                       or else J.As_Integer (Data, J.Member (Data, Child, "call")) not in 1
                         .. Long_Long_Integer (Next_Call - 1)
                     then
                        Refuse ("invalid child trajectory binding");
                        return;
                     end if;
                  end;
               end loop;
            when Output_Text =>
               if not Generating or else not Has_Input
                 or else Value_Kind_Of (Data, Field ("text")) /= J.String_Value
               then
                  Refuse ("generated output is outside its generation");
                  return;
               end if;
            when Context =>
               if Generating or else Value_Kind_Of (Data, Field ("messages")) /= J.Array_Value then
                  Refuse ("conversation context is missing or overlaps generation");
                  return;
               end if;
               for Index in 1 .. J.Length (Data, Field ("messages")) loop
                  declare
                     Message : constant J.Node := J.Element (Data, Field ("messages"), Index);
                  begin
                     if Value_Kind_Of (Data, Message) /= J.Object_Value
                       or else Value_Kind_Of (Data, J.Member (Data, Message, "role")) /= J.String_Value
                       or else J.As_String (Data, J.Member (Data, Message, "role"))
                         not in "system" | "developer" | "user" | "assistant" | "tool"
                       or else Value_Kind_Of (Data, J.Member (Data, Message, "content")) /= J.String_Value
                       or else Value_Kind_Of (Data, J.Member (Data, Message, "calls")) /= J.Array_Value
                       or else Value_Kind_Of (Data, J.Member (Data, Message, "parts")) /= J.String_Value
                     then
                        Refuse ("conversation message is missing its role, content, parts or parsed calls");
                        return;
                     end if;
                  end;
               end loop;
            when Raw_Reply =>
               if Generating or else Value_Kind_Of (Data, Field ("text")) /= J.String_Value then
                  Refuse ("raw reply is missing or outside its generation boundary");
                  return;
               end if;
            when Compaction | Retry =>
               null;
         end case;
         Result.Events := Result.Events + 1;
      end Read_Line;
   begin
      Result := (others => <>);
      Status := E.Success;
      if Content'Length > Max_Bytes then
         Status := E.Make (E.IO_Input_Too_Large);
         return;
      end if;
      Result.File_Digest := To_Unbounded_String (GNAT.SHA256.Digest (Content));
      declare
         Text : constant String := Content;
         First : Positive := Text'First;
      begin
         for Index in Text'Range loop
            if Text (Index) = ASCII.LF then
               Read_Line (Text (First .. Index - 1));
               exit when E.Is_Error (Status);
               First := Index + 1;
            end if;
         end loop;
         if E.Is_Ok (Status) and then (not Ended or else First <= Text'Last) then
            Refuse ("trajectory is truncated or missing its final newline/footer");
         end if;
      end;
      if E.Is_Ok (Status) then
         Result.Complete := Ended;
         Result.Exact_Tokens := Exact and then Result.Generations > 0;
         Result.Last_Digest := To_Unbounded_String (Previous);
         Result.Unanswered_Calls := Open_Calls;
      end if;
   exception
      when others =>
         Refuse ("cannot parse or validate trajectory");
   end Validate_Content;

   procedure Validate
     (File_Name : String; Result : out Validation; Status : out E.Error_Info;
      Max_Bytes : Byte_Limit := Byte_Limit'Last)
   is
      Remaining : Natural := Max_Bytes;
      Visited : array (1 .. 1_024) of Unbounded_String;
      Count : Natural := 0;

      procedure Walk (Path : String; Depth : Natural; Into : out Validation; Status : out E.Error_Info) is
         File : IO.File_Type;
         type Buffer_Access is access Ada.Streams.Stream_Element_Array;
         procedure Free is new Ada.Unchecked_Deallocation (Ada.Streams.Stream_Element_Array, Buffer_Access);
         Buffer : Buffer_Access;
         Last : Ada.Streams.Stream_Element_Offset;
         Canonical : constant String := Hostkit.Fs.Canonical_Path (Path);
         Children : J.Document;
         Error : Jsonlib.Errors.Error_Info;

         procedure Refuse (Detail : String) is
         begin
            Into.Complete := False;
            Status := E.Make (E.IO_Read_Failed);
            E.Add_Text (Status, "path", Path);
            E.Add_Text (Status, "detail", Detail);
         end Refuse;
      begin
         Into := (others => <>);
         Status := E.Success;
         if Depth > 32 or else Count = Visited'Length or else Canonical = ""
           or else Ada.Strings.Fixed.Tail (Path, 8) = ".partial" or else Hostkit.Fs.Is_Link (Path)
           or else Hostkit.Fs.Kind_Of (Path) /= Hostkit.Fs.Ordinary_File_Entry
         then
            Refuse ("trajectory must be a complete regular file within the family limits");
            return;
         end if;
         for Index in 1 .. Count loop
            if To_String (Visited (Index)) = Canonical then
               Refuse ("duplicate or cyclic child trajectory");
               return;
            end if;
         end loop;
         Count := Count + 1;
         Visited (Count) := To_Unbounded_String (Canonical);
         Hostkit.Fs.Open_Stream (File, IO.In_File, Path);
         if IO.Size (File) > IO.Count (Remaining) then
            IO.Close (File);
            Status := E.Make (E.IO_Input_Too_Large);
            return;
         end if;
         Buffer := new Ada.Streams.Stream_Element_Array (1 .. Ada.Streams.Stream_Element_Offset (IO.Size (File)));
         IO.Read (File, Buffer.all, Last);
         IO.Close (File);
         if Last /= Buffer.all'Last then
            Free (Buffer);
            Refuse ("trajectory changed or was shortened while reading");
            return;
         end if;
         Remaining := Remaining - Natural (Last);
         declare
            Text : String (1 .. Natural (Last)) with Import, Address => Buffer.all'Address;
         begin
            Validate_Content (Text, Into, Status, Max_Bytes);
         end;
         Free (Buffer);
         if E.Is_Error (Status) then
            E.Add_Text (Status, "path", Path);
            return;
         end if;
         Jsonlib.Parsers.Parse (To_String (Into.Children), Children, Error);
         for Index in 1 .. J.Length (Children, J.Root (Children)) loop
            declare
               Row : constant J.Node := J.Element (Children, J.Root (Children), Index);
               Child_Path : constant String := J.As_String (Children, J.Member (Children, Row, "path"));
               Child_Digest : constant String := J.As_String (Children, J.Member (Children, Row, "sha256"));
               Call : constant Long_Long_Integer := J.As_Integer (Children, J.Member (Children, Row, "call"));
               Root_Path : constant String := Ada.Directories.Containing_Directory
                 (Ada.Directories.Containing_Directory (Canonical));
               Child_Canonical : constant String := Hostkit.Fs.Canonical_Path (Child_Path);
               Child : Validation;
               Metadata : J.Document;
            begin
               if Child_Canonical'Length <= Root_Path'Length
                 or else Child_Canonical (Child_Canonical'First
                                          .. Child_Canonical'First + Root_Path'Length - 1) /= Root_Path
                 or else not Hostkit.Path_Text.Is_Separator_In
                   (Child_Canonical, Child_Canonical (Child_Canonical'First + Root_Path'Length))
               then
                  Refuse ("child trajectory is outside the selected private capture directory");
                  return;
               end if;
               Walk (Child_Path, Depth + 1, Child, Status);
               if E.Is_Error (Status) then
                  Into.Complete := False;
                  return;
               end if;
               Jsonlib.Parsers.Parse (To_String (Child.Metadata), Metadata, Error);
               declare
                  M : constant J.Node := J.Member (Metadata, J.Root (Metadata), "metadata");
               begin
                  if To_String (Child.Last_Digest) /= Child_Digest
                    or else J.As_String (Metadata, J.Member (Metadata, M, "parent_episode")) /= Canonical
                    or else J.As_Integer (Metadata, J.Member (Metadata, M, "parent_call")) /= Call
                  then
                     Refuse ("child digest or parent-call binding does not match");
                     return;
                  end if;
               end;
               Into.Exact_Tokens := Into.Exact_Tokens and then Child.Exact_Tokens;
               Into.Child_Episodes := Into.Child_Episodes + 1 + Child.Child_Episodes;
            end;
         end loop;
      exception
         when others =>
            if IO.Is_Open (File) then
               IO.Close (File);
            end if;
            Free (Buffer);
            Refuse ("cannot read or validate trajectory family");
      end Walk;
   begin
      Walk (File_Name, 0, Result, Status);
   end Validate;
end Model_Runner.Trajectories;
