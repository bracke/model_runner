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
      R : Ada.Strings.Unbounded.Unbounded_String;
      I : Natural := Escaped'First;

      --  The four hex digits at I, or -1 where they are not.
      function Hex_At (At_Index : Natural) return Integer is
         Value : Integer := 0;
      begin
         if At_Index + 3 > Escaped'Last then
            return -1;
         end if;
         for K in At_Index .. At_Index + 3 loop
            declare
               C : constant Character := Escaped (K);
            begin
               Value := Value * 16
                 + (if C in '0' .. '9' then Character'Pos (C) - Character'Pos ('0')
                    elsif C in 'a' .. 'f'
                    then Character'Pos (C) - Character'Pos ('a') + 10
                    elsif C in 'A' .. 'F'
                    then Character'Pos (C) - Character'Pos ('A') + 10
                    else 0);
               if C not in '0' .. '9' | 'a' .. 'f' | 'A' .. 'F' then
                  return -1;
               end if;
            end;
         end loop;
         return Value;
      end Hex_At;
   begin
      while I <= Escaped'Last loop
         if Escaped (I) = '\' and then I < Escaped'Last then
            I := I + 1;
            case Escaped (I) is
               when 'n' => Ada.Strings.Unbounded.Append (R, ASCII.LF);
               when 't' => Ada.Strings.Unbounded.Append (R, ASCII.HT);
               when 'r' => Ada.Strings.Unbounded.Append (R, ASCII.CR);
               when 'b' => Ada.Strings.Unbounded.Append (R, ASCII.BS);
               when 'f' => Ada.Strings.Unbounded.Append (R, ASCII.FF);
               when 'u' =>
                  declare
                     Code : Integer := Hex_At (I + 1);
                  begin
                     if Code < 0 then
                        Ada.Strings.Unbounded.Append (R, 'u');
                     else
                        I := I + 4;
                        --  A high surrogate followed by \u and a low one is
                        --  one character past the basic plane.
                        if Code in 16#D800# .. 16#DBFF#
                          and then I + 2 <= Escaped'Last
                          and then Escaped (I + 1) = '\'
                          and then Escaped (I + 2) = 'u'
                        then
                           declare
                              Low : constant Integer := Hex_At (I + 3);
                           begin
                              if Low in 16#DC00# .. 16#DFFF# then
                                 Code := 16#10000#
                                   + (Code - 16#D800#) * 16#400#
                                   + (Low - 16#DC00#);
                                 I := I + 6;
                              end if;
                           end;
                        end if;
                        if Code not in 16#D800# .. 16#DFFF# then
                           Ada.Strings.Unbounded.Append
                             (R, Model_Runner.UTF8.Encode (Code));
                        end if;
                     end if;
                  end;
               when others =>
                  Ada.Strings.Unbounded.Append (R, Escaped (I));
            end case;
         else
            Ada.Strings.Unbounded.Append (R, Escaped (I));
         end if;
         I := I + 1;
      end loop;
      return Ada.Strings.Unbounded.To_String (R);
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

   procedure Append_Reply
     (Item    : in out History;
      Reply   : String;
      Status  : out E.Error_Info;
      Reading : out E.Error_Info;
      Syntax  : Model_Runner.Tools.Call_Syntax :=
        Model_Runner.Tools.Tool_Call_JSON)
   is
      Asked : Model_Runner.Tools.Calls;
   begin
      Model_Runner.Tools.Read_Calls (Asked, Reply, Reading, Syntax => Syntax);

      if E.Is_Error (Reading)
        or else Model_Runner.Tools.Count (Asked) = 0
      then
         --  Nothing to take apart, or nothing this can take apart. Either
         --  way the reply is the turn, exactly as it arrived.
         Model_Runner.Tools.Close (Asked);
         Append (Item, Assistant_Role, Reply, Status);
         return;
      end if;

      declare
         Before : constant Natural := Item.Used;
      begin
         Append_Asking
           (Item,
            Reply (Reply'First
                   .. Reply'First
                      + Model_Runner.Tools.Spoken_Length (Reply) - 1),
            Status);

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
      Had_System : constant Boolean := Has_System (Item);
      Count      : constant Natural := Item.Used;
      Saved      : constant Message_Array := Item.Messages;
      Asked      : constant Call_Array := Item.Calls;
   begin
      Status := E.Success;

      if Item.Storage = null then
         Status := E.Make (E.Memory_Allocation_Failed);
         return;
      end if;

      --  Rebuild the history so that the system message is always first and
      --  the storage pool has no gap where a replaced one used to be. The
      --  existing content is copied out first, because rebuilding overwrites
      --  the pool from the start.
      declare
         Scratch : constant String := Item.Storage.all (1 .. Item.Filled);
         First   : constant Positive := (if Had_System then 2 else 1);
      begin
         Item.Used := 0;
         Item.Filled := 0;
         Item.Call_Used := 0;

         if Content'Length > 0 then
            Append (Item, System_Role, Content, Status);
            if E.Is_Error (Status) then
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
                  return;
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
                        return;
                     end if;
                  end;
               end loop;
            end;
         end loop;
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
     (Item        : in out History;
      Keep_Recent : Natural;
      Dropped     : out Natural)
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
      Synopsis_Cap : constant := 2560;
      Marker       : constant String :=
        ASCII.LF & ASCII.LF & "[earlier turns this run, compacted:]" & ASCII.LF;
      Digest       : String (1 .. Synopsis_Cap);
      D_Len        : Natural := 0;

      procedure Add (S : String) is
         Take : constant Natural := Natural'Min (S'Length, Synopsis_Cap - D_Len);
      begin
         if Take > 0 then
            Digest (D_Len + 1 .. D_Len + Take) := S (S'First .. S'First + Take - 1);
            D_Len := D_Len + Take;
         end if;
      end Add;

      --  A message's text on one line, blanks collapsed, cut to Cap.
      function One_Line (S : String; Cap : Positive) return String is
         R          : String (1 .. Natural'Min (S'Length, Cap));
         J          : Natural := 0;
         Prev_Space : Boolean := False;
      begin
         for C of S loop
            exit when J >= R'Length;
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
      if First_User /= 0 then
         Keep (First_User) := True;
      end if;

      --  The most recent turns, with the boundary pulled back past a leading
      --  tool turn so a kept result still has its call.
      declare
         Tail_Start : Natural := Natural'Max (1, N - Keep_Recent + 1);
      begin
         while Tail_Start > 1
           and then Item.Messages (Tail_Start).Sender = Tool_Role
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
                           Old_Syn   : String renames Old (Syn_First .. Old'Last);
                           Combined  : constant Natural := Old_Syn'Length + D_Len;
                           Kept      : constant Natural :=
                             Natural'Min (Combined, Synopsis_Cap);
                           Skip      : constant Natural := Combined - Kept;
                        begin
                           --  Base, then the marker.
                           New_Storage.all (Fill + 1 .. Fill + Base_Last
                                            - Old'First + 1) :=
                             Old (Old'First .. Base_Last);
                           Fill := Fill + Base_Last - Old'First + 1;
                           New_Storage.all (Fill + 1 .. Fill + Marker'Length) :=
                             Marker;
                           Fill := Fill + Marker'Length;
                           --  The last Kept characters of Old_Syn & Digest.
                           if Skip < Old_Syn'Length then
                              New_Storage.all
                                (Fill + 1 .. Fill + Old_Syn'Length - Skip) :=
                                Old_Syn (Old_Syn'First + Skip .. Old_Syn'Last);
                              Fill := Fill + Old_Syn'Length - Skip;
                              New_Storage.all (Fill + 1 .. Fill + D_Len) :=
                                Digest (1 .. D_Len);
                              Fill := Fill + D_Len;
                           else
                              declare
                                 D_Skip : constant Natural :=
                                   Skip - Old_Syn'Length;
                              begin
                                 New_Storage.all
                                   (Fill + 1 .. Fill + D_Len - D_Skip) :=
                                   Digest (D_Skip + 1 .. D_Len);
                                 Fill := Fill + D_Len - D_Skip;
                              end;
                           end if;
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
