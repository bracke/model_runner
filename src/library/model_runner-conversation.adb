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
   exception
      when others =>
         Item.Used := 0;
         Item.Filled := 0;
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

   procedure Append
     (Item    : in out History;
      Sender  : Role;
      Content : String;
      Status  : out E.Error_Info)
   is
      Offset : Natural;
      Ok     : Boolean;
   begin
      Status := E.Success;

      if Content'Length = 0 then
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
        (Sender => Sender, Offset => Offset, Length => Content'Length);
   end Append;

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

         if Content'Length > 0 then
            Append (Item, System_Role, Content, Status);
            if E.Is_Error (Status) then
               return;
            end if;
         end if;

         for Index in First .. Count loop
            Append
              (Item, Saved (Index).Sender,
               Scratch (Saved (Index).Offset + 1
                        .. Saved (Index).Offset + Saved (Index).Length),
               Status);
            if E.Is_Error (Status) then
               return;
            end if;
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
         --  pool.
         Item.Filled := Item.Filled - Item.Messages (Item.Used).Length;
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
   -- Has_System --
   -----------------

   function Has_System (Item : History) return Boolean
   is (Item.Used > 0 and then Item.Messages (1).Sender = System_Role);

end Model_Runner.Conversation;
