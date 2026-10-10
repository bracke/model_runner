with Ada.Calendar.Formatting;
with Ada.Characters.Handling;
with Ada.Directories;
with Ada.Strings.Fixed;
with Ada.Environment_Variables;
with Ada.Streams.Stream_IO;
with Ada.Unchecked_Deallocation;

with GNAT.OS_Lib;

with Hostkit.Metadata;

with Model_Runner.Conversation;
with Model_Runner.Processes;

with Http_Client.Clients;
with Http_Client.Errors;

with Model_Runner.Cancellation;
with Model_Runner.Agent_Runtime;
with Model_Runner.Framework.Permissions;
with Model_Runner.Tools.DOC;
with Model_Runner.Tools.Editing;
with Model_Runner.Tools.OOXML;
with Model_Runner.Tools.PDF;
with Model_Runner.Tools.Registry;
with Model_Runner.Tools.RTF;
with Model_Runner.Tools.Text_Util;
with Model_Runner.UTF8;

package body Model_Runner.Tools.Builtin is

   package E renames Model_Runner.Errors;
   package N renames Model_Runner.Numerics;
   package U renames Ada.Strings.Unbounded;

   use type N.Real;
   use type N.Element_Count;

   --  The most a tool answers with, leaving room under the call buffer for
   --  a truncation note.
   Cap : constant := Model_Runner.Tools.Max_Call_Bytes - 64;

   --  How long a spawned command -- a shell, python, curl, sqlite -- may run
   --  before it is stopped. A tool that hangs would hang the whole loop,
   --  which the agent's own wall-clock budget cannot cut short because it is
   --  only checked between steps, never inside a call. This is the bound
   --  inside the call.
   Tool_Timeout : constant Duration := 30.0;

   --  The tools that take a path in the tree, and of them those that write:
   --  the registry's.
   function File_Tool (Named : String) return Boolean is
     (Model_Runner.Tools.Registry."/=" (Model_Runner.Tools.Registry.Path_Of (Named),
                                         Model_Runner.Tools.Registry.No_Path));
   function Writes (Named : String) return Boolean is
     (Model_Runner.Tools.Registry."=" (Model_Runner.Tools.Registry.Path_Of (Named),
                                        Model_Runner.Tools.Registry.Writes_Path));

   ---------------------------------------------------------------------------
   --  Definitions
   --
   --  Two objects share the four pure tools' text: the pure set the eval
   --  offers, and the full set the command line offers. Written once so a
   --  tool cannot be described in one place and not the other.
   ---------------------------------------------------------------------------

   package Rg renames Model_Runner.Tools.Registry;

   --  A tool's name, as a table holds it.
   type Word is access constant String;
   function W (Text : String) return Word is (new String'(Text));

   --  The definitions, from the registry: the four pure tools the eval
   --  offers, and every built-in one.
   function Definitions_Text return String is
     (Rg.Offered ([Rg.Facts => True, others => False]));

   function All_Definitions_Text return String is
     (Rg.Offered ([Rg.Project_Graph | Rg.Project_Checks => False, others => True]));

   ------------------
   -- Offered_Text --
   ------------------

   function Offered_Text (Self : Instance) return String is
     (Rg.Offered
        (Model_Runner.Agent_Runtime.Run_Capabilities
           (May_Delegate => Self.Sub /= null, May_Ask => Self.Asker /= null)));

   ---------------------------------------------------------------------------
   --  Reading arguments (a walk over the top level of one JSON object)
   ---------------------------------------------------------------------------

   function After_String (Text : String; Index : Positive) return Positive is
      I : Natural := Index + 1;
   begin
      while I <= Text'Last loop
         if Text (I) = '\' then
            I := I + 2;
         elsif Text (I) = '"' then
            return I + 1;
         else
            I := I + 1;
         end if;
      end loop;
      return Text'Last + 1;
   end After_String;

   --  The string that opens at Index, as it means: decoded as the call's
   --  identity decodes it (Conversation.Unescaped), \uXXXX and surrogate
   --  pairs included -- two readings of one call's JSON told the agent loop
   --  two calls apart that the tool ran as one.
   function String_Content (Text : String; Index : Positive) return String is
      I : Natural := Index + 1;
   begin
      while I <= Text'Last and then Text (I) /= '"' loop
         I := I + (if Text (I) = '\' and then I < Text'Last then 2 else 1);
      end loop;
      return Model_Runner.Conversation.Unescaped (Text (Index + 1 .. Natural'Min (I - 1, Text'Last)));
   end String_Content;

   procedure Locate
     (Args  : String;
      Key   : String;
      First : out Natural;
      Last  : out Natural;
      Found : out Boolean)
   is
      I     : Natural := Args'First;
      Depth : Natural := 0;
   begin
      First := 0;
      Last  := 0;
      Found := False;

      while I <= Args'Last and then Args (I) /= '{' loop
         I := I + 1;
      end loop;
      if I > Args'Last then
         return;
      end if;
      I := I + 1;

      loop
         while I <= Args'Last and then Args (I) in ' ' | ASCII.HT
           | ASCII.LF | ASCII.CR
         loop
            I := I + 1;
         end loop;
         exit when I > Args'Last or else Args (I) = '}';

         if Args (I) /= '"' then
            return;
         end if;

         declare
            Key_First : constant Positive := I;
            Key_After : constant Positive := After_String (Args, I);
            This_Key  : constant String :=
              String_Content (Args, Key_First);
         begin
            I := Key_After;
            while I <= Args'Last and then Args (I) in ' ' | ASCII.HT
              | ASCII.LF | ASCII.CR
            loop
               I := I + 1;
            end loop;
            exit when I > Args'Last or else Args (I) /= ':';
            I := I + 1;
            while I <= Args'Last and then Args (I) in ' ' | ASCII.HT
              | ASCII.LF | ASCII.CR
            loop
               I := I + 1;
            end loop;
            exit when I > Args'Last;

            declare
               Value_First : constant Positive := I;
            begin
               case Args (I) is
                  when '"' =>
                     I := After_String (Args, I);
                  when '{' | '[' =>
                     Depth := 1;
                     I := I + 1;
                     while I <= Args'Last and then Depth > 0 loop
                        case Args (I) is
                           when '"'       => I := After_String (Args, I);
                           when '{' | '[' => Depth := Depth + 1; I := I + 1;
                           when '}' | ']' => Depth := Depth - 1; I := I + 1;
                           when others    => I := I + 1;
                        end case;
                     end loop;
                  when others =>
                     while I <= Args'Last
                       and then Args (I) not in ',' | '}' | ']'
                       | ' ' | ASCII.HT | ASCII.LF | ASCII.CR
                     loop
                        I := I + 1;
                     end loop;
               end case;

               if This_Key = Key then
                  First := Value_First;
                  Last  := I - 1;
                  Found := True;
                  return;
               end if;
            end;

            while I <= Args'Last and then Args (I) in ' ' | ASCII.HT
              | ASCII.LF | ASCII.CR
            loop
               I := I + 1;
            end loop;
            exit when I > Args'Last or else Args (I) /= ',';
            I := I + 1;
         end;
      end loop;
   end Locate;

   --  A string argument's decoded content, unbounded so a tool need not size
   --  a buffer for it.
   function Text_Argument (Args : String; Key : String; Found : out Boolean)
     return String
   is
      From, To : Natural;
      Present  : Boolean;
   begin
      Found := False;
      Locate (Args, Key, From, To, Present);
      if not Present or else To < From or else Args (From) /= '"' then
         return "";
      end if;
      Found := True;
      return String_Content (Args, From);
   end Text_Argument;

   procedure Text_List_Argument
     (Args        : String;
      Key         : String;
      Items       : out Schemas.Choice_Lists.Vector;
      Found       : out Boolean;
      Well_Formed : out Boolean)
   is
      From, To : Natural;
      Present  : Boolean;
      I        : Natural;

      procedure Blanks is
      begin
         while I <= To and then Args (I) in ' ' | ASCII.HT | ASCII.LF | ASCII.CR loop
            I := I + 1;
         end loop;
      end Blanks;
   begin
      Items.Clear;
      Found := False;
      Well_Formed := True;
      Locate (Args, Key, From, To, Present);
      if not Present or else To < From then
         return;
      end if;
      Found := True;
      if Args (From) /= '[' then
         Well_Formed := False;
         return;
      end if;
      I := From + 1;
      loop
         Blanks;
         exit when I > To or else Args (I) = ']';
         if Args (I) /= '"' then
            Well_Formed := False;
            Items.Clear;
            return;
         end if;
         Items.Append (String_Content (Args, I));
         I := After_String (Args, I);
         Blanks;
         if I <= To and then Args (I) = ',' then
            I := I + 1;
         end if;
      end loop;
      if I > To then
         Well_Formed := False;
         Items.Clear;
      end if;
   end Text_List_Argument;

   procedure Integer_Argument
     (Args  : String;
      Key   : String;
      Value : out Long_Long_Integer;
      Found : out Boolean)
   is
      From, To : Natural;
      Present  : Boolean;
   begin
      Value := 0;
      Found := False;
      Locate (Args, Key, From, To, Present);
      if not Present or else To < From then
         return;
      end if;

      declare
         Raw  : String renames Args (From .. To);
         Sign : Long_Long_Integer := 1;
         Acc  : Long_Long_Integer := 0;
         I    : Natural := Raw'First;
         Seen : Boolean := False;
      begin
         if I <= Raw'Last and then Raw (I) = '-' then
            Sign := -1;
            I := I + 1;
         end if;
         while I <= Raw'Last and then Raw (I) in '0' .. '9' loop
            declare
               Digit : constant Long_Long_Integer :=
                 Long_Long_Integer (Character'Pos (Raw (I)) - Character'Pos ('0'));
            begin
               --  Past what a whole number here holds: no number, said by
               --  the caller, not an overflow raised out of the parse.
               if Acc > (Long_Long_Integer'Last - Digit) / 10 then
                  return;
               end if;
               Acc := Acc * 10 + Digit;
            end;
            Seen := True;
            I := I + 1;
         end loop;
         if Seen and then I > Raw'Last then
            Value := Sign * Acc;
            Found := True;
         end if;
      end;
   end Integer_Argument;

   function Image (Value : Long_Long_Integer) return String is
      Raw : constant String := Long_Long_Integer'Image (Value);
   begin
      if Raw (Raw'First) = ' ' then
         return Raw (Raw'First + 1 .. Raw'Last);
      else
         return Raw;
      end if;
   end Image;

   --  Fit an answer to what the call buffer holds by keeping its head and its
   --  tail, with the bytes between them dropped and their count noted. The
   --  answer to a call and the summary or error a long output ends with both
   --  survive, and the model is told how much of the middle it is not seeing,
   --  so it can ask again for a narrower slice if it needs the rest.
   function Head_And_Tail (Text : String) return String is
      Head_Budget : constant Natural := (Cap * 3) / 5;
      Tail_Budget : constant Natural := Cap / 4;
      Dropped     : constant Natural := Text'Length - Head_Budget - Tail_Budget;
   begin
      return Text (Text'First .. Text'First + Head_Budget - 1)
        & ASCII.LF & "...[" & Image (Long_Long_Integer (Dropped))
        & " bytes elided]..." & ASCII.LF
        & Text (Text'Last - Tail_Budget + 1 .. Text'Last);
   end Head_And_Tail;

   --  Cut an answer to what the call buffer holds, keeping head and tail.
   function Capped (Text : String) return String is
   begin
      if Text'Length <= Cap then
         return Text;
      end if;
      return Head_And_Tail (Text);
   end Capped;

   ---------------------------------------------------------------------------
   --  The pure tools
   ---------------------------------------------------------------------------

   --  A tool's answer and whether it is a failure, which each tool says
   --  where it fails rather than leaving it to be read back out of the
   --  words. The words of a failure still begin "error: ", for the model.
   --  Halted: Timed_Out or Cancelled where the call's context stopped it,
   --  Answered otherwise. Truncated: the text is not all the tool said.
   --  Tokens: what a child agent generated for it.
   type Reply (Length : Natural) is record
      Failed    : Boolean;
      Changed   : Boolean := False;
      Halted    : Model_Runner.Tools.Runner.Answer_Kind := Model_Runner.Tools.Runner.Answered;
      Truncated : Boolean := False;
      Tokens    : Natural := 0;
      --  For a call that read or wrote a file: its revision then.
      Before_Revision : Model_Runner.Tools.Runner.Revision_Mark := Model_Runner.Tools.Runner.No_Revision;
      After_Revision  : Model_Runner.Tools.Runner.Revision_Mark := Model_Runner.Tools.Runner.No_Revision;
      Created   : Boolean := False;
      Text      : String (1 .. Length);
   end record;

   --  An answer.
   function Said (Text : String) return Reply
   is ((Length => Text'Length, Failed => False, Changed => False, Text => Text, others => <>));

   --  An answer that changed what later calls read: a file written anew.
   function Changed_It (Text : String) return Reply
   is ((Length => Text'Length, Failed => False, Changed => True, Text => Text, others => <>));

   --  A failure, in the words the model is told it in.
   function Failure (Text : String) return Reply
   is ((Length => Text'Length + 7, Failed => True, Changed => False,
        Text => "error: " & Text, others => <>));

   --  The same reply, said to be cut short.
   function Cut (Item : Reply) return Reply
   is ((Length => Item.Length, Failed => Item.Failed, Changed => Item.Changed,
        Halted => Item.Halted, Truncated => True, Tokens => Item.Tokens,
        Before_Revision => Item.Before_Revision, After_Revision => Item.After_Revision,
        Created => Item.Created, Text => Item.Text));

   --  A failure where the call's context stopped it: How says how.
   function Halted_By
     (How : Model_Runner.Tools.Runner.Answer_Kind; Text : String) return Reply
   is ((Length => Text'Length + 7, Failed => True, Changed => False,
        Halted => How, Truncated => False, Tokens => 0, Text => "error: " & Text, others => <>));

   --  The same answer with words before it, failed or not as it was.
   function Prefixed (Before : String; Item : Reply) return Reply
   is ((Length => Before'Length + Item.Length, Failed => Item.Failed,
        Changed => Item.Changed, Halted => Item.Halted, Truncated => Item.Truncated,
        Tokens => Item.Tokens,
        Before_Revision => Item.Before_Revision, After_Revision => Item.After_Revision,
        Created => Item.Created, Text => Before & Item.Text));

   function Calculator (Args : String) return Reply is
      A, B : Long_Long_Integer;
      Found_A, Found_B, Found_Op : Boolean;
      Op : constant String := Text_Argument (Args, "op", Found_Op);

      --  Whether an argument is there, a number past the range or not.
      function Given (Key : String) return Boolean is
         First, Last : Natural;
         Present     : Boolean;
      begin
         Locate (Args, Key, First, Last, Present);
         return Present and then Last >= First and then Args (First) in '0' .. '9' | '-';
      end Given;

      --  Worked in twice the width and held to the range: every grammatical
      --  call has an answer, a result past the range among them.
      type Wide is range -(2 ** 127) .. 2 ** 127 - 1;
      function Fitted (Value : Wide) return Reply
      is (if Value in Wide (Long_Long_Integer'First) .. Wide (Long_Long_Integer'Last)
          then Said (Image (Long_Long_Integer (Value)))
          else Failure ("the result is outside the supported range of whole numbers ("
                        & Image (Long_Long_Integer'First) & " .. " & Image (Long_Long_Integer'Last) & ")"));
   begin
      Integer_Argument (Args, "a", A, Found_A);
      Integer_Argument (Args, "b", B, Found_B);
      if (not Found_A and then Given ("a")) or else (not Found_B and then Given ("b")) then
         return Failure ("a number given is outside the supported range of whole numbers ("
                         & Image (Long_Long_Integer'First) & " .. " & Image (Long_Long_Integer'Last) & ")");
      elsif not (Found_A and then Found_B and then Found_Op) then
         return Failure ("calculator needs integers a and b and an op");
      end if;
      if Op = "+" then
         return Fitted (Wide (A) + Wide (B));
      elsif Op = "-" then
         return Fitted (Wide (A) - Wide (B));
      elsif Op = "*" then
         return Fitted (Wide (A) * Wide (B));
      elsif Op = "/" then
         if B = 0 then
            return Failure ("division by zero");
         else
            return Fitted (Wide (A) / Wide (B));
         end if;
      else
         return Failure ("op must be one of + - * /");
      end if;
   end Calculator;

   function String_Length (Args : String) return Reply is
      Have : Boolean;
      Text : constant String := Text_Argument (Args, "text", Have);
   begin
      if not Have then
         return Failure ("string_length needs a string text");
      end if;
      return Said (Image
        (Long_Long_Integer (Model_Runner.UTF8.Code_Point_Count (Text))));
   end String_Length;

   function Reverse_Text (Args : String) return Reply is
      Have : Boolean;
      Text : constant String := Text_Argument (Args, "text", Have);
   begin
      if not Have then
         return Failure ("reverse_text needs a string text");
      end if;
      declare
         Output : String (1 .. Text'Length);
         Fill   : Natural := Output'Last;
         I      : Natural := Text'First;
         Point  : Natural;
         Width  : Natural;
      begin
         while I <= Text'Last loop
            Model_Runner.UTF8.Decode_First
              (Text (I .. Text'Last), Point, Width);
            exit when Width = 0;
            Output (Fill - Width + 1 .. Fill) := Text (I .. I + Width - 1);
            Fill := Fill - Width;
            I := I + Width;
         end loop;
         return Said (Output);
      end;
   end Reverse_Text;

   function Lookup (Args : String) return Reply is
      Have : Boolean;
      Key  : constant String := Text_Argument (Args, "key", Have);
   begin
      if not Have then
         return Failure ("lookup needs a string key");
      elsif Key = "capital_of_france" then
         return Said ("Paris");
      elsif Key = "speed_of_light" then
         return Said ("299792458 metres per second");
      elsif Key = "ada_year" then
         return Said ("1983");
      else
         return Failure ("no fact by that key");
      end if;
   end Lookup;

   --  Base64, the standard alphabet with = padding.
   Alphabet : constant String :=
     "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

   function Base64_Encode (Args : String) return Reply is
      Have : Boolean;
      Text : constant String := Text_Argument (Args, "text", Have);
   begin
      if not Have then
         return Failure ("base64_encode needs a string text");
      end if;
      declare
         Out_S : U.Unbounded_String;
         I     : Natural := Text'First;
         function Byte (K : Natural) return Natural
         is (Character'Pos (Text (K)));
      begin
         while I <= Text'Last loop
            declare
               B0 : constant Natural := Byte (I);
               Have1 : constant Boolean := I + 1 <= Text'Last;
               Have2 : constant Boolean := I + 2 <= Text'Last;
               B1 : constant Natural := (if Have1 then Byte (I + 1) else 0);
               B2 : constant Natural := (if Have2 then Byte (I + 2) else 0);
            begin
               U.Append (Out_S, Alphabet (Alphabet'First + B0 / 4));
               U.Append
                 (Out_S,
                  Alphabet (Alphabet'First + (B0 mod 4) * 16 + B1 / 16));
               U.Append
                 (Out_S,
                  (if Have1
                   then Alphabet
                          (Alphabet'First + (B1 mod 16) * 4 + B2 / 64)
                   else '='));
               U.Append
                 (Out_S,
                  (if Have2 then Alphabet (Alphabet'First + B2 mod 64)
                   else '='));
            end;
            I := I + 3;
         end loop;
         return Said (Capped (U.To_String (Out_S)));
      end;
   end Base64_Encode;

   function Base64_Decode (Args : String) return Reply is
      Have : Boolean;
      Text : constant String := Text_Argument (Args, "text", Have);

      function Value_Of (C : Character) return Integer is
      begin
         for K in Alphabet'Range loop
            if Alphabet (K) = C then
               return K - Alphabet'First;
            end if;
         end loop;
         return -1;
      end Value_Of;
   begin
      if not Have then
         return Failure ("base64_decode needs a string text");
      end if;
      declare
         Out_S : U.Unbounded_String;
         Bits  : Natural := 0;
         Acc   : Natural := 0;
      begin
         for C of Text loop
            exit when C = '=';
            if C not in ' ' | ASCII.LF | ASCII.CR | ASCII.HT then
               declare
                  V : constant Integer := Value_Of (C);
               begin
                  if V < 0 then
                     return Failure ("not valid base64");
                  end if;
                  Acc := Acc * 64 + V;
                  Bits := Bits + 6;
                  if Bits >= 8 then
                     Bits := Bits - 8;
                     U.Append
                       (Out_S, Character'Val ((Acc / (2 ** Bits)) mod 256));
                  end if;
               end;
            end if;
         end loop;
         return Said (Capped (U.To_String (Out_S)));
      end;
   end Base64_Decode;

   function Now_Text return String is
   begin
      return Ada.Calendar.Formatting.Image (Ada.Calendar.Clock);
   end Now_Text;

   --  A readable file's raw bytes -- a note may hold any, a NUL among them,
   --  which the text reader refuses.
   function Raw_Bytes (Path : String) return String is
      use Ada.Streams;
      use Ada.Streams.Stream_IO;
      File : Stream_IO.File_Type;
   begin
      Open (File, In_File, Path);
      declare
         Length : constant Natural := Natural (Size (File));
         Block  : Stream_Element_Array (1 .. Stream_Element_Offset (Length));
         Last   : Stream_Element_Offset := 0;
         Result : String (1 .. Length);
      begin
         if Length > 0 then
            Read (File, Block, Last);
         end if;
         Close (File);
         for I in 1 .. Natural (Last) loop
            Result (I) := Character'Val (Block (Stream_Element_Offset (I)));
         end loop;
         return Result (1 .. Natural (Last));
      end;
   end Raw_Bytes;

   --  Write the runner's notes to its store file, each note as its key length
   --  and key then its value length and value, so a value with any byte in it
   --  -- a newline, a brace -- reads back whole with no escaping. Put in
   --  place whole or not at all, as a source file is (Editing.Replace): a
   --  save that failed half way emptied the notes a later run would read.
   --  Answers why it could not be kept, or "".
   function Save_Store (Self : Instance) return String is
      Text : U.Unbounded_String;
      Put  : Model_Runner.Tools.Editing.Said;
   begin
      for I in 1 .. Self.Used loop
         declare
            Key   : constant String := U.To_String (Self.Memory (I).Key);
            Value : constant String := U.To_String (Self.Memory (I).Value);
         begin
            U.Append (Text, Image (Long_Long_Integer (Key'Length)) & " " & Key
                      & Image (Long_Long_Integer (Value'Length)) & " " & Value);
         end;
      end loop;
      Model_Runner.Tools.Editing.Replace (U.To_String (Self.Store), U.To_String (Text), Put);
      if Put.Failed then
         return U.To_String (Put.Text);
      elsif not Put.Durable then
         return "the memory file was written but could not be made durable";
      end if;
      return "";
   end Save_Store;

   --  Read the notes from the store into the runner. A file that is not
   --  there is no notes yet; one that is there and will not read, or will
   --  not parse to its last byte, is said -- Failed, and why -- with the
   --  runner left holding no notes, not taken for an empty store: notes
   --  asked to be kept that could not be found again are not nothing.
   procedure Load_Store (Self : in out Instance; Refusal : out U.Unbounded_String) is
      Path : constant String := U.To_String (Self.Store);
      Held : U.Unbounded_String;
      Got  : E.Error_Info;
   begin
      Self.Used := 0;
      Refusal := U.Null_Unbounded_String;
      if Path = "" or else not Ada.Directories.Exists (Path) then
         return;
      end if;
      --  Bytes as they are, read within the bound every text is.
      Model_Runner.Tools.Editing.Read_Text (Path, Held, Got);
      if E.Is_Error (Got) and then E.Text_Of (Got, "detail") /= "it is not text" then
         Refusal := U.To_Unbounded_String ("the memory file " & Path & " could not be read");
         return;
      end if;

      declare
         Data : constant String :=
           (if E.Is_Ok (Got) then U.To_String (Held) else Raw_Bytes (Path));
         Pos  : Natural := Data'First;

         Read      : Notes;
         Read_Used : Natural := 0;

         --  Bytes from Pos to the end, which is how far a length may reach:
         --  asked as a subtraction, so a length near the largest number is
         --  refused rather than added to a position past it.
         function Left return Natural
         is (if Pos > Data'Last then 0 else Data'Last - Pos + 1);

         --  A decimal length followed by one space; Ok is false when what is
         --  there is not that shape, or is a number past what a length can
         --  be, which ends the parse.
         function Read_Length (Ok : out Boolean) return Natural is
            N    : Natural := 0;
            Seen : Boolean := False;
         begin
            Ok := False;
            while Pos <= Data'Last and then Data (Pos) in '0' .. '9' loop
               declare
                  Digit : constant Natural :=
                    Character'Pos (Data (Pos)) - Character'Pos ('0');
               begin
                  if N > (Natural'Last - Digit) / 10 then
                     return 0;
                  end if;
                  N := N * 10 + Digit;
               end;
               Pos  := Pos + 1;
               Seen := True;
            end loop;
            if Seen and then Pos <= Data'Last and then Data (Pos) = ' ' then
               Pos := Pos + 1;
               Ok  := True;
            end if;
            return N;
         end Read_Length;

         procedure Damaged is
         begin
            Refusal := U.To_Unbounded_String
              ("the memory file " & Path & " is damaged at byte" & Natural'Image (Pos - Data'First + 1)
               & ": it is not notes this reads, and nothing of it was taken");
         end Damaged;
      begin
         while Pos <= Data'Last loop
            declare
               Good_K : Boolean;
               K_Len  : constant Natural := Read_Length (Good_K);
            begin
               if not Good_K or else K_Len > Left then
                  Damaged;
                  return;
               end if;
               declare
                  Key    : constant String := Data (Pos .. Pos + K_Len - 1);
                  Good_V : Boolean;
                  V_Len  : Natural;
               begin
                  Pos   := Pos + K_Len;
                  V_Len := Read_Length (Good_V);
                  if not Good_V or else V_Len > Left then
                     Damaged;
                     return;
                  end if;
                  declare
                     Value : constant String := Data (Pos .. Pos + V_Len - 1);
                  begin
                     Pos := Pos + V_Len;
                     if Read_Used < Max_Notes then
                        Read_Used := Read_Used + 1;
                        Read (Read_Used) :=
                          (Key   => U.To_Unbounded_String (Key),
                           Value => U.To_Unbounded_String (Value));
                     end if;
                  end;
               end;
            end;
         end loop;

         --  Every record parsed, to the last byte: these are the notes.
         Self.Memory := Read;
         Self.Used := Read_Used;
      end;
   end Load_Store;

   procedure Use_Memory_File
     (Self   : in out Instance;
      Path   : String;
      Status : out Model_Runner.Errors.Error_Info)
   is
      Refusal : U.Unbounded_String;
   begin
      Status := E.Success;
      Self.Store := U.To_Unbounded_String (Path);
      Load_Store (Self, Refusal);
      if U.Length (Refusal) > 0 then
         Status := E.Make (E.IO_Read_Failed);
         E.Add_Text (Status, "path", Path, E.Param_Path);
         E.Add_Text (Status, "detail", U.To_String (Refusal));
      end if;
   end Use_Memory_File;

   function Memory_Put (Self : in out Instance; Args : String) return Reply is
      Have_K, Have_V : Boolean;
      Key   : constant String := Text_Argument (Args, "key", Have_K);
      Value : constant String := Text_Argument (Args, "value", Have_V);

      --  "ok" once kept where it was asked to be: a note the file could not
      --  take is said, not answered ok -- the next run would not find it.
      function Kept return Reply is
         Why : constant String :=
           (if U.Length (Self.Store) > 0 then Save_Store (Self) else "");
      begin
         return (if Why = "" then Said ("ok")
                 else Failure ("the note holds for this run, but was not kept for a later one: " & Why));
      end Kept;
   begin
      if not (Have_K and then Have_V) then
         return Failure ("memory_put needs a key and a value");
      end if;
      for I in 1 .. Self.Used loop
         if U.To_String (Self.Memory (I).Key) = Key then
            Self.Memory (I).Value := U.To_Unbounded_String (Value);
            return Kept;
         end if;
      end loop;
      if Self.Used >= Max_Notes then
         return Failure ("memory is full");
      end if;
      Self.Used := Self.Used + 1;
      Self.Memory (Self.Used) :=
        (Key => U.To_Unbounded_String (Key),
         Value => U.To_Unbounded_String (Value));
      return Kept;
   end Memory_Put;

   function Memory_Get (Self : in out Instance; Args : String) return Reply is
      Have : Boolean;
      Key  : constant String := Text_Argument (Args, "key", Have);
   begin
      if not Have then
         return Failure ("memory_get needs a key");
      end if;
      for I in 1 .. Self.Used loop
         if U.To_String (Self.Memory (I).Key) = Key then
            return Said (U.To_String (Self.Memory (I).Value));
         end if;
      end loop;
      return Failure ("nothing remembered under that key");
   end Memory_Get;

   ---------------------------------------------------------------------------
   --  The tools that reach the world
   ---------------------------------------------------------------------------

   --  Read a file into a string, no more than the call buffer holds.
   --  Whether a file looks binary rather than text: its first bytes carry a
   --  NUL, which text does not and most binary formats do. Cheap and bounded
   --  -- a couple of kilobytes -- and a file that will not open is called
   --  binary so retrieve leaves it alone. It keeps a folder's images, PDFs
   --  and archives out of a text search rather than turning them to noise.
   function Is_Binary (Path : String) return Boolean is
      use Ada.Streams;
      File : Stream_IO.File_Type;
      Buf  : Stream_Element_Array (1 .. 2048);
      Last : Stream_Element_Offset;
   begin
      Stream_IO.Open (File, Stream_IO.In_File, Path);
      Stream_IO.Read (File, Buf, Last);
      Stream_IO.Close (File);
      for I in 1 .. Last loop
         if Buf (I) = 0 then
            return True;
         end if;
      end loop;
      return False;
   exception
      --  Not opened, not known to be binary: read as text, its failure is
      --  said -- taken for binary, a file that would not open was passed
      --  over as an image is.
      when others =>
         if Stream_IO.Is_Open (File) then
            Stream_IO.Close (File);
         end if;
         return False;
   end Is_Binary;

   --  The most of a PDF's bytes read to pull text from -- a whole document,
   --  bounded so a huge file cannot fill memory.
   Doc_Bytes : constant := 4 * 1024 * 1024;

   --  Up to Limit of a file's raw bytes, as a String, or the empty string
   --  when it will not open. Unlike Read_Capped, this reads bytes as they
   --  are -- for a binary format like PDF, where a line reader would stop or
   --  mangle at the first NUL.
   function Read_Raw (Path : String; Limit : Positive) return String is
      use Ada.Streams;
      type Buffer is access Stream_Element_Array;
      procedure Free is new Ada.Unchecked_Deallocation (Stream_Element_Array,
                                                         Buffer);
      File : Stream_IO.File_Type;
      Buf  : Buffer := new Stream_Element_Array (1 .. Stream_Element_Offset (Limit));
      Last : Stream_Element_Offset := 0;
   begin
      Stream_IO.Open (File, Stream_IO.In_File, Path);
      Stream_IO.Read (File, Buf.all, Last);
      Stream_IO.Close (File);
      return Result : String (1 .. Natural (Last)) do
         for I in 1 .. Last loop
            Result (Natural (I)) := Character'Val (Integer (Buf (I)));
         end loop;
         Free (Buf);
      end return;
   exception
      when others =>
         if Stream_IO.Is_Open (File) then
            Stream_IO.Close (File);
         end if;
         Free (Buf);
         return "";
   end Read_Raw;

   function Read_Capped (Path : String; Base : String := "") return Reply is
      Disk : constant String := Model_Runner.Tools.Editing.On_Disk (Base, Path);
      use Ada.Streams;
      use Ada.Streams.Stream_IO;
      File : Stream_IO.File_Type;

      function As_String
        (Block : Stream_Element_Array; Last : Stream_Element_Offset)
         return String
      is
         Result : String (1 .. Natural (Last));
      begin
         for I in 1 .. Natural (Last) loop
            Result (I) := Character'Val (Block (Stream_Element_Offset (I)));
         end loop;
         return Result;
      end As_String;
   begin
      --  A directory is listed, not read: said so, with the call that does.
      if Ada.Directories.Exists (Disk)
        and then Ada.Directories."=" (Ada.Directories.Kind (Disk), Ada.Directories.Directory)
      then
         return Failure ("" & Path & " is a directory: list_directory " & Path & " lists it");
      end if;
      Open (File, In_File, Disk);
      declare
         Total : constant Natural := Natural (Size (File));
      begin
         if Total = 0 then
            Close (File);
            return Said ("");
         elsif Total <= Cap then
            --  It fits: return the file whole, byte for byte.
            declare
               Block : Stream_Element_Array (1 .. Stream_Element_Offset (Total));
               Last  : Stream_Element_Offset;
            begin
               Read (File, Block, Last);
               Close (File);
               return Said (As_String (Block, Last));
            end;
         else
            --  Too big for the buffer: read only the head and the tail --
            --  never the middle -- so a huge file costs no more memory than
            --  a fitting one, and note the bytes dropped between them.
            declare
               Head_Budget : constant Natural := (Cap * 3) / 5;
               Tail_Budget : constant Natural := Cap / 4;
               Head_Block  : Stream_Element_Array
                 (1 .. Stream_Element_Offset (Head_Budget));
               Tail_Block  : Stream_Element_Array
                 (1 .. Stream_Element_Offset (Tail_Budget));
               Head_Last, Tail_Last : Stream_Element_Offset;
            begin
               Set_Index (File, 1);
               Read (File, Head_Block, Head_Last);
               Set_Index (File, Positive_Count (Total - Tail_Budget + 1));
               Read (File, Tail_Block, Tail_Last);
               Close (File);
               declare
                  Dropped : constant Natural :=
                    Total - Natural (Head_Last) - Natural (Tail_Last);
               begin
                  return Cut (Said (As_String (Head_Block, Head_Last)
                    & ASCII.LF & "...[" & Image (Long_Long_Integer (Dropped))
                    & " bytes elided]..." & ASCII.LF
                    & As_String (Tail_Block, Tail_Last)));
               end;
            end;
         end if;
      end;
   exception
      when others =>
         if Is_Open (File) then
            Close (File);
         end if;
         return Failure ("could not read the file");
   end Read_Capped;

   --  Run a program, capturing its output (and its errors), and free the
   --  argument list. A program that is not installed is said so plainly.
   function Capture
     (Program : String; Args : GNAT.OS_Lib.Argument_List) return Reply
   is
      package Tr renames Model_Runner.Tools.Runner;
      package Pr renames Model_Runner.Processes;

      --  The run's own limits, as the task running the call entered them:
      --  its cancellation, and its deadline where that comes before the
      --  tool's own. A process outliving either is stopped with its group.
      Context : constant Tr.Tool_Context := Tr.Entered_Context;
      Allowed : constant Duration := Tr.Time_Left (Context, Tool_Timeout);
      Asked   : Pr.Request;

      procedure Release is
      begin
         for A of Args loop
            declare
               Item : GNAT.OS_Lib.String_Access := A;
            begin
               GNAT.OS_Lib.Free (Item);
            end;
         end loop;
      end Release;

      function Seconds (Span : Duration) return String is
         Raw : constant String := Integer'Image (Integer (Span));
      begin
         return Raw (Raw'First + 1 .. Raw'Last);
      end Seconds;
   begin
      if Tr.Stopped (Context) then
         Release;
         return (if Model_Runner.Cancellation.Is_Cancelled (Context.Cancel)
                 then Halted_By (Tr.Cancelled, "the run was cancelled before '" & Program & "' started")
                 else Halted_By (Tr.Timed_Out, "the run's time ran out before '" & Program & "' started"));
      end if;
      Asked.Program := U.To_Unbounded_String (Program);
      for A of Args loop
         Asked.Arguments.Append (U.To_Unbounded_String (A.all));
      end loop;
      Release;
      Asked.Limit := Duration'Max (0.001, Allowed);
      Asked.Cancelled := Tr.Stop_Now'Access;

      declare
         Ran  : constant Pr.Result := Pr.Run (Asked);
         Text : constant String := Pr.Told (Ran, "'" & Program & "'");
      begin
         if not Ran.Started then
            return Failure ("'" & Program & "' is not installed on this machine, or would not run");
         elsif Ran.Stopped and then Model_Runner.Cancellation.Is_Cancelled (Context.Cancel) then
            return Halted_By (Tr.Cancelled, "'" & Program & "' was stopped: the run was cancelled");
         elsif Ran.Stopped and then Allowed < Tool_Timeout then
            return Halted_By (Tr.Timed_Out, "'" & Program & "' was stopped when the run's time ran out, after "
                              & Seconds (Allowed) & " seconds");
         elsif Ran.Stopped then
            return Halted_By (Tr.Timed_Out, "'" & Program & "' did not finish within "
                              & Seconds (Tool_Timeout) & " seconds and was stopped");
         end if;
         --  A failure with its exit status and what it said on its
         --  standard error; an answer as it printed it.
         return (Length => Text'Length, Failed => not Pr.Succeeded (Ran), Changed => False,
                 Halted => Tr.Answered, Truncated => Ran.Truncated, Tokens => 0, Text => Text,
                 others => <>);
      end;
   end Capture;

   --  Why a file tool may not reach its path when the harness started this
   --  program as an agent and said where it works and what it may do, or
   --  nothing when it may -- and always nothing when the harness did not:
   --  a person's own run reaches what the person can.
   function Confinement (Named, Args : String) return String is
      package Pm renames Model_Runner.Framework.Permissions;
      package Env renames Ada.Environment_Variables;
      Have  : Boolean;
      Given : constant String := Text_Argument (Args, "path", Have);
      --  A search of no path is of the whole tree.
      Path  : constant String :=
        (if not Have and then Named in "find" | "search_code" then "." else Given);
   begin
      if not Env.Exists (Pm.Agent_Root_Variable) then
         return "";
      elsif not File_Tool (Named) then
         --  Held where it works, it has the file tools and those that reach
         --  nothing, and the network only where its permissions grant
         --  use_network. A program is run for it by the harness -- its
         --  checks, through the execution policy, their output kept -- and
         --  never by it: a shell of its own would pass the allowed programs,
         --  the limits, the network cut and the roots it may write by. A
         --  tool that reads a whole folder would take it past what the file
         --  tools check, and is never its.
         declare
            Allowed : constant Pm.Permission_Set :=
              (if Env.Exists (Pm.Agent_Permissions_Variable)
               then Pm.Value (Env.Value (Pm.Agent_Permissions_Variable))
               else Pm.Nothing);
         begin
            return (if Named in "calculator" | "string_length" | "reverse_text" | "lookup"
                              | "base64_encode" | "base64_decode" | "now"
                              | "memory_put" | "memory_get"
                    then ""
                    elsif Named in "http_get" | "web_search"
                      and then Pm.Allows (Allowed, Pm.Use_Network)
                    then ""
                    else "an agent the harness started does not use " & Named
                         & (if Named in "shell" | "run_python"
                            then ": the harness runs programs, by its checks"
                            elsif Named in "http_get" | "web_search"
                            then " without use_network" else ""));
         end;
      end if;
      return Pm.Path_Refusal
        (Env.Value (Pm.Agent_Root_Variable), Path,
         Writing => Writes (Named),
         Allowed =>
           (if Env.Exists (Pm.Agent_Permissions_Variable)
            then Pm.Value (Env.Value (Pm.Agent_Permissions_Variable))
            else Pm.Nothing));
   end Confinement;

   --  The verdict on a file tool's path where Confinement refuses it.
   function Confined_Path_Verdict
     (Named, Args : String) return Model_Runner.Framework.Permissions.Path_Verdict
   is
      package Pm renames Model_Runner.Framework.Permissions;
      package Env renames Ada.Environment_Variables;
      Have  : Boolean;
      Given : constant String := Text_Argument (Args, "path", Have);
      --  A search of no path is of the whole tree.
      Path  : constant String :=
        (if not Have and then Named in "find" | "search_code" then "." else Given);
   begin
      if not Env.Exists (Pm.Agent_Root_Variable) then
         return Pm.Path_Allowed;
      end if;
      return Pm.Path_Refused_As
        (Env.Value (Pm.Agent_Root_Variable), Path,
         Writing => Writes (Named),
         Allowed =>
           (if Env.Exists (Pm.Agent_Permissions_Variable)
            then Pm.Value (Env.Value (Pm.Agent_Permissions_Variable))
            else Pm.Nothing));
   end Confined_Path_Verdict;

   --  Where an agent the harness started names a path from the root --
   --  /src/a.adb -- that is a place in the project, or for a file to be
   --  written one whose directory is: that place, relative; "" otherwise.
   function Rooted (Named, Args : String) return String is
      package Pm renames Model_Runner.Framework.Permissions;
      package Env renames Ada.Environment_Variables;
      Have : Boolean;
      Path : constant String := Text_Argument (Args, "path", Have);
   begin
      if not Env.Exists (Pm.Agent_Root_Variable) or else Path'Length < 2 or else Path (Path'First) /= '/'
        or else Ada.Strings.Fixed.Index (Path, "..") > 0
      then
         return "";
      end if;
      declare
         Root    : constant String := Env.Value (Pm.Agent_Root_Variable);
         --  The project's own name, a workspace's tree's too: /demo/a.txt
         --  in the project demo is a.txt, not demo/a.txt.
         State   : constant Natural := Ada.Strings.Fixed.Index (Root, "/.model_runner/");
         Project : constant String :=
           Ada.Directories.Simple_Name (if State > Root'First then Root (Root'First .. State - 1) else Root);
         Bare    : constant String :=
           (if Path (Path'Last) = '/' then Path (Path'First + 1 .. Path'Last - 1)
            else Path (Path'First + 1 .. Path'Last));
         --  /demo, the project itself, is its top: listed as . is.
         Given   : constant String := (if Bare = Project then Project & "/." else Bare);
         Named_Project : constant Boolean :=
           Given'Length > Project'Length + 1
           and then Given (Given'First .. Given'First + Project'Length) = Project & "/";
         Tail    : constant String :=
           (if Named_Project then Given (Given'First + Project'Length + 1 .. Given'Last) else Given);
         Whole   : constant String := Root & "/" & Tail;
      begin
         if Ada.Directories.Exists (Whole)
           --  A file to be written: where its directory is, and -- named
           --  under the project's own name -- at the top of it too.
           or else (Writes (Named)
                    and then (Ada.Strings.Fixed.Index (Tail, "/") > 0 or else Named_Project)
                    and then Ada.Directories.Exists (Ada.Directories.Containing_Directory (Whole)))
         then
            return Tail;
         end if;
         return "";
      end;
   exception
      when others =>
         return "";
   end Rooted;

   --  A file whole, and its revision after it, for edit_file to be given.
   function Read_File (Args : String; Base : String) return Reply is
      Have : Boolean;
      Path : constant String := Text_Argument (Args, "path", Have);
   begin
      if not Have then
         return Failure ("read_file needs a path");
      elsif not Ada.Directories.Exists (Model_Runner.Tools.Editing.On_Disk (Base, Path)) then
         return Failure ("no file at " & Path);
      end if;
      declare
         Read : constant Reply := Read_Capped (Path, Base);
         Now  : constant String := Model_Runner.Tools.Editing.Revision_Of (Path, Base);
      begin
         if Read.Failed or else Now = "" then
            return Read;
         end if;
         declare
            Text : constant String := Read.Text & ASCII.LF & "(revision " & Now & ")";
         begin
            return (Length => Text'Length, Failed => False, Changed => False,
                    Halted => Read.Halted, Truncated => Read.Truncated, Tokens => 0,
                    Before_Revision => Model_Runner.Tools.Runner.Mark (Now),
                    After_Revision  => Model_Runner.Tools.Runner.Mark (Now),
                    Created => False, Text => Text);
         end;
      end;
   end Read_File;

   --  What the editing package said, as a reply.
   function As_Reply (Item : Model_Runner.Tools.Editing.Said) return Reply is
      Text : constant String := U.To_String (Item.Text);
   begin
      return (Length => Text'Length, Failed => Item.Failed, Changed => Item.Changed,
              Halted => Model_Runner.Tools.Runner.Answered, Truncated => Item.Truncated,
              Tokens => 0,
              Before_Revision => Model_Runner.Tools.Runner.Mark (U.To_String (Item.Before_Revision)),
              After_Revision  => Model_Runner.Tools.Runner.Mark (U.To_String (Item.After_Revision)),
              Created => Item.Created, Text => Text);
   end As_Reply;

   --  A reply with the revisions a change left, as values.
   function With_Revisions (Given : Reply; Put : Model_Runner.Tools.Editing.Said) return Reply is
      Result : Reply := Given;
   begin
      Result.Before_Revision := Model_Runner.Tools.Runner.Mark (U.To_String (Put.Before_Revision));
      Result.After_Revision := Model_Runner.Tools.Runner.Mark (U.To_String (Put.After_Revision));
      Result.Created := Put.Created;
      return Result;
   end With_Revisions;

   function Edit_File (Args : String; Base : String) return Reply is
      Have_P, Have_O, Have_N, Have_R : Boolean;
      Path : constant String := Text_Argument (Args, "path", Have_P);
      Old  : constant String := Text_Argument (Args, "old_text", Have_O);
      Neww : constant String := Text_Argument (Args, "new_text", Have_N);
      Rev  : constant String := Text_Argument (Args, "revision", Have_R);
   begin
      if not (Have_P and then Have_O and then Have_N) then
         return Failure ("edit_file needs a path, old_text and new_text");
      end if;
      return As_Reply (Model_Runner.Tools.Editing.Edit (Path, Old, Neww, Rev, Base));
   end Edit_File;

   --  An edit, taken where it starts within lines last read when it is
   --  in more than one place.
   function Edit_File_Near (Args : String; Base : String; First, Last : Natural) return Reply is
      Have_P, Have_O, Have_N, Have_R : Boolean;
      Path : constant String := Text_Argument (Args, "path", Have_P);
      Old  : constant String := Text_Argument (Args, "old_text", Have_O);
      Neww : constant String := Text_Argument (Args, "new_text", Have_N);
      Rev  : constant String := Text_Argument (Args, "revision", Have_R);
   begin
      if not (Have_P and then Have_O and then Have_N) then
         return Failure ("edit_file needs a path, old_text and new_text");
      end if;
      return As_Reply (Model_Runner.Tools.Editing.Edit (Path, Old, Neww, Rev, Base, First, Last));
   end Edit_File_Near;

   function Read_Range (Args : String; Base : String) return Reply is
      Have, Have_F, Have_L : Boolean;
      Path  : constant String := Text_Argument (Args, "path", Have);
      First, Last : Long_Long_Integer := 0;
   begin
      Integer_Argument (Args, "first_line", First, Have_F);
      Integer_Argument (Args, "last_line", Last, Have_L);
      if not (Have and then Have_F) then
         return Failure ("read_range needs a path and a first_line");
      end if;
      return As_Reply
        (Model_Runner.Tools.Editing.Read_Range
           (Path, Natural (Long_Long_Integer'Max (0, Long_Long_Integer'Min (First, 100_000_000))),
            (if Have_L then Natural (Long_Long_Integer'Max (0, Long_Long_Integer'Min (Last, 100_000_000)))
             else 0), Base));
   end Read_Range;

   function Search_File (Args : String; Base : String) return Reply is
      Have_P, Have_T : Boolean;
      Path    : constant String := Text_Argument (Args, "path", Have_P);
      Pattern : constant String := Text_Argument (Args, "pattern", Have_T);
   begin
      if not (Have_P and then Have_T) then
         return Failure ("search_file needs a path and a pattern");
      end if;
      return As_Reply (Model_Runner.Tools.Editing.Search_File (Path, Pattern, Base));
   end Search_File;

   function Search_Code (Args : String; Base : String) return Reply is
      Have_P, Have_T : Boolean;
      Path    : constant String := Text_Argument (Args, "path", Have_P);
      Pattern : constant String := Text_Argument (Args, "pattern", Have_T);
   begin
      if not Have_T then
         return Failure ("search_code needs a pattern");
      end if;
      return As_Reply
        (Model_Runner.Tools.Editing.Search_Code ((if Have_P and then Path /= "" then Path else "."), Pattern, Base));
   end Search_Code;

   function Write_File (Args : String; Base : String) return Reply is
      Have_P, Have_C : Boolean;
      Path    : constant String := Text_Argument (Args, "path", Have_P);
      Content : constant String := Text_Argument (Args, "content", Have_C);
      Put     : Model_Runner.Tools.Editing.Said;
   begin
      if not (Have_P and then Have_C) then
         return Failure ("write_file needs "
           & (if not Have_P and then not Have_C then "a path and content"
              elsif not Have_P then "a path"
              else "content: the whole new text of " & Path));
      end if;
      --  Nothing written over something: an empty write of a file that holds
      --  text is refused, not taken -- a 4B wrote "" over the source it was
      --  to fix, and every check after failed on an empty unit.
      declare
         Disk : constant String := Model_Runner.Tools.Editing.On_Disk (Base, Path);
      begin
         if Content = "" and then Ada.Directories.Exists (Disk)
           and then Ada.Directories."=" (Ada.Directories.Kind (Disk), Ada.Directories.Ordinary_File)
           and then Ada.Directories.">" (Ada.Directories.Size (Disk), 0)
         then
            return Failure
              ("write_file with no content would empty " & Path & ", which holds"
               & Ada.Directories.File_Size'Image (Ada.Directories.Size (Disk))
               & " bytes; write its whole new text -- or, where the file should go, say so in your report");
         end if;
      end;
      --  Put in place whole or not at all (Editing.Replace), as bytes, the
      --  way the file is read back: a text file would end the content with
      --  a line break the model never wrote.
      Model_Runner.Tools.Editing.Replace (Path, Content, Put, Base);
      if Put.Failed then
         return As_Reply (Put);
      elsif not Put.Changed then
         --  A file that already holds exactly this is left as it is, and
         --  said so: a write of what is there changes nothing, and is no
         --  progress.
         return With_Revisions
           (Said ("unchanged: " & Path & " already holds these" & Natural'Image (Content'Length) & " bytes"),
            Put);
      end if;
      return With_Revisions
        (Changed_It ("wrote" & Natural'Image (Content'Length) & " bytes to " & Path
                     & Model_Runner.Tools.Editing.Kept_Note (Put)), Put);
   end Write_File;

   function List_Directory (Args : String; Base : String) return Reply is
      Have : Boolean;
      Path : constant String := Text_Argument (Args, "path", Have);
      Out_S : U.Unbounded_String;
      Search : Ada.Directories.Search_Type;
      Item   : Ada.Directories.Directory_Entry_Type;
      Disk   : constant String := Model_Runner.Tools.Editing.On_Disk (Base, Path);
   begin
      if not Have then
         return Failure ("list_directory needs a path");
      elsif not Ada.Directories.Exists (Disk) then
         return Failure ("no directory at " & Path);
      elsif Ada.Directories."/=" (Ada.Directories.Kind (Disk), Ada.Directories.Directory) then
         return Failure ("" & Path & " is a file, not a directory: read_file reads it");
      end if;
      Ada.Directories.Start_Search (Search, Disk, "");
      while Ada.Directories.More_Entries (Search)
        and then U.Length (Out_S) <= Cap
      loop
         Ada.Directories.Get_Next_Entry (Search, Item);
         declare
            Name : constant String := Ada.Directories.Simple_Name (Item);
         begin
            if Name /= "." and then Name /= ".." then
               if U.Length (Out_S) > 0 then
                  U.Append (Out_S, ASCII.LF);
               end if;
               U.Append (Out_S, Name);
            end if;
         end;
      end loop;
      Ada.Directories.End_Search (Search);
      return Said (Capped (U.To_String (Out_S)));
   exception
      when others =>
         return Failure ("could not list the directory");
   end List_Directory;

   --  find, by its kind: text in a file or a tree here; what asks a
   --  project's graph only where a project's work runs it.
   function Find (Args : String; Base : String) return Reply is
      Have_K, Have_Q, Have_P : Boolean;
      Kind  : constant String := Text_Argument (Args, "kind", Have_K);
      Query : constant String := Text_Argument (Args, "query", Have_Q);
      Path  : constant String := Text_Argument (Args, "path", Have_P);
      Where : constant String := (if Have_P and then Path /= "" then Path else ".");
   begin
      if not (Have_K and then Have_Q) then
         return Failure ("find needs a kind and a query");
      elsif Rg.Graph_Finding (Kind) then
         return Failure ("find " & Kind & " asks a project's graph, which is not here; find text searches");
      elsif Kind /= "text" then
         return Failure ("find takes kind text" & " -- not " & Kind);
      elsif Ada.Directories.Exists (Model_Runner.Tools.Editing.On_Disk (Base, Where))
        and then Ada.Directories."=" (Ada.Directories.Kind (Model_Runner.Tools.Editing.On_Disk (Base, Where)),
                                      Ada.Directories.Ordinary_File)
      then
         return As_Reply (Model_Runner.Tools.Editing.Search_File (Where, Query, Base));
      end if;
      return As_Reply (Model_Runner.Tools.Editing.Search_Code (Where, Query, Base));
   end Find;

   --  A file read whole, or by its lines where it is asked for some.
   function Read_Any (Args : String; Base : String) return Reply is
      First : Long_Long_Integer;
      Have  : Boolean;
   begin
      Integer_Argument (Args, "first_line", First, Have);
      return (if Have then Read_Range (Args, Base) else Read_File (Args, Base));
   end Read_Any;

   --  A tool that takes a path in the tree, answered.
   --  The file tools, each by the registry's name for it: what carries out
   --  a call, given its arguments and the tree they are under.
   type File_Handler is access function (Args : String; Base : String) return Reply;
   type File_Handled is record
      Name : Word;
      Run  : File_Handler;
   end record;

   File_Handlers : constant array (Positive range <>) of File_Handled :=
     [(W ("read_file"), Read_Any'Access), (W ("find"), Find'Access),
      (W ("write_file"), Write_File'Access), (W ("list_directory"), List_Directory'Access),
      (W ("edit_file"), Edit_File'Access), (W ("read_range"), Read_Range'Access),
      (W ("search_file"), Search_File'Access), (W ("search_code"), Search_Code'Access)];

   function File_Answer (Named, Args : String; Base : String) return Reply is
   begin
      for One of File_Handlers loop
         if One.Name.all = Named then
            return One.Run (Args, Base);
         end if;
      end loop;
      return Failure ("no file tool by the name """ & Named & """");
   end File_Answer;

   function Shell (Args : String) return Reply is
      Have : Boolean;
      Cmd  : constant String := Text_Argument (Args, "command", Have);
   begin
      if not Have then
         return Failure ("shell needs a command");
      end if;
      return Capture ("sh", [new String'("-c"), new String'(Cmd)]);
   end Shell;

   function Run_Python (Args : String) return Reply is
      Have : Boolean;
      Code : constant String := Text_Argument (Args, "code", Have);
   begin
      if not Have then
         return Failure ("run_python needs code");
      end if;
      return Capture ("python3", [new String'("-c"), new String'(Code)]);
   end Run_Python;

   --  Fetch a URL's body through the in-process HTTP/HTTPS client, streamed
   --  to a temporary file and never held whole in memory, then return it
   --  capped. No process is spawned; the client's own timeouts bound a slow
   --  or silent server, and Max_Download_Size keeps the temp file no larger
   --  than what the tool will hand back.
   function Download (Url : String) return Reply is
      package HC renames Http_Client.Clients;
      package HE renames Http_Client.Errors;

      Path : GNAT.OS_Lib.String_Access;
      FD   : GNAT.OS_Lib.File_Descriptor;
      Outcome : HC.Download_Result;
      Options : HC.Download_Options := HC.Default_Download_Options;
      Config  : HC.Client_Configuration := HC.Default_Client_Configuration;
      Status  : HE.Result_Status;
      Gone    : Boolean;
   begin
      Options.Max_Download_Size := Cap;

      --  The streaming download writes what the stream yields and does not
      --  decode a content coding, so a body the server compressed would come
      --  back as bytes no reader can use. Ask for none: no Accept-Encoding
      --  advertised, so the server sends the text as it is.
      Config.Enable_Decompression := False;
      Config.Execution.Advertise_Accept_Encoding := False;

      GNAT.OS_Lib.Create_Temp_File (FD, Path);
      GNAT.OS_Lib.Close (FD);

      Status := HC.Download_To_File
        (URL           => Url,
         Path          => Path.all,
         Result        => Outcome,
         Options       => Options,
         Configuration => Config);

      declare
         Read      : constant Reply :=
           (if HE.Is_Success (Status) then Read_Capped (Path.all) else Said (""));
         Body_Text : String renames Read.Text;
      begin
         GNAT.OS_Lib.Delete_File (Path.all, Gone);
         GNAT.OS_Lib.Free (Path);
         if not HE.Is_Success (Status) then
            return Failure ("the request failed ("
              & HE.Result_Status'Image (Status) & ")");
         elsif Body_Text = "" then
            return Said ("(the request returned no body; HTTP status"
              & Natural'Image (Outcome.HTTP_Status_Code) & ")");
         else
            return Said (Body_Text);
         end if;
      end;
   end Download;

   --  Rank the passages of a folder's text files against a query and return
   --  the best few. This is lexical retrieval: a passage scores by how often
   --  the query's words appear in it, each word weighted down by how many
   --  passages carry it, so a rare word counts for more than a common one.
   --  It finds the words the query used, not their meaning -- a semantic
   --  ranking would embed both and compare, which needs the model this tool
   --  does not hold.
   procedure Use_Embedder
     (Self : in out Instance; Source : Embedder_Reference) is
   begin
      Self.Embed := Source;
   end Use_Embedder;

   procedure Use_Delegator
     (Self : in out Instance; Source : Delegator_Reference) is
   begin
      Self.Sub := Source;
   end Use_Delegator;

   procedure Use_Inquirer
     (Self : in out Instance; Source : Inquirer_Reference) is
   begin
      Self.Asker := Source;
   end Use_Inquirer;

   --  The ask_user tool: put a question to the user and return the answer.
   --  With no inquirer wired -- an eval, a library embedding, or a sub-agent,
   --  none of which has a user at a console -- the call is declined in words
   --  the model reads, so the loop goes on rather than blocking on input
   --  no one will give.
   function Ask_User
     (Self : in out Instance; Args : String) return Reply
   is
      Have     : Boolean;
      Question : constant String := Text_Argument (Args, "question", Have);
   begin
      if not Have then
         return Failure ("ask_user needs a question string");
      end if;
      if Self.Asker = null then
         return Failure ("no user is available to ask; decide with what you "
                & "have or use another tool");
      end if;

      declare
         Buffer : String (1 .. Model_Runner.Tools.Max_Call_Bytes);
         Last   : Natural;
         Status : E.Error_Info;
      begin
         Self.Asker.Ask (Question, Buffer, Last, Status);
         if E.Is_Error (Status) then
            return Failure ("the user could not be asked");
         elsif Last = 0 then
            return Said ("the user gave no answer");
         else
            return Said (Buffer (1 .. Last));
         end if;
      end;
   end Ask_User;

   --  The delegate tool: run one subtask on a sub-agent and return its
   --  answer. With no delegator wired -- which is how a sub-agent's own
   --  runner is left -- the call is declined in words the model reads, so
   --  delegation cannot recurse and the loop goes on.
   function Delegate
     (Self : in out Instance; Args : String) return Reply
   is
      package Rt renames Model_Runner.Agent_Runtime;
      Have  : Boolean;
      --  The contract a /work helper is given: task, role, need, the files
      --  it starts from and must write, and when it is done -- put to it in
      --  the same brief, and its outputs checked after.
      Asked : constant Rt.Contract := Rt.Contract_Of (Args, Have);
      Job   : constant String :=
        (if U.Length (Asked.Role) = 0 then Rt.Brief (Asked)
         else "Your role: " & U.To_String (Asked.Role) & ASCII.LF & Rt.Brief (Asked));
      Outputs : constant Rt.Paths.Vector := Asked.Outputs;
      Before  : constant Rt.Paths.Vector := Rt.Prints (Outputs, U.To_String (Self.Base));
   begin
      if not Have then
         return Failure ("delegate needs a task string");
      end if;
      if U.Length (Asked.Refusal) > 0 then
         return Failure ("delegate's " & U.To_String (Asked.Refusal));
      end if;
      if Self.Sub = null then
         return Failure ("delegation is not available here -- a sub-agent "
                & "cannot delegate further; do the work with the other tools");
      end if;

      declare
         package Tr renames Model_Runner.Tools.Runner;
         Buffer : String (1 .. Model_Runner.Tools.Max_Call_Bytes);
         Last   : Natural;
         Ended  : Sub_Outcome;
         Status : E.Error_Info;

         --  What it took, beside what it came to: the caller's budget is
         --  spent by what its child generated, whatever the child gave.
         function Spent (Item : Reply) return Reply
         is ((Length => Item.Length, Failed => Item.Failed, Changed => Item.Changed,
              Halted => Item.Halted, Truncated => Item.Truncated,
              Tokens => Ended.Tokens,
              Before_Revision => Item.Before_Revision, After_Revision => Item.After_Revision,
        Created => Item.Created, Text => Item.Text));

         function Took return String is
           (Image (Long_Long_Integer (Ended.Steps)) & " steps and "
            & Image (Long_Long_Integer (Ended.Calls)) & " calls");
      begin
         Self.Sub.Run_Sub (Job, Tr.Context_Of (Self), Buffer, Last, Ended, Status);
         if E.Is_Error (Status) then
            return Spent (Failure ("the sub-agent could not run the task (" & E.Diagnostic_Code (Status.Code) & ")"));
         end if;
         --  Only an answer is a result: a child that stopped any other way
         --  has not done the task, whatever it said on the way.
         case Ended.State is
            when Completed =>
               if Last < Buffer'First then
                  return Spent (Failure ("the sub-agent ended without an answer, after " & Took));
               end if;
               --  What it was to write and did not: failed, whatever it said.
               declare
                  Missing : constant String := Rt.Unwritten (Outputs, Before, U.To_String (Self.Base));
               begin
                  if Missing /= "" then
                     return Spent (Failure ("the sub-agent did not write " & Missing & ", which it was to"
                                            & ASCII.LF & Buffer (Buffer'First .. Last)));
                  end if;
               end;
               return Spent (Said (Buffer (Buffer'First .. Last)));
            when Cancelled =>
               return Spent (Halted_By (Tr.Cancelled, "the sub-agent was stopped: the run was cancelled"));
            when Exhausted =>
               if Ended.Timed then
                  return Spent (Halted_By (Tr.Timed_Out, "the sub-agent ran out of time before answering, after "
                                           & Took));
               end if;
               return Spent (Failure ("the sub-agent stopped before answering: "
                                      & Ada.Strings.Unbounded.To_String (Ended.Reason) & ", after " & Took));
            when Failed =>
               return Spent (Failure ("the sub-agent failed: "
                                      & Ada.Strings.Unbounded.To_String (Ended.Reason) & ", after " & Took));
         end case;
      end;
   end Delegate;

   function Retrieve
     (Args : String; Embed : Embedder_Reference; Base : String) return Reply
   is
      Max_Chunks : constant := 2048;  --  passages held across the folder
      Max_Terms  : constant := 24;    --  distinct query words scored
      Max_Files  : constant := 1024;  --  files read from the folder
      Snippet    : constant := 600;   --  characters in a passage window
      Front      : constant := 1200;  --  leading bytes dropped as front matter
      Top        : constant := 3;     --  passages returned
      Embed_Cap  : constant := 64;    --  most passages embedded in one call
      Max_Width  : constant := 8192;  --  widest embedding vector held

      Have_F, Have_Q : Boolean;
      Given  : constant String := Text_Argument (Args, "folder", Have_F);
      --  Under the tools' tree, where one is named.
      Folder : constant String := Model_Runner.Tools.Editing.On_Disk (Base, Given);
      Query  : constant String := Text_Argument (Args, "query", Have_Q);

      function Low (S : String) return String
        renames Ada.Characters.Handling.To_Lower;

      function Word (C : Character) return Boolean
      is (C in 'a' .. 'z' | '0' .. '9');

      --  Whole-word occurrences of Term (lowercased) in Hay (lowercased).
      function Occurrences (Hay, Term : String) return Natural is
         N : Natural := 0;
         I : Integer := Hay'First;
      begin
         if Term'Length = 0 or else Hay'Length < Term'Length then
            return 0;
         end if;
         while I <= Hay'Last - Term'Length + 1 loop
            if Hay (I .. I + Term'Length - 1) = Term
              and then (I = Hay'First or else not Word (Hay (I - 1)))
              and then (I + Term'Length - 1 = Hay'Last
                        or else not Word (Hay (I + Term'Length)))
            then
               N := N + 1;
               I := I + Term'Length;
            else
               I := I + 1;
            end if;
         end loop;
         return N;
      end Occurrences;

      Terms  : array (1 .. Max_Terms) of U.Unbounded_String;
      DF     : array (1 .. Max_Terms) of Natural := [others => 0];
      N_Term : Natural := 0;

      type Chunk is record
         Source : U.Unbounded_String;   --  the file it came from
         Shown  : U.Unbounded_String;   --  the passage as written
         Lower  : U.Unbounded_String;   --  the passage lowercased, to match
         Score  : Float := 0.0;
         Taken  : Boolean := False;
      end record;
      Chunks   : array (1 .. Max_Chunks) of Chunk;
      N_Chunks : Natural := 0;
      Files    : Natural := 0;   --  files read, over the whole tree
      Semantic : Boolean := False;   --  whether meaning-ranking was applied

      use type Ada.Directories.File_Kind;

      --  Take a lowercased query into its distinct words, longest first come
      --  first served, ignoring one-character noise.
      procedure Read_Terms (Q : String) is
         I : Integer := Q'First;
      begin
         while I <= Q'Last and then N_Term < Max_Terms loop
            if Word (Q (I)) then
               declare
                  First : constant Integer := I;
               begin
                  while I <= Q'Last and then Word (Q (I)) loop
                     I := I + 1;
                  end loop;
                  if I - First >= 2 then
                     declare
                        W : constant String := Q (First .. I - 1);
                        Seen : Boolean := False;
                     begin
                        for T in 1 .. N_Term loop
                           if U.To_String (Terms (T)) = W then
                              Seen := True;
                           end if;
                        end loop;
                        if not Seen then
                           N_Term := N_Term + 1;
                           Terms (N_Term) := U.To_Unbounded_String (W);
                        end if;
                     end;
                  end if;
               end;
            else
               I := I + 1;
            end if;
         end loop;
      end Read_Terms;

      --  Add a passage, lowercased once for matching, kept short for return.
      procedure Add_Chunk (From : String; Text : String) is
      begin
         if N_Chunks >= Max_Chunks or else Text'Length = 0 then
            return;
         end if;
         N_Chunks := N_Chunks + 1;
         Chunks (N_Chunks).Source := U.To_Unbounded_String (From);
         declare
            --  Made valid UTF-8: a window may cut a multi-byte character, and
            --  a PDF or a legacy Word file is not UTF-8 at all -- either would
            --  be refused by the embedder's tokenizer and by the model the
            --  passage is handed back to.
            Kept : constant String :=
              Model_Runner.Tools.Text_Util.To_Valid_Utf8
                (if Text'Length <= Snippet then Text
                 else Text (Text'First .. Text'First + Snippet - 1));
         begin
            Chunks (N_Chunks).Shown := U.To_Unbounded_String (Kept);
            Chunks (N_Chunks).Lower := U.To_Unbounded_String (Low (Kept));
         end;
      end Add_Chunk;

      --  Add a passage, breaking one longer than a window into several so a
      --  long stretch of text is indexed whole rather than truncated to its
      --  first window.
      procedure Add_Windows (From : String; Para : String) is
         P : Integer := Para'First;
      begin
         while P <= Para'Last and then N_Chunks < Max_Chunks loop
            declare
               Stop : constant Integer :=
                 Integer'Min (P + Snippet - 1, Para'Last);
            begin
               Add_Chunk (From, Para (P .. Stop));
               P := Stop + 1;
            end;
         end loop;
      end Add_Windows;

      --  Split a file's text into passages at blank lines, each windowed.
      procedure Split (From : String; Text : String) is
         I     : Integer := Text'First;
         Start : Integer := Text'First;
      begin
         while I <= Text'Last loop
            if I < Text'Last and then Text (I) = ASCII.LF
              and then Text (I + 1) = ASCII.LF
            then
               Add_Windows (From, Text (Start .. I - 1));
               I := I + 2;
               Start := I;
            else
               I := I + 1;
            end if;
         end loop;
         if Start <= Text'Last then
            Add_Windows (From, Text (Start .. Text'Last));
         end if;
      end Split;

      --  Drop the leading bytes of a long document's extracted text -- the
      --  title, author, copyright and table of contents a book opens with,
      --  which are not what a search is usually after. A short document keeps
      --  all of its text; only a long one has front matter to spare.
      function Skip_Front (Text : String) return String
      is (if Text'Length > 3 * Front
          then Text (Text'First + Front .. Text'Last) else Text);

      --  Read a directory and its subdirectories into passages, each
      --  labelled with its path under the folder the tool was given. A name
      --  beginning with a dot is skipped -- "." and ".." and hidden trees
      --  like .git -- and the file and passage caps bound the whole walk.
      --  What could not be read -- a folder that would not list, a text file
      --  that would not read -- counted and the first named, and said with
      --  whatever is answered: passages ranked from part of the folder are
      --  not the folder's best, and none found is not none there.
      Unread_Files   : Natural := 0;
      Unread_Folders : Natural := 0;
      First_Unread   : U.Unbounded_String;

      procedure Unread (Path : String; Folder : Boolean) is
      begin
         if Folder then
            Unread_Folders := Unread_Folders + 1;
         else
            Unread_Files := Unread_Files + 1;
         end if;
         if U.Length (First_Unread) = 0 then
            First_Unread := U.To_Unbounded_String (Path);
         end if;
      end Unread;

      function Missed return String
      is (if Unread_Files + Unread_Folders = 0 then ""
          else ASCII.LF & "(incomplete:"
               & (if Unread_Files > 0 then Natural'Image (Unread_Files) & " file"
                    & (if Unread_Files = 1 then "" else "s") else "")
               & (if Unread_Files > 0 and then Unread_Folders > 0 then " and" else "")
               & (if Unread_Folders > 0 then Natural'Image (Unread_Folders) & " folder"
                    & (if Unread_Folders = 1 then "" else "s") else "")
               & " could not be read, " & U.To_String (First_Unread) & " the first -- what they hold"
               & " was not searched)");

      procedure Walk (Dir : String; Prefix : String) is
         Search : Ada.Directories.Search_Type;
         Item   : Ada.Directories.Directory_Entry_Type;
      begin
         Ada.Directories.Start_Search
           (Search, Dir, "",
            [Ada.Directories.Ordinary_File => True,
             Ada.Directories.Directory     => True,
             others                        => False]);
         while Ada.Directories.More_Entries (Search)
           and then Files < Max_Files
           and then N_Chunks < Max_Chunks
         loop
            Ada.Directories.Get_Next_Entry (Search, Item);
            declare
               Name : constant String := Ada.Directories.Simple_Name (Item);
               Full : constant String := Ada.Directories.Full_Name (Item);
               OO_Found : Boolean;
               OO_Kind  : constant Model_Runner.Tools.OOXML.Document_Kind :=
                 Model_Runner.Tools.OOXML.Kind_Of (Name, OO_Found);

               --  The last four and five characters, lowercased, for reading
               --  a file's kind off its name.
               Ext4 : constant String :=
                 (if Name'Length >= 4
                  then Low (Name (Name'Last - 3 .. Name'Last)) else "");
               Ext5 : constant String :=
                 (if Name'Length >= 5
                  then Low (Name (Name'Last - 4 .. Name'Last)) else "");
            begin
               if Name'Length = 0 or else Name (Name'First) = '.' then
                  null;
               elsif Ada.Directories.Kind (Item)
                       = Ada.Directories.Directory
               then
                  Walk (Full, Prefix & Name & "/");
               elsif Read_Raw (Full, 5) = "%PDF-" then
                  --  A PDF: binary, but its text is pulled out and indexed
                  --  from the file's own bytes. Checked before the binary
                  --  test so a PDF is read as a PDF, never as raw text.
                  Files := Files + 1;
                  declare
                     Text : constant String :=
                       Model_Runner.Tools.PDF.Extract_Text
                         (Read_Raw (Full, Doc_Bytes));
                  begin
                     if Text'Length > 0 then
                        Split (Prefix & Name, Skip_Front (Text));
                     end if;
                  end;
               elsif OO_Found and then Read_Raw (Full, 2) = "PK" then
                  --  A Word, Excel, PowerPoint, OpenDocument or EPUB file:
                  --  a ZIP of XML, whose text is pulled from the right parts.
                  Files := Files + 1;
                  declare
                     Text : constant String :=
                       Model_Runner.Tools.OOXML.Extract_Text
                         (Read_Raw (Full, Doc_Bytes), OO_Kind);
                  begin
                     if Text'Length > 0 then
                        Split (Prefix & Name, Skip_Front (Text));
                     end if;
                  end;
               elsif (Ext4 = ".doc" or else Ext4 = ".xls"
                      or else Ext4 = ".ppt")
                 and then Read_Raw (Full, 8)
                          = Character'Val (16#D0#) & Character'Val (16#CF#)
                            & Character'Val (16#11#) & Character'Val (16#E0#)
                            & Character'Val (16#A1#) & Character'Val (16#B1#)
                            & Character'Val (16#1A#) & Character'Val (16#E1#)
               then
                  --  A legacy Word, Excel or PowerPoint file: an OLE2
                  --  compound file. Its printable runs are read out and
                  --  indexed.
                  Files := Files + 1;
                  declare
                     Text : constant String :=
                       Model_Runner.Tools.DOC.Extract_Text
                         (Read_Raw (Full, Doc_Bytes));
                  begin
                     if Text'Length > 0 then
                        Split (Prefix & Name, Skip_Front (Text));
                     end if;
                  end;
               elsif Ext4 = ".rtf" and then Read_Raw (Full, 5) = "{\rtf" then
                  --  An RTF document: its control words and groups stripped
                  --  to the text.
                  Files := Files + 1;
                  declare
                     Text : constant String :=
                       Model_Runner.Tools.RTF.Extract_Text
                         (Read_Raw (Full, Doc_Bytes));
                  begin
                     if Text'Length > 0 then
                        Split (Prefix & Name, Skip_Front (Text));
                     end if;
                  end;
               elsif Ext4 = ".htm" or else Ext4 = ".xml"
                 or else Ext5 = ".html"
               then
                  --  An HTML or XML file: its tags stripped to the text.
                  Files := Files + 1;
                  declare
                     Read : constant Reply := Read_Capped (Full);
                     Text : constant String :=
                       (if Read.Failed then ""
                        else Model_Runner.Tools.Text_Util.Strip_Tags (Read.Text));
                  begin
                     if Read.Failed then
                        Unread (Prefix & Name, Folder => False);
                     end if;
                     if Text'Length > 0 then
                        Split (Prefix & Name, Skip_Front (Text));
                     end if;
                  end;
               elsif Is_Binary (Full) then
                  --  An image, an archive -- not text to search.
                  null;
               else
                  Files := Files + 1;
                  declare
                     Read       : constant Reply := Read_Capped (Full);
                     Body_Text  : String renames Read.Text;
                     Unreadable : constant Boolean := Read.Failed;
                  begin
                     if not Unreadable then
                        Split (Prefix & Name, Body_Text);
                     else
                        Unread (Prefix & Name, Folder => False);
                     end if;
                  end;
               end if;
            end;
         end loop;
         Ada.Directories.End_Search (Search);
      exception
         when others =>
            Unread (Dir, Folder => True);
      end Walk;

   begin
      if not (Have_F and then Have_Q) then
         return Failure ("retrieve needs a folder and a query");
      elsif not Ada.Directories.Exists (Folder) then
         return Failure ("no folder at that path");
      end if;

      Read_Terms (Low (Query));
      if N_Term = 0 then
         return Failure ("the query has no words to search for");
      end if;

      --  Read the folder tree's files into passages.
      Walk (Folder, "");

      if N_Chunks = 0 then
         return Said ("no readable text files in that folder" & Missed);
      end if;

      --  Document frequency of each term across the passages.
      for T in 1 .. N_Term loop
         declare
            Term : constant String := U.To_String (Terms (T));
         begin
            for C in 1 .. N_Chunks loop
               if Occurrences (U.To_String (Chunks (C).Lower), Term) > 0 then
                  DF (T) := DF (T) + 1;
               end if;
            end loop;
         end;
      end loop;

      --  Score each passage: term frequency times a rarity weight, so a word
      --  in few passages counts for more than one in many.
      for C in 1 .. N_Chunks loop
         declare
            Hay   : constant String := U.To_String (Chunks (C).Lower);
            Total : Float := 0.0;
         begin
            for T in 1 .. N_Term loop
               declare
                  TF : constant Natural :=
                    Occurrences (Hay, U.To_String (Terms (T)));
               begin
                  if TF > 0 then
                     Total := Total
                       + Float (TF) * (1.0 / (1.0 + Float (DF (T))));
                  end if;
               end;
            end loop;
            Chunks (C).Score := Total;
         end;
      end loop;

      --  With an embedder at hand, re-score by meaning: embed the query and
      --  the candidate passages and rank by how close each is to the query,
      --  which finds a passage that shares the query's sense even where it
      --  shares few of its words. Only a bounded number are embedded -- the
      --  whole set when it is small, otherwise the ones the lexical score
      --  already liked -- because each embedding is a pass over the model.
      --  A candidate's cosine (in -1 .. 1) is shifted into 0 .. 2 so the
      --  selection below, which keeps a positive score, still reads it; a
      --  passage not embedded is left at zero and drops out. If the query
      --  will not embed, the lexical scores stand.
      if Embed /= null then
         declare
            Q      : N.Real_Array (0 .. Max_Width - 1);
            P      : N.Real_Array (0 .. Max_Width - 1);
            Q_Last : Natural;
            P_Last : Natural;
            St     : E.Error_Info;
         begin
            Embed.Embed (Query, Q, Q_Last, St);
            if E.Is_Ok (St) then
               Semantic := True;
               declare
                  Used  : array (1 .. N_Chunks) of Boolean :=
                    [others => False];
                  Count : constant Natural :=
                    Natural'Min (N_Chunks, Embed_Cap);
                  Cand  : array (1 .. Count) of Positive;
               begin
                  --  The Count passages the lexical score liked most.
                  for K in 1 .. Count loop
                     declare
                        Best   : Natural := 0;
                        Best_S : Float := Float'First;
                     begin
                        for C in 1 .. N_Chunks loop
                           if not Used (C)
                             and then Chunks (C).Score >= Best_S
                           then
                              Best := C;
                              Best_S := Chunks (C).Score;
                           end if;
                        end loop;
                        exit when Best = 0;
                        Used (Best) := True;
                        Cand (K) := Best;
                     end;
                  end loop;

                  --  Every passage out of the running until its meaning earns
                  --  it back. The sentinel is below any cosine, so a passage
                  --  that was not embedded never outranks one that was.
                  for C in 1 .. N_Chunks loop
                     Chunks (C).Score := -2.0;
                  end loop;

                  for K in Cand'Range loop
                     Embed.Embed
                       (U.To_String (Chunks (Cand (K)).Shown),
                        P, P_Last, St);
                     if E.Is_Ok (St) and then P_Last = Q_Last then
                        declare
                           Dot : N.Real := 0.0;
                        begin
                           for I in 0 .. N.Element_Index (Q_Last) loop
                              Dot := Dot + Q (I) * P (I);
                           end loop;
                           Chunks (Cand (K)).Score := Float (Dot) + 1.0;
                        end;
                     end if;
                  end loop;
               end;
            end if;
         end;
      end if;

      --  The best few, in order, each labelled with its file.
      declare
         Out_S : U.Unbounded_String;
         Found : Natural := 0;

         --  Lexical ranking requires a positive score -- a word the query
         --  and the passage share. Semantic ranking returns its best
         --  candidates whatever their cosine, since a shared meaning need
         --  not be a shared word; only the sentinel non-candidates are shut
         --  out.
         Floor : constant Float := (if Semantic then -1.5 else 0.0);
      begin
         for Rank in 1 .. Top loop
            declare
               Best  : Natural := 0;
               Top_S : Float := Floor;
            begin
               for C in 1 .. N_Chunks loop
                  if not Chunks (C).Taken
                    and then Chunks (C).Score > Top_S
                  then
                     Best := C;
                     Top_S := Chunks (C).Score;
                  end if;
               end loop;
               exit when Best = 0;
               Chunks (Best).Taken := True;
               Found := Found + 1;
               if U.Length (Out_S) > 0 then
                  U.Append (Out_S, ASCII.LF & ASCII.LF);
               end if;
               U.Append (Out_S, "[" & U.To_String (Chunks (Best).Source)
                         & "] " & U.To_String (Chunks (Best).Shown));
            end;
         end loop;

         if Found = 0 then
            return Said ("no passage in that folder matched the query" & Missed);
         end if;
         return Said (Capped (U.To_String (Out_S)) & Missed);
      end;
   end Retrieve;

   function Http_Get (Args : String) return Reply is
      Have : Boolean;
      Url  : constant String := Text_Argument (Args, "url", Have);
   begin
      if not Have then
         return Failure ("http_get needs a url");
      end if;
      return Download (Url);
   end Http_Get;

   --  Percent-encode a query string for a URL: the unreserved characters
   --  pass through, everything else -- a space, a symbol, a non-ASCII byte --
   --  becomes %XX, so the query is safe to paste after "?q=".
   function Encode_Query (S : String) return String is
      Hex  : constant String := "0123456789ABCDEF";
      Room : String (1 .. S'Length * 3);
      Used : Natural := 0;

      procedure Put (C : Character) is
      begin
         Used := Used + 1;
         Room (Used) := C;
      end Put;
   begin
      for C of S loop
         if C in 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '-' | '_' | '.' | '~'
         then
            Put (C);
         else
            Put ('%');
            Put (Hex (Character'Pos (C) / 16 + 1));
            Put (Hex (Character'Pos (C) mod 16 + 1));
         end if;
      end loop;
      return Room (1 .. Used);
   end Encode_Query;

   function Web_Search (Args : String) return Reply is
      Have  : Boolean;
      Query : constant String := Text_Argument (Args, "query", Have);
   begin
      if not Have then
         return Failure ("web_search needs a query");
      end if;
      --  Fetched the same way as http_get -- through the in-process client,
      --  streamed -- with the query percent-encoded into the URL.
      return Download
        ("https://lite.duckduckgo.com/lite/?q=" & Encode_Query (Query));
   end Web_Search;

   function Sql (Args : String; Base : String) return Reply is
      Have_D, Have_Q : Boolean;
      --  Under the tools' tree, where one is named.
      Database : constant String :=
        Model_Runner.Tools.Editing.On_Disk (Base, Text_Argument (Args, "database", Have_D));
      Query    : constant String := Text_Argument (Args, "query", Have_Q);
   begin
      if not (Have_D and then Have_Q) then
         return Failure ("sql needs a database and a query");
      end if;
      return Capture
        ("sqlite3", [new String'(Database), new String'(Query)]);
   end Sql;

   ---------
   -- Run --
   ---------

   ----------
   -- Kind --
   ----------

   overriding function Kind
     (Self : Instance; Named : String) return Model_Runner.Tools.Runner.Call_Kind
   is
      pragma Unreferenced (Self);
   begin
      return Rg.Kind_Of (Named);
   end Kind;

   overriding function Parallel_Safe
     (Self : Instance; Named : String) return Boolean is
   begin
      if not Rg.Parallel (Named) then
         return False;
      elsif Named = "retrieve" then
         return Self.Embed = null;
      end if;
      return True;
   end Parallel_Safe;

   ---------------
   -- Revisions --
   ---------------

   protected body Revisions is
      procedure Put (Path : String; Revision : String) is
      begin
         Held.Include (Path, Revision);
      end Put;

      function Has (Path : String) return Boolean is (Held.Contains (Path));

      function Get (Path : String) return String
      is (if Held.Contains (Path) then Held.Element (Path) else "");
   end Revisions;

   --------------
   -- Set_Base --
   --------------

   procedure Set_Base (Self : in out Instance; Base : String) is
   begin
      Self.Base := U.To_Unbounded_String (Base);
   end Set_Base;

   ----------
   -- Base --
   ----------

   function Base (Self : Instance) return String is (U.To_String (Self.Base));

   -------------
   -- Touches --
   -------------

   overriding function Touches
     (Self : Instance; Named : String) return Model_Runner.Tools.Runner.Resource
   is
      pragma Unreferenced (Self);
   begin
      return Rg.Touches (Named);
   end Touches;

   -----------
   -- Stamp --
   -----------

   overriding function Stamp
     (Self : Instance; Named : String; Arguments : String) return String
   is
      use type Model_Runner.Tools.Runner.Resource;
      use type Model_Runner.Tools.Runner.Call_Kind;
      use type Ada.Directories.File_Kind;

      --  FNV-1a over what was seen, as the revisions are.
      type Hash is mod 2 ** 64;
      Sum   : Hash := 16#CBF29CE484222325#;
      Files : Natural := 0;

      procedure Mix (Text : String) is
      begin
         for C of Text loop
            Sum := (Sum xor Hash (Character'Pos (C))) * 16#100000001B3#;
         end loop;
         Sum := (Sum xor 16#0A#) * 16#100000001B3#;
      end Mix;

      procedure Walk (Folder : String) is
         use Ada.Directories;
         Search : Search_Type;
         Found  : Directory_Entry_Type;
      begin
         Start_Search (Search, Folder, "", [Ordinary_File | Directory => True, others => False]);
         while More_Entries (Search) loop
            Get_Next_Entry (Search, Found);
            declare
               Name : constant String := Simple_Name (Found);
               Full : constant String := Full_Name (Found);
            begin
               if Name'Length > 0 and then Name (Name'First) /= '.' then
                  if Kind (Found) = Directory then
                     Walk (Full);
                  else
                     Files := Files + 1;
                     --  The filesystem's own change stamp, to the
                     --  nanosecond, where the host gives one: a quick edit
                     --  that keeps the size is seen. Size and time else.
                     declare
                        Available : Boolean;
                        Changed   : constant String := Hostkit.Metadata.Change_Stamp (Full, Available);
                     begin
                        if Available then
                           Mix (Full & Changed);
                        else
                           Mix (Full & Ada.Directories.File_Size'Image (Size (Found))
                                & Ada.Calendar.Formatting.Image (Modification_Time (Found),
                                                                 Include_Time_Fraction => True));
                        end if;
                     end;
                  end if;
               end if;
            end;
         end loop;
         End_Search (Search);
      exception
         when others =>
            Mix ("unreadable " & Folder);
      end Walk;

      Has_Path : Boolean;
      Path     : constant String := Text_Argument (Arguments, "path", Has_Path);
      Where    : constant String :=
        Model_Runner.Tools.Editing.On_Disk
          (U.To_String (Self.Base), (if Has_Path and then Path /= "" then Path else "."));
   begin
      --  Of what a file tool reads, or would change: a change that failed
      --  is stamped too, and may run again once what it found has moved.
      if Rg.Touches (Named) /= Model_Runner.Tools.Runner.Files
        or else Rg.Kind_Of (Named) not in Model_Runner.Tools.Runner.Reads | Model_Runner.Tools.Runner.Changes
      then
         return "";
      end if;
      if Ada.Directories.Exists (Where)
        and then Ada.Directories.Kind (Where) = Ada.Directories.Ordinary_File
      then
         return "file " & Model_Runner.Tools.Editing.Revision_Of (Where);
      elsif Ada.Directories.Exists (Where) then
         Walk (Where);
         return "tree" & Natural'Image (Files) & " " & Hash'Image (Sum);
      end if;
      return "absent " & Where;
   exception
      when others =>
         return "unreadable " & Where;
   end Stamp;

   --  The rest of the built-in tools, each by the registry's name for it:
   --  what carries out a call, given the runner and its arguments. With
   --  the file tools above, every tool the registry describes that this
   --  runner carries has a row here, which the suite holds to (Handles);
   --  what a tool is -- its definition, its effect, what it needs -- is the
   --  registry's row, and only how it is done is here.
   type Handler is access function (Self : in out Instance; Args : String) return Reply;
   type Handled is record
      Name : Word;
      Run  : Handler;
   end record;

   --  Those that need nothing of the runner, as handlers.
   generic
      with function Tool (Args : String) return Reply;
   function Plain (Self : in out Instance; Args : String) return Reply;

   function Plain (Self : in out Instance; Args : String) return Reply is
      pragma Unreferenced (Self);
   begin
      return Tool (Args);
   end Plain;

   function On_Calculator is new Plain (Calculator);
   function On_String_Length is new Plain (String_Length);
   function On_Reverse_Text is new Plain (Reverse_Text);
   function On_Lookup is new Plain (Lookup);
   function On_Base64_Encode is new Plain (Base64_Encode);
   function On_Base64_Decode is new Plain (Base64_Decode);
   function On_Shell is new Plain (Shell);
   function On_Run_Python is new Plain (Run_Python);
   function On_Http_Get is new Plain (Http_Get);
   function On_Web_Search is new Plain (Web_Search);

   function On_Now (Self : in out Instance; Args : String) return Reply is
      pragma Unreferenced (Self, Args);
   begin
      return Said (Now_Text);
   end On_Now;

   function On_Sql (Self : in out Instance; Args : String) return Reply
   is (Sql (Args, U.To_String (Self.Base)));

   function On_Retrieve (Self : in out Instance; Args : String) return Reply
   is (Retrieve (Args, Self.Embed, U.To_String (Self.Base)));

   Handlers : constant array (Positive range <>) of Handled :=
     [(W ("calculator"), On_Calculator'Access), (W ("string_length"), On_String_Length'Access),
      (W ("reverse_text"), On_Reverse_Text'Access), (W ("lookup"), On_Lookup'Access),
      (W ("base64_encode"), On_Base64_Encode'Access), (W ("base64_decode"), On_Base64_Decode'Access),
      (W ("now"), On_Now'Access),
      (W ("memory_put"), Memory_Put'Access), (W ("memory_get"), Memory_Get'Access),
      (W ("shell"), On_Shell'Access), (W ("run_python"), On_Run_Python'Access),
      (W ("http_get"), On_Http_Get'Access), (W ("web_search"), On_Web_Search'Access),
      (W ("sql"), On_Sql'Access), (W ("retrieve"), On_Retrieve'Access),
      (W ("delegate"), Delegate'Access), (W ("ask_user"), Ask_User'Access)];

   -------------
   -- Handles --
   -------------

   function Handles (Named : String) return Boolean is
   begin
      return (for some One of Handlers => One.Name.all = Named)
        or else (for some One of File_Handlers => One.Name.all = Named);
   end Handles;

   overriding procedure Run
     (Self      : in out Instance;
      Named     : String;
      Arguments : String;
      Result    : out String;
      Last      : out Natural;
      Outcome   : out Model_Runner.Tools.Runner.Call_Outcome;
      Status    : out Model_Runner.Errors.Error_Info)
   is
      package Pm renames Model_Runner.Framework.Permissions;
      package Tr renames Model_Runner.Tools.Runner;
      use type Tr.Refusal_Kind;

      --  What refused the call, where the confinement of an agent the
      --  harness started did: set as Answer says so.
      Refused : Tr.Refusal_Kind := Tr.Not_Refused;

      --  The confinement's words for the call, and what refused it: a path
      --  by its verdict, any other tool by the permissions.
      function Confined (Called, Args : String) return String is
         Said : constant String := Confinement (Called, Args);
      begin
         if Said /= "" then
            Refused :=
              (if not File_Tool (Called)
               then Tr.Not_Permitted
               else
                 (case Confined_Path_Verdict (Called, Args) is
                    when Pm.Path_Outside       => Tr.Outside_Project,
                    when Pm.Path_Harness_Owned => Tr.Harness_Owned,
                    when others                => Tr.Not_Permitted));
         end if;
         return Said;
      end Confined;

      function Answer return Reply is
      begin
         if File_Tool (Named)
           and then Rooted (Named, Arguments) /= ""
         then
            --  A path from the root that names a place in the project, as
            --  the session's agent has it: taken as that place, and said.
            declare
               Have  : Boolean;
               Given : constant String := Text_Argument (Arguments, "path", Have);
               Taken : constant String := Rooted (Named, Arguments);
               At_Path : constant Natural := Ada.Strings.Fixed.Index (Arguments, """" & Given & """");
               Moved : constant String :=
                 Arguments (Arguments'First .. At_Path) & Taken
                 & Arguments (At_Path + Given'Length + 1 .. Arguments'Last);
               Taken_As : constant String := "(" & Given & " is taken as the project's " & Taken & ") ";
            begin
               if Confined (Named, Moved) /= "" then
                  return Failure (Confinement (Named, Moved));
               end if;
               return Prefixed (Taken_As, File_Answer (Named, Moved, U.To_String (Self.Base)));
            end;
         elsif Confined (Named, Arguments) /= "" then
            return Failure (Confinement (Named, Arguments));
         elsif File_Tool (Named) then
            declare
               Have : Boolean;
               Path : constant String := Text_Argument (Arguments, "path", Have);
               Now  : constant String :=
                 (if Writes (Named) and then Have and then Self.Seen.Has (Path)
                  then Model_Runner.Tools.Editing.Revision_Of (Path, U.To_String (Self.Base)) else "");
            begin
               --  Changed under it since it last read or wrote it: made over
               --  what it did not see, the other change would be lost.
               if Now /= "" and then Now /= Self.Seen.Get (Path) then
                  return Failure
                    (Path & " has changed since you last read or wrote it (revision " & Self.Seen.Get (Path)
                     & " then, " & Now & " now), by something other than you: read it again, then"
                     & " change what is there");
               end if;
               declare
                  --  The lines last read of the file, where they were a part.
                  Near : constant String :=
                    (if Named = "edit_file" and then Have and then Self.Read_At.Has (Path)
                     then Self.Read_At.Get (Path) else "");
                  Colon : constant Natural := Ada.Strings.Fixed.Index (Near, ":");

                  function Answered return Reply is
                  begin
                     if Colon > Near'First and then Colon < Near'Last then
                        return Edit_File_Near
                          (Arguments, U.To_String (Self.Base),
                           Natural'Value (Near (Near'First .. Colon - 1)),
                           Natural'Value (Near (Colon + 1 .. Near'Last)));
                     end if;
                     return File_Answer (Named, Arguments, U.To_String (Self.Base));
                  end Answered;

                  Given : constant Reply := Answered;
               begin
                  --  Which lines it read: a part, kept; the whole, none.
                  if Have and then not Given.Failed and then Named in "read_file" | "read_range" then
                     declare
                        First, Last : Long_Long_Integer := 0;
                        Have_F, Have_L : Boolean;
                     begin
                        Integer_Argument (Arguments, "first_line", First, Have_F);
                        Integer_Argument (Arguments, "last_line", Last, Have_L);
                        if Have_F and then First in 1 .. 100_000_000 then
                           Self.Read_At.Put
                             (Path, Ada.Strings.Fixed.Trim (Long_Long_Integer'Image (First), Ada.Strings.Left) & ":"
                                    & (if Have_L and then Last in First .. 100_000_000
                                       then Ada.Strings.Fixed.Trim (Long_Long_Integer'Image (Last), Ada.Strings.Left)
                                       else "100000000"));
                        else
                           Self.Read_At.Put (Path, "");
                        end if;
                     end;
                  end if;
                  --  The file as the agent now knows it, read or written.
                  if Have and then not Given.Failed
                    and then Given.After_Revision /= Model_Runner.Tools.Runner.No_Revision
                  then
                     Self.Seen.Put (Path, Given.After_Revision);
                  end if;
                  return Given;
               end;
            end;
         end if;
         for One of Handlers loop
            if One.Name.all = Named then
               return One.Run (Self, Arguments);
            end if;
         end loop;
         return Failure ("no tool by the name """ & Named & """");
      end Answer;

      --  The run's limits, for a tool that waits to answer to.
      function Entered return Boolean is
      begin
         Tr.Enter (Tr.Context_Of (Self));
         return True;
      end Entered;

      Ready : constant Boolean := Entered;
      pragma Unreferenced (Ready);
      Given : constant Reply := Answer;
      Text  : String renames Given.Text;
      use type Tr.Answer_Kind;
   begin
      Last   := 0;
      Status := E.Success;
      --  Refused where the confinement said so; stopped where the run's
      --  limits stopped it; failed where the tool said it failed.
      Outcome :=
        (if Refused /= Tr.Not_Refused
         then (Answer => Tr.Refused, Refusal => Refused, others => <>)
         elsif Given.Halted /= Tr.Answered
         then (Answer => Given.Halted, Changed => Named /= "write_file"
                                                  and then Tr."=" (Kind (Self, Named), Tr.Changes),
               Tokens => Given.Tokens, others => <>)
         elsif Given.Failed
         then (Answer => Tr.Failed, Tokens => Given.Tokens, others => <>)
         --  A write says whether it changed the file; any other tool that
         --  may change state is taken to have.
         else (Answer => Tr.Answered, Refusal => Tr.Not_Refused,
               Changed => Given.Changed
                          or else (Rg."/=" (Rg.Path_Of (Named), Rg.Writes_Path)
                                   and then Tr."=" (Kind (Self, Named), Tr.Changes)),
               Truncated => Given.Truncated, Tokens => Given.Tokens,
               Before_Revision => Given.Before_Revision, After_Revision => Given.After_Revision,
               Created => Given.Created));
      if Text'Length > Result'Length then
         Status := E.Make (E.Tools_Too_Large);
         return;
      end if;
      Result (Result'First .. Result'First + Text'Length - 1) := Text;
      Last := Result'First + Text'Length - 1;
   end Run;

end Model_Runner.Tools.Builtin;
