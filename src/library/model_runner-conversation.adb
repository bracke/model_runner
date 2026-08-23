with Ada.Unchecked_Deallocation;

with Model_Runner.Tools;

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
         First_Call => 0, Calls => 0);
   end Add;

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
      Reading : out E.Error_Info)
   is
      Asked : Model_Runner.Tools.Calls;
   begin
      Model_Runner.Tools.Read_Calls (Asked, Reply, Reading);

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
