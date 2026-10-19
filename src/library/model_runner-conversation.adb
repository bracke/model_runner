with Jsonlib.Documents;
with Jsonlib.Errors;
with Jsonlib.Parsers;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Model_Runner.Text;
with Model_Runner.UTF8;
with Ada.Unchecked_Deallocation;

package body Model_Runner.Conversation is

   package E renames Model_Runner.Errors;

   procedure Free_Storage is
     new Ada.Unchecked_Deallocation (String, Storage_Access);

   ----------------
   -- Role_Name --
   ----------------

   function Role_Name (Item : Role) return String is
   begin
      case Item is
         when System_Role    => return "system";
         when User_Role      => return "user";
         when Assistant_Role => return "assistant";
         when Tool_Role      => return "tool";
         when Developer_Role => return "developer";
      end case;
   end Role_Name;

   ----------
   -- Open --
   ----------

   function Bounds_Of (Item : History) return Model_Runner.Limits.Session_Limits is (Item.Bounds);

   procedure Open
     (Item   : in out History;
      Bounds : Model_Runner.Limits.Session_Limits :=
        Model_Runner.Limits.Default_Session_Limits;
      Status : out E.Error_Info) is
   begin
      Close (Item);
      Item.Bounds := Bounds;
      Item.Storage :=
        new String (1 .. Natural'Max (Bounds.Max_Rendered_Bytes, 1));
      Item.Filled := 0;
      Item.Used := 0;
      Item.Call_Used := 0;
      Status := E.Success;
   exception
      when Storage_Error =>
         Item.Storage := null;
         Status := E.Make (E.Memory_Allocation_Failed);
         E.Add_Text (Status, "category", "template_buffers", E.Param_Identifier);
   end Open;

   -----------
   -- Close --
   -----------

   procedure Close (Item : in out History) is
   begin
      if Item.Storage /= null then
         --  Clear the content before releasing it: a conversation may hold
         --  sensitive prompt text and nothing else in the process needs it.
         Item.Storage.all := [others => ' '];
         Free_Storage (Item.Storage);
      end if;
      Item.Used := 0;
      Item.Filled := 0;
      Item.Call_Used := 0;
   exception
      when others =>
         Item.Used := 0;
         Item.Filled := 0;
         Item.Call_Used := 0;
   end Close;

   --------------
   -- Finalize --
   --------------

   overriding procedure Finalize (Item : in out History) is
   begin
      Close (Item);
   end Finalize;

   -----------
   -- Clear --
   -----------

   procedure Clear (Item : in out History) is
   begin
      Item.Used := 0;
      Item.Filled := 0;
      Item.Call_Used := 0;
   end Clear;

   --  Append content to the storage pool, reporting the slice it occupies.
   procedure Store
     (Item    : in out History;
      Content : String;
      Offset  : out Natural;
      Ok      : out Boolean) is
   begin
      Offset := Item.Filled;
      Ok := Item.Storage /= null
        and then Item.Filled + Content'Length <= Item.Storage.all'Length;

      if Ok and then Content'Length > 0 then
         Item.Storage.all (Item.Filled + 1 .. Item.Filled + Content'Length) :=
           Content;
         Item.Filled := Item.Filled + Content'Length;
      end if;
   end Store;

   ------------
   -- Append --
   ------------

   --  Append a message, saying whether an empty one is a message at all.
   --  Every appended turn comes through here, and the only one that may be
   --  empty is the turn a model spent entirely on tool calls.
   procedure Add
     (Item        : in out History;
      Sender      : Role;
      Content     : String;
      Allow_Empty : Boolean;
      Status      : out E.Error_Info)
   is
      Offset : Natural;
      Ok     : Boolean;
   begin
      Status := E.Success;

      if Content'Length = 0 and then not Allow_Empty then
         Status := E.Make (E.Conversation_Empty);
         E.Add_Text (Status, "role", Role_Name (Sender), E.Param_Identifier);
         return;
      end if;

      if Item.Used >= Max_Messages
        or else Item.Used >= Item.Bounds.Max_Messages
      then
         Status := E.Make (E.Conversation_Too_Long);
         E.Add_Integer
           (Status, "limit",
            Long_Long_Integer
              (Natural'Min (Max_Messages, Item.Bounds.Max_Messages)));
         return;
      end if;

      Store (Item, Content, Offset, Ok);
      if not Ok then
         Status := E.Make (E.Conversation_Too_Long);
         E.Add_Integer
           (Status, "limit",
            Long_Long_Integer (Item.Bounds.Max_Rendered_Bytes),
            E.Param_Bytes);
         return;
      end if;

      Item.Used := Item.Used + 1;
      Item.Messages (Item.Used) :=
        (Sender => Sender, Offset => Offset, Length => Content'Length,
         Parts_Offset => 0, Parts_Length => 0,
         First_Call => 0, Calls => 0);
   end Add;

   ---------------
   -- Unescaped --
   ---------------

   function Unescaped (Escaped : String) return String is
      Hex : constant String := "0123456789abcdef";

      --  The four hex digits at an index, or -1 where they are not.
      function Hex_At (At_Index : Natural) return Integer is
         Value : Integer := 0;
      begin
         if At_Index + 3 > Escaped'Last then
            return -1;
         end if;
         for C of Escaped (At_Index .. At_Index + 3) loop
            case C is
               when '0' .. '9' => Value := Value * 16 + Character'Pos (C) - Character'Pos ('0');
               when 'a' .. 'f' => Value := Value * 16 + Character'Pos (C) - Character'Pos ('a') + 10;
               when 'A' .. 'F' => Value := Value * 16 + Character'Pos (C) - Character'Pos ('A') + 10;
               when others => return -1;
            end case;
         end loop;
         return Value;
      end Hex_At;

      --  What a model wrote, made a JSON string's inside: raw controls and
      --  quotes escaped, an escape JSON has not -- \x, \u short of four
      --  digits -- its character alone, a surrogate half with no other
      --  half dropped.
      function Repaired return String is
         R : Ada.Strings.Unbounded.Unbounded_String;
         I : Natural := Escaped'First;
      begin
         while I <= Escaped'Last loop
            declare
               C : constant Character := Escaped (I);
            begin
               if C = '\' and then I = Escaped'Last then
                  Ada.Strings.Unbounded.Append (R, "\\");
               elsif C = '\' and then Escaped (I + 1) in '"' | '\' | '/' | 'b' | 'f' | 'n' | 'r' | 't' then
                  Ada.Strings.Unbounded.Append (R, Escaped (I .. I + 1));
                  I := I + 1;
               elsif C = '\' and then Escaped (I + 1) = 'u' and then Hex_At (I + 2) >= 0 then
                  declare
                     Code : constant Integer := Hex_At (I + 2);
                     Low  : constant Integer :=
                       (if I + 7 <= Escaped'Last and then Escaped (I + 6 .. I + 7) = "\u"
                        then Hex_At (I + 8) else -1);
                  begin
                     if Code in 16#D800# .. 16#DBFF# and then Low in 16#DC00# .. 16#DFFF# then
                        Ada.Strings.Unbounded.Append (R, Escaped (I .. I + 11));
                        I := I + 11;
                     elsif Code in 16#D800# .. 16#DFFF# then
                        I := I + 5;
                     else
                        Ada.Strings.Unbounded.Append (R, Escaped (I .. I + 5));
                        I := I + 5;
                     end if;
                  end;
               elsif C = '\' then
                  I := I + 1;
                  if Escaped (I) = '"' or else Character'Pos (Escaped (I)) < 32 then
                     goto Escape_One;
                  end if;
                  Ada.Strings.Unbounded.Append (R, Escaped (I));
               elsif C = '"' or else Character'Pos (C) < 32 then
                  goto Escape_One;
               else
                  Ada.Strings.Unbounded.Append (R, C);
               end if;
               goto Next;
               <<Escape_One>>
               Ada.Strings.Unbounded.Append
                 (R, (if Escaped (I) = '"' then "\"""
                      else "\u00" & Hex (Character'Pos (Escaped (I)) / 16 + 1)
                                   & Hex (Character'Pos (Escaped (I)) mod 16 + 1)));
            end;
            <<Next>>
            I := I + 1;
         end loop;
         return Ada.Strings.Unbounded.To_String (R);
      end Repaired;

      Document : Jsonlib.Documents.Document;
      Error    : Jsonlib.Errors.Error_Info;
   begin
      --  Read as JSON is read -- jsonlib -- once it is a JSON string; what
      --  still is none, bytes no UTF-8 has among them, is kept as written.
      Jsonlib.Parsers.Parse ('"' & Repaired & '"', Document, Error);
      if Jsonlib.Errors.Failed (Error)
        or else Jsonlib.Documents."/="
                  (Jsonlib.Documents.Kind (Document, Jsonlib.Documents.Root (Document)),
                   Jsonlib.Documents.String_Value)
      then
         return Escaped;
      end if;
      return Jsonlib.Documents.As_String (Document, Jsonlib.Documents.Root (Document));
   end Unescaped;

   -------------------
   -- Text_Of_Parts --
   -------------------

   function Text_Of_Parts (Parts : String) return String is
      Trimmed : constant String := Model_Runner.Text.Trim (Parts);
      R : Ada.Strings.Unbounded.Unbounded_String;
      I : Natural := Trimmed'First;

      procedure Skip_Blanks is
      begin
         while I <= Trimmed'Last
           and then Trimmed (I) in ' ' | ASCII.LF | ASCII.CR | ASCII.HT
         loop
            I := I + 1;
         end loop;
      end Skip_Blanks;

      --  A JSON string at I, decoded, I left past its closing quote.
      function Read_String return String is
         From : constant Natural := I + 1;
      begin
         I := From;
         while I <= Trimmed'Last and then Trimmed (I) /= '"' loop
            if Trimmed (I) = '\' and then I < Trimmed'Last then
               I := I + 1;
            end if;
            I := I + 1;
         end loop;
         I := I + 1;
         return Unescaped (Trimmed (From .. Natural'Min (I - 2, Trimmed'Last)));
      end Read_String;
   begin
      --  Every "text" key's string value, wherever it stands: a part has
      --  one or none, and no part nests another.
      while I <= Trimmed'Last loop
         if Trimmed (I) = '"' then
            declare
               Key : constant String := Read_String;
            begin
               Skip_Blanks;
               if I <= Trimmed'Last and then Trimmed (I) = ':' then
                  I := I + 1;
                  Skip_Blanks;
                  if I <= Trimmed'Last and then Trimmed (I) = '"' then
                     declare
                        Value : constant String := Read_String;
                     begin
                        if Key = "text" then
                           Ada.Strings.Unbounded.Append (R, Value);
                        end if;
                     end;
                  end if;
               end if;
            end;
         else
            I := I + 1;
         end if;
      end loop;
      return Ada.Strings.Unbounded.To_String (R);
   end Text_Of_Parts;

   ---------------------
   -- Prompt_Of_Parts --
   ---------------------

   function Prompt_Of_Parts
     (Parts : String; Image_Marker, Video_Marker : String) return String
   is
      Trimmed : constant String := Model_Runner.Text.Trim (Parts);
      R : Ada.Strings.Unbounded.Unbounded_String;
      I : Natural := Trimmed'First;
      Depth : Natural := 0;

      --  What the object being read is, and its words, gathered until it
      --  closes and is written out in one go.
      Kind : Ada.Strings.Unbounded.Unbounded_String;
      Words : Ada.Strings.Unbounded.Unbounded_String;

      procedure Skip_Blanks is
      begin
         while I <= Trimmed'Last
           and then Trimmed (I) in ' ' | ASCII.LF | ASCII.CR | ASCII.HT
         loop
            I := I + 1;
         end loop;
      end Skip_Blanks;

      function Read_String return String is
         From : constant Natural := I + 1;
      begin
         I := From;
         while I <= Trimmed'Last and then Trimmed (I) /= '"' loop
            if Trimmed (I) = '\' and then I < Trimmed'Last then
               I := I + 1;
            end if;
            I := I + 1;
         end loop;
         I := I + 1;
         return Unescaped (Trimmed (From .. Natural'Min (I - 2, Trimmed'Last)));
      end Read_String;

      procedure Flush is
         K : constant String := Ada.Strings.Unbounded.To_String (Kind);
      begin
         if K = "text" then
            Ada.Strings.Unbounded.Append (R, Words);
         elsif K = "image" or else K = "image_url" then
            Ada.Strings.Unbounded.Append (R, Image_Marker);
         elsif K = "video" then
            Ada.Strings.Unbounded.Append (R, Video_Marker);
         end if;
         Kind := Ada.Strings.Unbounded.Null_Unbounded_String;
         Words := Ada.Strings.Unbounded.Null_Unbounded_String;
      end Flush;
   begin
      --  Each top-level object is one part; its "type" and "text" are read
      --  wherever they stand in it, and it is written when it closes.
      while I <= Trimmed'Last loop
         case Trimmed (I) is
            when '{' =>
               Depth := Depth + 1;
               I := I + 1;
            when '}' =>
               if Depth = 1 then
                  Flush;
               end if;
               if Depth > 0 then
                  Depth := Depth - 1;
               end if;
               I := I + 1;
            when '"' =>
               if Depth = 1 then
                  declare
                     Key : constant String := Read_String;
                  begin
                     Skip_Blanks;
                     if I <= Trimmed'Last and then Trimmed (I) = ':' then
                        I := I + 1;
                        Skip_Blanks;
                        if I <= Trimmed'Last and then Trimmed (I) = '"' then
                           declare
                              Value : constant String := Read_String;
                           begin
                              if Key = "type" then
                                 Kind :=
                                   Ada.Strings.Unbounded.To_Unbounded_String
                                     (Value);
                              elsif Key = "text" then
                                 Words :=
                                   Ada.Strings.Unbounded.To_Unbounded_String
                                     (Value);
                              end if;
                           end;
                        end if;
                     end if;
                  end;
               else
                  --  A string outside a part: skip it whole.
                  declare
                     Ignore : constant String := Read_String;
                     pragma Unreferenced (Ignore);
                  begin
                     null;
                  end;
               end if;
            when others =>
               I := I + 1;
         end case;
      end loop;
      return Ada.Strings.Unbounded.To_String (R);
   end Prompt_Of_Parts;

   ------------------
   -- Append_Parts --
   ------------------

   procedure Append_Parts
     (Item   : in out History;
      Sender : Role;
      Parts  : String;
      Status : out E.Error_Info)
   is
      Trimmed : constant String := Model_Runner.Text.Trim (Parts);
      Before  : constant Natural := Item.Filled;

      Text_At, Parts_At : Natural;
      Ok : Boolean;
   begin
      Status := E.Success;

      --  A list, and one holding a part: an object between its brackets.
      if Trimmed'Length < 2 or else Trimmed (Trimmed'First) /= '['
        or else Trimmed (Trimmed'Last) /= ']'
        or else (for all C of Trimmed => C /= '{')
      then
         Status := E.Make (E.Conversation_Empty);
         E.Add_Text (Status, "role", Role_Name (Sender), E.Param_Identifier);
         return;
      end if;

      if Item.Used >= Max_Messages
        or else Item.Used >= Item.Bounds.Max_Messages
      then
         Status := E.Make (E.Conversation_Too_Long);
         E.Add_Integer
           (Status, "limit",
            Long_Long_Integer
              (Natural'Min (Max_Messages, Item.Bounds.Max_Messages)));
         return;
      end if;

      declare
         Text : constant String := Text_Of_Parts (Parts);
      begin
         Store (Item, Text, Text_At, Ok);
         if Ok then
            Store (Item, Trimmed, Parts_At, Ok);
         end if;
         if not Ok then
            Item.Filled := Before;
            Status := E.Make (E.Conversation_Too_Long);
            E.Add_Integer
              (Status, "limit",
               Long_Long_Integer (Item.Bounds.Max_Rendered_Bytes),
               E.Param_Bytes);
            return;
         end if;

         Item.Used := Item.Used + 1;
         Item.Messages (Item.Used) :=
           (Sender => Sender, Offset => Text_At, Length => Text'Length,
            Parts_Offset => Parts_At, Parts_Length => Trimmed'Length,
            First_Call => 0, Calls => 0);
      end;
   end Append_Parts;

   --------------
   -- Parts_At --
   --------------

   function Parts_At (Item : History; Index : Positive) return String is
   begin
      if Index > Item.Used or else Item.Storage = null
        or else Item.Messages (Index).Parts_Length = 0
      then
         return "";
      end if;
      declare
         Found : Message renames Item.Messages (Index);
      begin
         return Item.Storage.all
           (Found.Parts_Offset + 1 .. Found.Parts_Offset + Found.Parts_Length);
      end;
   end Parts_At;

   ------------
   -- Append --
   ------------

   procedure Append
     (Item    : in out History;
      Sender  : Role;
      Content : String;
      Status  : out E.Error_Info) is
   begin
      Add (Item, Sender, Content, Allow_Empty => False, Status => Status);
   end Append;

   --------------------
   -- Append_Asking --
   --------------------

   procedure Append_Asking
     (Item    : in out History;
      Content : String;
      Status  : out E.Error_Info) is
   begin
      Add (Item, Assistant_Role, Content, Allow_Empty => True,
           Status => Status);
   end Append_Asking;

   ------------------
   -- Append_Call --
   ------------------

   procedure Append_Call
     (Item      : in out History;
      Named     : String;
      Arguments : String;
      Status    : out E.Error_Info)
   is
      Before : constant Natural := Item.Filled;
      Name_At, Args_At : Natural;
      Ok               : Boolean;
   begin
      Status := E.Success;

      if Item.Used = 0 then
         --  A call belongs to the turn the model wrote it in, and there is
         --  no turn here to belong to.
         Status := E.Make (E.Conversation_Empty);
         E.Add_Text
           (Status, "role", Role_Name (Assistant_Role), E.Param_Identifier);
         return;
      end if;

      if Item.Call_Used >= Max_Calls then
         Status := E.Make (E.Conversation_Too_Long);
         E.Add_Integer (Status, "limit", Long_Long_Integer (Max_Calls));
         return;
      end if;

      Store (Item, Named, Name_At, Ok);
      if Ok then
         Store (Item, Arguments, Args_At, Ok);
      end if;

      if not Ok then
         --  Nothing half-stored: a call that did not fit leaves the history
         --  as it was rather than leaving a name with no arguments after it.
         Item.Filled := Before;
         Status := E.Make (E.Conversation_Too_Long);
         E.Add_Integer
           (Status, "limit",
            Long_Long_Integer (Item.Bounds.Max_Rendered_Bytes),
            E.Param_Bytes);
         return;
      end if;

      Item.Call_Used := Item.Call_Used + 1;
      Item.Calls (Item.Call_Used) :=
        (Name_Offset => Name_At, Name_Length => Named'Length,
         Args_Offset => Args_At, Args_Length => Arguments'Length);

      declare
         Held : Message renames Item.Messages (Item.Used);
      begin
         if Held.Calls = 0 then
            Held.First_Call := Item.Call_Used;
         end if;
         Held.Calls := Held.Calls + 1;
      end;
   end Append_Call;

   -------------------
   -- Append_Reply --
   -------------------

   ----------------------
   -- Closed_Reasoning --
   ----------------------

   function Closed_Reasoning (Reply : String) return String is
      Lead : Positive := Reply'First;
   begin
      if Ada.Strings.Fixed.Index (Reply, "</think>") /= 0 then
         return Reply;
      end if;
      while Lead <= Reply'Last
        and then Reply (Lead) in ' ' | ASCII.HT | ASCII.LF | ASCII.CR
      loop
         Lead := Lead + 1;
      end loop;
      if Reply'Last - Lead + 1 >= 7 and then Reply (Lead .. Lead + 6) = "<think>"
      then
         return Reply & ASCII.LF & "</think>";
      end if;
      return Reply;
   end Closed_Reasoning;

   function Reply_Turn
     (Reply  : String;
      Syntax : Model_Runner.Tools.Call_Syntax) return String
   is (if Model_Runner.Tools."=" (Syntax, Model_Runner.Tools.Harmony_Call)
       then Model_Runner.Tools.Harmony_Answer (Reply)
       else Closed_Reasoning (Reply));

   procedure Append_Reply
     (Item    : in out History;
      Reply   : String;
      Status  : out E.Error_Info;
      Reading : out E.Error_Info;
      Syntax  : Model_Runner.Tools.Call_Syntax :=
        Model_Runner.Tools.Tool_Call_JSON;
      Offered : access constant Model_Runner.Tools.Definitions'Class := null)
   is
      Asked : Model_Runner.Tools.Calls;

      --  Where the reply's answer begins: past the first </think>, or --
      --  where reasoning opens the reply and never closes -- past the
      --  reply's end, since all of it was reasoning. Calls are read only
      --  from there. A reasoning line that names <tool_call> paired with
      --  the real call's close and lost it, and a call drafted in the
      --  reasoning was run. Reasoning is what opens the reply, as
      --  llama.cpp reads it: an answer that mentions <think> further on
      --  keeps its calls. But tagged calls that end the reasoning, nothing
      --  after them, are what it did: qwen3-8b opened a thought, wrote its
      --  call in it and stopped, and the call was taken for an answer
      --  without the line the work asked for.
      function Answer_Start return Positive is
         Close : constant Natural := Ada.Strings.Fixed.Index (Reply, "</think>");
         Lead  : Positive := Reply'First;

         --  Where the tagged calls that end the reply begin, or past its
         --  end where it does not end in one.
         function Trailing_Calls return Positive is
            Open_Tag  : constant String := "<tool_call>";
            Close_Tag : constant String := "</tool_call>";
            Last      : Natural := Reply'Last;
            Start     : Positive := Reply'Last + 1;
         begin
            --  Open_JSON too, which /work reads a JSON template's calls in:
            --  the envelope is what it reads first, and only the envelope
            --  is taken out of a thought, never a bare object.
            if Model_Runner.Tools."/=" (Syntax, Model_Runner.Tools.Tool_Call_JSON)
              and then Model_Runner.Tools."/=" (Syntax, Model_Runner.Tools.Open_JSON)
              and then Model_Runner.Tools."/=" (Syntax, Model_Runner.Tools.Qwen_XML)
            then
               return Start;
            end if;
            loop
               while Last >= Reply'First and then Reply (Last) in ' ' | ASCII.HT | ASCII.LF | ASCII.CR loop
                  Last := Last - 1;
               end loop;
               exit when Last - Reply'First + 1 < Close_Tag'Length
                 or else Reply (Last - Close_Tag'Length + 1 .. Last) /= Close_Tag;
               declare
                  --  The call's opening is the first after the call before it
                  --  closed that a call follows and that reads as one to the
                  --  close: reasoning may talk of the tag, or draft a call and
                  --  write the real one after it, and a call's own arguments
                  --  may spell <tool_call>{.
                  Before : constant Natural :=
                    Ada.Strings.Fixed.Index
                      (Reply (Reply'First .. Last - Close_Tag'Length), Close_Tag, Ada.Strings.Backward);
                  Look   : Positive := (if Before = 0 then Reply'First else Before + Close_Tag'Length);
                  Opens  : Natural := 0;

                  --  Whether the text from an opening to the close reads as
                  --  calls.
                  function Reads (From : Positive) return Boolean is
                     Asked_Here : Model_Runner.Tools.Calls;
                     Status     : E.Error_Info;
                     Found      : Boolean;
                  begin
                     Model_Runner.Tools.Read_Calls
                       (Asked_Here, Reply (From .. Last), Status, Syntax => Syntax, Offered => Offered);
                     Found := E.Is_Ok (Status) and then Model_Runner.Tools.Count (Asked_Here) > 0;
                     Model_Runner.Tools.Close (Asked_Here);
                     return Found;
                  end Reads;
               begin
                  loop
                     declare
                        Found : constant Natural := Ada.Strings.Fixed.Index (Reply (Look .. Last), Open_Tag);
                        After : Positive := Found + Open_Tag'Length;
                     begin
                        exit when Found = 0;
                        while After <= Last and then Reply (After) in ' ' | ASCII.HT | ASCII.LF | ASCII.CR loop
                           After := After + 1;
                        end loop;
                        if After <= Last and then Reply (After) in '{' | '<' and then Reads (Found) then
                           Opens := Found;
                           exit;
                        end if;
                        Look := Found + 1;
                     end;
                  end loop;
                  exit when Opens = 0;
                  Start := Opens;
                  Last := Opens - 1;
               end;
            end loop;
            return Start;
         end Trailing_Calls;
         Opens_Thought : Boolean;
         First_Call    : constant Natural := Ada.Strings.Fixed.Index (Reply, "<tool_call>");
      begin
         while Lead <= Reply'Last
           and then Reply (Lead) in ' ' | ASCII.HT | ASCII.LF | ASCII.CR
         loop
            Lead := Lead + 1;
         end loop;
         Opens_Thought := Reply'Last - Lead + 1 >= 7 and then Reply (Lead .. Lead + 6) = "<think>";
         --  A close ends the reasoning where the reply opened it, or -- one
         --  the prompt opened -- unless it lies inside a call that reads as
         --  one: a call's arguments that spell </think>, in a reply that
         --  never thought, cut the reply inside the call and dropped it;
         --  and a thought the prompt opened may talk of <tool_call> before
         --  it closes.
         if Close /= 0 and then not Opens_Thought and then First_Call /= 0 and then First_Call < Close then
            declare
               --  The call that could hold it: the last opened before it,
               --  and not closed before it. An earlier one -- quoted whole
               --  in the thought, or named in its prose -- read with the
               --  real call after the close, held it shut.
               Opened : constant Natural :=
                 Ada.Strings.Fixed.Index (Reply (Reply'First .. Close), "<tool_call>", Ada.Strings.Backward);
               Closed_Between : constant Boolean :=
                 Opened /= 0 and then Ada.Strings.Fixed.Index (Reply (Opened .. Close), "</tool_call>") /= 0;
               Shut : constant Natural := Ada.Strings.Fixed.Index (Reply (Close .. Reply'Last), "</tool_call>");
               Here : Model_Runner.Tools.Calls;
               Read : E.Error_Info;
               Call_Holds_It : Boolean := False;
            begin
               if Shut /= 0 and then Opened /= 0 and then not Closed_Between then
                  Model_Runner.Tools.Read_Calls
                    (Here, Reply (Opened .. Shut + 11), Read, Syntax => Syntax, Offered => Offered);
                  Call_Holds_It := E.Is_Ok (Read) and then Model_Runner.Tools.Count (Here) > 0;
                  Model_Runner.Tools.Close (Here);
               end if;
               if not Call_Holds_It then
                  return Close + 8;
               end if;
            end;
         elsif Close /= 0 then
            return Close + 8;
         end if;
         if Opens_Thought then
            return Trailing_Calls;
         end if;
         return Reply'First;
      end Answer_Start;

      Answer_At : constant Positive := Answer_Start;

      --  The tagged calls a thought opens with, before any of its reasoning:
      --  no draft, which reasoning's prose would hold, but what was done.
      --  qwen3-8b opened a thought with its edit, began another thought,
      --  and called run_checks after it; the edit was dropped, and the
      --  model went on as if it had been made. Where they lie, or an empty
      --  span.
      type Text_Span is record
         From, Upto : Natural := 0;
      end record;

      function Leading_Span return Text_Span is
         Open_Tag  : constant String := "<tool_call>";
         Close_Tag : constant String := "</tool_call>";
         At_It     : Positive := Reply'First;
         Found     : Text_Span;

         procedure Skip_Space is
         begin
            while At_It <= Reply'Last and then Reply (At_It) in ' ' | ASCII.HT | ASCII.LF | ASCII.CR loop
               At_It := At_It + 1;
            end loop;
         end Skip_Space;

         function Here (Mark : String) return Boolean
         is (Reply'Last - At_It + 1 >= Mark'Length and then Reply (At_It .. At_It + Mark'Length - 1) = Mark);
      begin
         if Model_Runner.Tools."/=" (Syntax, Model_Runner.Tools.Tool_Call_JSON)
           and then Model_Runner.Tools."/=" (Syntax, Model_Runner.Tools.Open_JSON)
           and then Model_Runner.Tools."/=" (Syntax, Model_Runner.Tools.Qwen_XML)
         then
            return Found;
         end if;
         Skip_Space;
         if not Here ("<think>") then
            return Found;
         end if;
         At_It := At_It + 7;
         loop
            Skip_Space;
            exit when not Here (Open_Tag);
            declare
               Shut : constant Natural :=
                 Ada.Strings.Fixed.Index (Reply (At_It .. Reply'Last), Close_Tag);
            begin
               exit when Shut = 0;
               if Found.From = 0 then
                  Found.From := At_It;
               end if;
               Found.Upto := Shut + Close_Tag'Length - 1;
               At_It := Found.Upto + 1;
            end;
         end loop;
         --  Where they run into the answer, the answer reads them already.
         return (if Found.From = 0 or else Found.Upto >= Answer_At then (0, 0) else Found);
      end Leading_Span;

      Lead : constant Text_Span := Leading_Span;

      --  Their text, to be read before the answer's -- each but one the
      --  answer makes again, the same tool with the same arguments: drafted
      --  first and then made, a call is made once.
      function Leading_Calls return String is
         package U renames Ada.Strings.Unbounded;
         Close_Tag : constant String := "</tool_call>";
         Kept      : U.Unbounded_String;
         Answer    : Model_Runner.Tools.Calls;
         Read      : E.Error_Info;
         At_It     : Natural := Lead.From;

         --  Whether the answer makes this call.
         function Repeated (Block : String) return Boolean is
            One    : Model_Runner.Tools.Calls;
            Status : E.Error_Info;
            Found  : Boolean := False;
         begin
            Model_Runner.Tools.Read_Calls (One, Block, Status, Syntax => Syntax, Offered => Offered);
            if E.Is_Ok (Status) and then E.Is_Ok (Read) and then Model_Runner.Tools.Count (One) = 1 then
               for Index in 1 .. Model_Runner.Tools.Count (Answer) loop
                  Found := Found
                    or else (Model_Runner.Tools.Called (Answer, Index) = Model_Runner.Tools.Called (One, 1)
                             and then Model_Runner.Tools.Arguments (Answer, Index)
                                      = Model_Runner.Tools.Arguments (One, 1));
               end loop;
            end if;
            Model_Runner.Tools.Close (One);
            return Found;
         end Repeated;
      begin
         if Lead.From = 0 then
            return "";
         end if;
         Model_Runner.Tools.Read_Calls
           (Answer, Reply (Answer_At .. Reply'Last), Read, Syntax => Syntax, Offered => Offered);
         --  The span is calls and the spaces between them, each closed.
         while At_It > 0 and then At_It <= Lead.Upto loop
            declare
               Shut : constant Natural := Ada.Strings.Fixed.Index (Reply (At_It .. Lead.Upto), Close_Tag);
               Upto : constant Natural := (if Shut = 0 then Lead.Upto else Shut + Close_Tag'Length - 1);
            begin
               if not Repeated (Reply (At_It .. Upto)) then
                  U.Append (Kept, Reply (At_It .. Upto) & ASCII.LF);
               end if;
               At_It := Upto + 1;
            end;
         end loop;
         Model_Runner.Tools.Close (Answer);
         return U.To_String (Kept);
      end Leading_Calls;

      --  The reasoning kept as the turn's, without the calls it opened
      --  with: they are the turn's calls, and kept as text too, a template
      --  that keeps the reasoning wrote each of them twice.
      function Without_Lead (First, Last : Natural) return String
      is (if Lead.From = 0 or else Lead.From < First or else Lead.Upto > Last then Reply (First .. Last)
          else Reply (First .. Lead.From - 1) & Reply (Lead.Upto + 1 .. Last));
   begin
      Model_Runner.Tools.Read_Calls
        (Asked, Leading_Calls & Reply (Answer_At .. Reply'Last), Reading,
         Syntax => Syntax, Offered => Offered);

      --  One block that would not read leaves the calls that did: they
      --  are the turn's, and the agent tells the model of the one lost --
      --  all of them went for one, and the reply was taken as its text.
      --  Too many calls stay none, as the model is told to split them.
      if Model_Runner.Tools.Count (Asked) = 0
        or else (E.Is_Error (Reading) and then not E."=" (Reading.Code, E.Tools_Call_Malformed))
      then
         --  Nothing to take apart, or nothing this can take apart. Either
         --  way the reply is the turn as it arrived -- but for a harmony
         --  reply, whose turn is its final message: its template refuses a
         --  turn that carries the channels' markers.
         --  A thought cut short is kept closed: left open, every later
         --  prompt carried it whole, as the template strips only a closed
         --  one.
         Model_Runner.Tools.Close (Asked);
         Append (Item, Assistant_Role, Reply_Turn (Reply, Syntax), Status);
         return;
      end if;

      declare
         Before      : constant Natural := Item.Used;
         First, Last : Natural;
      begin
         --  What the model said, taking the syntax into account: the prose
         --  before the first block for the tag and JSON forms, the ">>>all"
         --  block's body for Functionary's recipient form -- so a mixed
         --  reply's words are kept beside its calls rather than the raw
         --  blocks being handed back as text.
         Model_Runner.Tools.Spoken_Span
           (Reply (Answer_At .. Reply'Last), Syntax, First, Last);

         --  And the reasoning before it, which is the turn's too.
         if Answer_At > Reply'First
           and then Model_Runner.Tools."/=" (Syntax, Model_Runner.Tools.Recipient_JSON)
         then
            First := Reply'First;
         end if;
         --  Reasoning its calls ended, closed for the template to keep.
         Append_Asking (Item, Closed_Reasoning (Without_Lead (First, Last)), Status);

         for Index in 1 .. Model_Runner.Tools.Count (Asked) loop
            exit when E.Is_Error (Status);
            Append_Call
              (Item,
               Model_Runner.Tools.Called (Asked, Index),
               Model_Runner.Tools.Arguments (Asked, Index),
               Status);
         end loop;

         --  All of the turn or none of it. A turn appended with half its
         --  calls on it is a conversation that says the model asked for one
         --  thing when it asked for two, and the caller who was told the
         --  append failed would have no reason to look.
         if E.Is_Error (Status) then
            Drop_Last (Item, Item.Used - Before);
         end if;
      end;

      Model_Runner.Tools.Close (Asked);
   end Append_Reply;

   -----------------
   -- Set_System --
   -----------------

   procedure Set_System
     (Item    : in out History;
      Content : String;
      Status  : out E.Error_Info)
   is
      type Messages_Access is access Message_Array;
      type Calls_Access is access Call_Array;
      procedure Free is new Ada.Unchecked_Deallocation
        (Message_Array, Messages_Access);
      procedure Free is new Ada.Unchecked_Deallocation
        (Call_Array, Calls_Access);

      Had_System : constant Boolean := Has_System (Item);
      Count      : constant Natural := Item.Used;
   begin
      Status := E.Success;

      if Item.Storage = null then
         Status := E.Make (E.Memory_Allocation_Failed);
         return;
      end if;

      --  Rebuild the history so that the system message is always first and
      --  the storage pool has no gap where a replaced one used to be. The
      --  existing content is copied out first, because rebuilding overwrites
      --  the pool from the start -- onto the heap, not the stack: a history
      --  of sixteen megabytes and its tables, copied onto the task's stack,
      --  ran past it.
      declare
         Scratch_Copy : Storage_Access :=
           new String'(Item.Storage.all (1 .. Item.Filled));
         Saved_Copy   : Messages_Access := new Message_Array'(Item.Messages);
         Asked_Copy   : Calls_Access := new Call_Array'(Item.Calls);
         Scratch      : String renames Scratch_Copy.all;
         Saved        : Message_Array renames Saved_Copy.all;
         Asked        : Call_Array renames Asked_Copy.all;
         First        : constant Positive := (if Had_System then 2 else 1);
         Calls_Before : constant Natural := Item.Call_Used;

         --  A rebuild that cannot finish -- the new text, or what it moves
         --  along, past the room -- leaves the history as it was, not
         --  emptied part way.
         procedure Put_Back is
         begin
            Item.Storage.all (1 .. Scratch'Length) := Scratch;
            Item.Filled := Scratch'Length;
            Item.Used := Count;
            Item.Messages := Saved;
            Item.Calls := Asked;
            Item.Call_Used := Calls_Before;
         end Put_Back;

         procedure Rebuild is
         begin
            Item.Used := 0;
            Item.Filled := 0;
            Item.Call_Used := 0;

            if Content'Length > 0 then
               Append (Item, System_Role, Content, Status);
               if E.Is_Error (Status) then
                  Put_Back;
                  return;
               end if;
            end if;

            for Index in First .. Count loop
               declare
                  Row : Message renames Saved (Index);
               begin
                  --  A turn that asked for tools and said nothing is still a
                  --  turn, and rebuilding the history must not be where it
                  --  stops being one.
                  Add (Item, Row.Sender,
                       Scratch (Row.Offset + 1 .. Row.Offset + Row.Length),
                       Allow_Empty => Row.Calls > 0, Status => Status);
                  if E.Is_Error (Status) then
                     Put_Back;
                     return;
                  end if;

                  --  Its parts -- a picture -- move with it.
                  if Row.Parts_Length > 0 then
                     declare
                        Parts_At : Natural;
                        Ok       : Boolean;
                     begin
                        Store (Item, Scratch (Row.Parts_Offset + 1 .. Row.Parts_Offset + Row.Parts_Length),
                               Parts_At, Ok);
                        if not Ok then
                           Put_Back;
                           Status := E.Make (E.Conversation_Too_Long);
                           E.Add_Integer
                             (Status, "limit", Long_Long_Integer (Item.Bounds.Max_Rendered_Bytes), E.Param_Bytes);
                           return;
                        end if;
                        Item.Messages (Item.Used).Parts_Offset := Parts_At;
                        Item.Messages (Item.Used).Parts_Length := Row.Parts_Length;
                     end;
                  end if;

                  for Which in 0 .. Row.Calls - 1 loop
                     declare
                        From : Call_Row renames Asked (Row.First_Call + Which);
                     begin
                        Append_Call
                          (Item,
                           Scratch (From.Name_Offset + 1
                                    .. From.Name_Offset + From.Name_Length),
                           Scratch (From.Args_Offset + 1
                                    .. From.Args_Offset + From.Args_Length),
                           Status);
                        if E.Is_Error (Status) then
                           Put_Back;
                           return;
                        end if;
                     end;
                  end loop;
               end;
            end loop;
         end Rebuild;
      begin
         Rebuild;
         Free_Storage (Scratch_Copy);
         Free (Saved_Copy);
         Free (Asked_Copy);
      exception
         when others =>
            Free_Storage (Scratch_Copy);
            Free (Saved_Copy);
            Free (Asked_Copy);
            raise;
      end;
   end Set_System;

   ----------------
   -- Drop_Last --
   ----------------

   procedure Drop_Last (Item : in out History; Count : Natural) is
      Removing : constant Natural := Natural'Min (Count, Item.Used);
   begin
      for Step in 1 .. Removing loop
         pragma Unreferenced (Step);
         --  Reclaim the storage of the message being dropped, which is always
         --  the most recently appended one and therefore at the end of the
         --  pool. Its calls were stored after its content and go with it:
         --  taking the pool back to where the content began takes both,
         --  which subtracting the content's length alone would not.
         declare
            Held : Message renames Item.Messages (Item.Used);
         begin
            Item.Filled := Held.Offset;
            if Held.Calls > 0 then
               Item.Call_Used := Held.First_Call - 1;
            end if;
         end;
         Item.Used := Item.Used - 1;
      end loop;
   end Drop_Last;

   -------------
   -- Compact --
   -------------

   procedure Compact
     (Item          : in out History;
      Keep_Recent   : Natural;
      Dropped       : out Natural;
      Work_Record   : String := "";
      Synopsis_Room : Positive := Default_Synopsis)
   is
      N : constant Natural := Item.Used;
      Has_Sys : constant Boolean :=
        N > 0 and then Item.Messages (1).Sender = System_Role;
      First_User : Natural := 0;
      Keep       : array (1 .. Max_Messages) of Boolean := [others => False];

      --  A short digest of the turns being dropped is folded into the task,
      --  after a marker, so a long run keeps the thread of what it has done
      --  even as its oldest turns go. It is bounded and carried forward: each
      --  compaction adds to it and keeps only the most recent Synopsis_Cap
      --  characters, so it can never grow the task without limit.
      Synopsis_Cap : constant Positive :=
        Positive'Max (Least_Synopsis, Synopsis_Room);
      Marker       : constant String :=
        ASCII.LF & ASCII.LF & "[earlier turns this run, compacted:]" & ASCII.LF;
      Record_Marker : constant String :=
        ASCII.LF & "[the work so far, as the harness recorded it:]" & ASCII.LF;
      Digest       : String (1 .. Synopsis_Cap);
      D_Len        : Natural := 0;

      procedure Add (S : String) is
         Room : constant Natural := Natural'Min (S'Length, Synopsis_Cap - D_Len);
         --  Cut short, at a whole character: half of one is not UTF-8, and
         --  a task carrying it could never be tokenized again.
         Take : constant Natural :=
           (if Room = S'Length then Room
            else Model_Runner.UTF8.Safe_Prefix_Length
                   (S (S'First .. S'First + Room - 1)));
      begin
         if Take > 0 then
            Digest (D_Len + 1 .. D_Len + Take) := S (S'First .. S'First + Take - 1);
            D_Len := D_Len + Take;
         end if;
      end Add;

      --  A message's text on one line, blanks collapsed, cut to Cap.
      function One_Line (S : String; Cap : Positive) return String is
         R          : String (1 .. Natural'Min (S'Length, Cap)) :=
           [others => ' '];
         J          : Natural := 0;
         Prev_Space : Boolean := False;
      begin
         for C of S loop
            if J >= R'Length then
               --  Cut at a whole character, as Add cuts.
               return R (1 .. Model_Runner.UTF8.Safe_Prefix_Length (R (1 .. J)));
            end if;
            if C in ' ' | ASCII.LF | ASCII.CR | ASCII.HT then
               if not Prev_Space and then J > 0 then
                  J := J + 1;
                  R (J) := ' ';
                  Prev_Space := True;
               end if;
            else
               J := J + 1;
               R (J) := C;
               Prev_Space := False;
            end if;
         end loop;
         return R (1 .. J);
      end One_Line;

      --  Add the digest line for one dropped message.
      procedure Digest_Message (I : Positive) is
         Src : Message renames Item.Messages (I);
      begin
         case Src.Sender is
            when Assistant_Role =>
               if Src.Calls > 0 then
                  Add ("- called");
                  for K in 0 .. Src.Calls - 1 loop
                     declare
                        Row : Call_Row renames Item.Calls (Src.First_Call + K);
                     begin
                        Add ((if K = 0 then " " else ", ")
                             & Item.Storage.all
                                 (Row.Name_Offset + 1
                                  .. Row.Name_Offset + Row.Name_Length));
                     end;
                  end loop;
                  Add ([1 => ASCII.LF]);
               elsif Src.Length > 0 then
                  Add ("- said: " & One_Line
                         (Item.Storage.all
                            (Src.Offset + 1 .. Src.Offset + Src.Length), 100)
                       & ASCII.LF);
               end if;
            when Tool_Role =>
               Add ("- result: " & One_Line
                      (Item.Storage.all
                         (Src.Offset + 1 .. Src.Offset + Src.Length), 100)
                    & ASCII.LF);
            when User_Role =>
               Add ("- asked: " & One_Line
                      (Item.Storage.all
                         (Src.Offset + 1 .. Src.Offset + Src.Length), 100)
                    & ASCII.LF);
            when System_Role | Developer_Role =>
               null;
         end case;
      end Digest_Message;
   begin
      Dropped := 0;
      if N = 0 or else Item.Storage = null then
         return;
      end if;

      --  The first user turn -- the task -- is kept whatever else goes.
      for I in 1 .. N loop
         if Item.Messages (I).Sender = User_Role then
            First_User := I;
            exit;
         end if;
      end loop;

      if Has_Sys then
         Keep (1) := True;
      end if;
      --  And a developer's instructions wherever they stand, as the system
      --  message is kept: they went with the first compaction, and no digest
      --  line said they had.
      for I in 1 .. N loop
         if Item.Messages (I).Sender = Developer_Role then
            Keep (I) := True;
         end if;
      end loop;
      if First_User /= 0 then
         Keep (First_User) := True;
      end if;

      --  The most recent turns, with the boundary pulled back to an
      --  assistant's turn: past a leading tool turn, so a kept result still
      --  has its call, and past a leading user turn, which would follow the
      --  kept task with no answer between -- a template that holds the
      --  roles to alternating refused the conversation whole.
      declare
         Tail_Start : Natural := Natural'Max (1, N - Keep_Recent + 1);
      begin
         while Tail_Start > 1
           and then Item.Messages (Tail_Start).Sender in Tool_Role | User_Role
           and then Tail_Start > First_User + 1
         loop
            Tail_Start := Tail_Start - 1;
         end loop;
         for I in Tail_Start .. N loop
            Keep (I) := True;
         end loop;
      end;

      for I in 1 .. N loop
         if not Keep (I) then
            Dropped := Dropped + 1;
         end if;
      end loop;
      if Dropped = 0 then
         return;
      end if;

      --  Digest the turns about to go, in order, for the task to carry.
      if First_User /= 0 then
         for I in 1 .. N loop
            if not Keep (I) then
               Digest_Message (I);
            end if;
         end loop;
         --  Nothing of the turns themselves, but a record to carry: the
         --  task is rewritten all the same, to carry it.
         if D_Len = 0 and then Work_Record /= "" then
            Add ([1 => ASCII.LF]);
         end if;
      end if;

      --  Rebuild the pool and tables into fresh storage, keeping order. Each
      --  kept message's content is copied to the front, then its calls' name
      --  and argument slices after it, the way they were first laid down.
      declare
         New_Storage  : constant Storage_Access :=
           new String (Item.Storage.all'Range);
         New_Messages : Message_Array := [others => <>];
         New_Calls    : Call_Array := [others => <>];
         Fill         : Natural := 0;
         Call_Fill    : Natural := 0;
         M            : Natural := 0;
      begin
         for I in 1 .. N loop
            if Keep (I) then
               declare
                  Src     : Message renames Item.Messages (I);
                  New_Off : constant Natural := Fill;
               begin
                  if I = First_User and then D_Len > 0 then
                     --  The task carries the digest. Its stored content is the
                     --  task, then the marker, then the synopsis so far; split
                     --  it back into base and old synopsis, add the new lines,
                     --  and keep only the last Synopsis_Cap characters of the
                     --  synopsis so it stays bounded run after run.
                     declare
                        Old : String renames Item.Storage.all
                          (Src.Offset + 1 .. Src.Offset + Src.Length);
                        M_At : Natural := 0;
                     begin
                        for P in Old'First .. Old'Last - Marker'Length + 1 loop
                           if Old (P .. P + Marker'Length - 1) = Marker then
                              M_At := P;
                              exit;
                           end if;
                        end loop;
                        declare
                           Base_Last : constant Natural :=
                             (if M_At = 0 then Old'Last else M_At - 1);
                           Syn_First : constant Natural :=
                             (if M_At = 0 then Old'Last + 1
                              else M_At + Marker'Length);

                           --  The synopsis so far without the record an
                           --  earlier compaction carried: the record is
                           --  the work as it stands, said once and new
                           --  each time, never a history of itself.
                           function Without_Record (Syn : String) return String is
                           begin
                              for P in Syn'First .. Syn'Last - Record_Marker'Length + 1 loop
                                 if Syn (P .. P + Record_Marker'Length - 1) = Record_Marker then
                                    return Syn (Syn'First .. P - 1);
                                 end if;
                              end loop;
                              return Syn;
                           end Without_Record;

                           Lines     : constant String :=
                             Without_Record (Old (Syn_First .. Old'Last)) & Digest (1 .. D_Len);
                           --  Its last Synopsis_Cap characters, then the
                           --  record whole, where there is one and room.
                           --  Begun at a whole character: the cut skips the
                           --  rest of one it lands inside.
                           function Tail_From return Positive is
                              From : Positive :=
                                Lines'First
                                + Natural'Max (0, Lines'Length - Synopsis_Cap);
                           begin
                              while From <= Lines'Last
                                and then Character'Pos (Lines (From)) in 16#80# .. 16#BF#
                                and then From > Lines'First
                              loop
                                 From := From + 1;
                              end loop;
                              return From;
                           end Tail_From;
                           Kept      : constant String :=
                             Lines (Tail_From .. Lines'Last);
                           Recorded  : constant String :=
                             (if Work_Record = "" then ""
                              else Record_Marker & Work_Record);
                           Room_Left : constant Integer :=
                             New_Storage.all'Last - Fill - (Base_Last - Old'First + 1)
                             - Marker'Length - Kept'Length - Src.Parts_Length;
                           Synopsis  : constant String :=
                             Kept & (if Recorded'Length <= Room_Left then Recorded else "");
                        begin
                           --  Base, then the marker, then the synopsis.
                           New_Storage.all (Fill + 1 .. Fill + Base_Last
                                            - Old'First + 1) :=
                             Old (Old'First .. Base_Last);
                           Fill := Fill + Base_Last - Old'First + 1;
                           New_Storage.all (Fill + 1 .. Fill + Marker'Length) :=
                             Marker;
                           Fill := Fill + Marker'Length;
                           New_Storage.all (Fill + 1 .. Fill + Synopsis'Length) := Synopsis;
                           Fill := Fill + Synopsis'Length;
                        end;
                     end;
                     M := M + 1;
                     New_Messages (M) :=
                       (Sender     => Src.Sender,
                        Offset     => New_Off,
                        Length     => Fill - New_Off,
                        Parts_Offset => 0,
                        Parts_Length => 0,
                        First_Call => 0,
                        Calls      => 0);
                     --  Its parts -- a picture the task was asked about --
                     --  go along with it, as any kept turn's do.
                     if Src.Parts_Length > 0 and then Fill + Src.Parts_Length <= New_Storage.all'Last then
                        New_Storage.all (Fill + 1 .. Fill + Src.Parts_Length) :=
                          Item.Storage.all (Src.Parts_Offset + 1 .. Src.Parts_Offset + Src.Parts_Length);
                        New_Messages (M).Parts_Offset := Fill;
                        New_Messages (M).Parts_Length := Src.Parts_Length;
                        Fill := Fill + Src.Parts_Length;
                     end if;
                     goto Next_Message;
                  end if;

                  New_Storage.all (Fill + 1 .. Fill + Src.Length) :=
                    Item.Storage.all (Src.Offset + 1 .. Src.Offset + Src.Length);
                  Fill := Fill + Src.Length;
                  M := M + 1;
                  New_Messages (M) :=
                    (Sender     => Src.Sender,
                     Offset     => New_Off,
                     Length     => Src.Length,
                     Parts_Offset => 0,
                     Parts_Length => 0,
                     First_Call =>
                       (if Src.Calls > 0 then Call_Fill + 1 else 0),
                     Calls      => Src.Calls);

                  --  The parts go along with the words.
                  if Src.Parts_Length > 0 then
                     New_Storage.all (Fill + 1 .. Fill + Src.Parts_Length) :=
                       Item.Storage.all
                         (Src.Parts_Offset + 1
                          .. Src.Parts_Offset + Src.Parts_Length);
                     New_Messages (M).Parts_Offset := Fill;
                     New_Messages (M).Parts_Length := Src.Parts_Length;
                     Fill := Fill + Src.Parts_Length;
                  end if;

                  for K in 0 .. Src.Calls - 1 loop
                     declare
                        Row      : Call_Row renames
                          Item.Calls (Src.First_Call + K);
                        Name_Off : constant Natural := Fill;
                        Args_Off : Natural;
                     begin
                        New_Storage.all
                          (Fill + 1 .. Fill + Row.Name_Length) :=
                          Item.Storage.all
                            (Row.Name_Offset + 1
                             .. Row.Name_Offset + Row.Name_Length);
                        Fill := Fill + Row.Name_Length;
                        Args_Off := Fill;
                        New_Storage.all
                          (Fill + 1 .. Fill + Row.Args_Length) :=
                          Item.Storage.all
                            (Row.Args_Offset + 1
                             .. Row.Args_Offset + Row.Args_Length);
                        Fill := Fill + Row.Args_Length;
                        Call_Fill := Call_Fill + 1;
                        New_Calls (Call_Fill) :=
                          (Name_Offset => Name_Off,
                           Name_Length => Row.Name_Length,
                           Args_Offset => Args_Off,
                           Args_Length => Row.Args_Length);
                     end;
                  end loop;
               end;
               <<Next_Message>>
               null;
            end if;
         end loop;

         Free_Storage (Item.Storage);
         Item.Storage   := New_Storage;
         Item.Messages  := New_Messages;
         Item.Calls     := New_Calls;
         Item.Used      := M;
         Item.Filled    := Fill;
         Item.Call_Used := Call_Fill;
      end;
   end Compact;

   ------------
   -- Length --
   ------------

   function Length (Item : History) return Natural is (Item.Used);

   ----------------
   -- Sender_At --
   ----------------

   function Sender_At (Item : History; Index : Positive) return Role
   is (if Index > Item.Used then User_Role else Item.Messages (Index).Sender);

   -----------------
   -- Content_At --
   -----------------

   function Content_At (Item : History; Index : Positive) return String is
   begin
      if Index > Item.Used or else Item.Storage = null then
         return "";
      end if;

      declare
         Found : Message renames Item.Messages (Index);
      begin
         if Found.Length = 0 then
            return "";
         end if;
         return Item.Storage.all (Found.Offset + 1 .. Found.Offset + Found.Length);
      end;
   end Content_At;

   -----------------
   -- Call_Count --
   -----------------

   function Call_Count (Item : History; Index : Positive) return Natural
   is (if Index > Item.Used then 0 else Item.Messages (Index).Calls);

   --  Where one call of one message lies, or nothing when either position
   --  is out of range. Written once because both readers below ask it.
   function Row_Of
     (Item : History; Index : Positive; Call : Positive) return Natural
   is (if Index > Item.Used or else Call > Item.Messages (Index).Calls
       then 0
       else Item.Messages (Index).First_Call + Call - 1);

   ----------------
   -- Call_Name --
   ----------------

   function Call_Name
     (Item : History; Index : Positive; Call : Positive) return String
   is
      Where : constant Natural := Row_Of (Item, Index, Call);
   begin
      if Where = 0 or else Item.Storage = null then
         return "";
      end if;

      declare
         Found : Call_Row renames Item.Calls (Where);
      begin
         return Item.Storage.all
           (Found.Name_Offset + 1 .. Found.Name_Offset + Found.Name_Length);
      end;
   end Call_Name;

   ---------------------
   -- Call_Arguments --
   ---------------------

   function Call_Arguments
     (Item : History; Index : Positive; Call : Positive) return String
   is
      Where : constant Natural := Row_Of (Item, Index, Call);
   begin
      if Where = 0 or else Item.Storage = null then
         return "";
      end if;

      declare
         Found : Call_Row renames Item.Calls (Where);
      begin
         return Item.Storage.all
           (Found.Args_Offset + 1 .. Found.Args_Offset + Found.Args_Length);
      end;
   end Call_Arguments;

   -----------------
   -- Has_System --
   -----------------

   function Has_System (Item : History) return Boolean
   is (Item.Used > 0 and then Item.Messages (1).Sender = System_Role);

end Model_Runner.Conversation;
