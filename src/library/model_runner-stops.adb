with Ada.Unchecked_Deallocation;

package body Model_Runner.Stops is

   use type Model_Runner.Tokenizer.Token_Id;

   package E renames Model_Runner.Errors;

   procedure Free_Storage is
     new Ada.Unchecked_Deallocation (String, Storage_Access);

   ----------
   -- Open --
   ----------

   procedure Open
     (Item   : in out Set;
      Bounds : Model_Runner.Limits.Session_Limits :=
        Model_Runner.Limits.Default_Session_Limits) is
   begin
      Close (Item);
      Item.Bounds := Bounds;
      Item.Storage :=
        new String (1 .. Natural'Max (Bounds.Max_Stop_Storage_Bytes, 1));
      Item.Storage_Used := 0;
   exception
      when Storage_Error =>
         Item.Storage := null;
   end Open;

   -----------
   -- Close --
   -----------

   procedure Close (Item : in out Set) is
   begin
      if Item.Storage /= null then
         Free_Storage (Item.Storage);
      end if;
      Item.Tokens_Used := 0;
      Item.Strings_Used := 0;
      Item.Storage_Used := 0;
      Item.Longest := 0;
   exception
      when others =>
         Item.Tokens_Used := 0;
         Item.Strings_Used := 0;
   end Close;

   --------------
   -- Finalize --
   --------------

   overriding procedure Finalize (Item : in out Set) is
   begin
      Close (Item);
   end Finalize;

   --  Build the diagnostic shared by the two limit failures.
   function Rejected (Field : String; Limit : Natural) return E.Error_Info is
      Result : E.Error_Info := E.Make (E.Generation_Invalid_Request);
   begin
      E.Add_Text (Result, "field", Field, E.Param_Identifier);
      E.Add_Integer (Result, "limit", Long_Long_Integer (Limit));
      return Result;
   end Rejected;

   ----------------
   -- Add_Token --
   ----------------

   procedure Add_Token
     (Item   : in out Set;
      Token  : Token_Id;
      Status : out E.Error_Info) is
   begin
      Status := E.Success;

      if Token < 0 then
         Status := E.Make (E.Tokenizer_Invalid_Token_Id);
         E.Add_Integer (Status, "token", Long_Long_Integer (Token));
         return;
      end if;

      --  Adding the same token twice is not an error; it just has no effect.
      if Is_Stop_Token (Item, Token) then
         return;
      end if;

      if Item.Tokens_Used >= Max_Token_Slots
        or else Item.Tokens_Used >= Item.Bounds.Max_Stop_Tokens
      then
         Status := Rejected
           ("stop_token",
            Natural'Min (Max_Token_Slots, Item.Bounds.Max_Stop_Tokens));
         return;
      end if;

      Item.Tokens_Used := Item.Tokens_Used + 1;
      Item.Tokens (Item.Tokens_Used) := Token;
   end Add_Token;

   -----------------
   -- Add_String --
   -----------------

   procedure Add_String
     (Item   : in out Set;
      Text   : String;
      Status : out E.Error_Info) is
   begin
      Status := E.Success;

      if Text'Length = 0 then
         Status := E.Make (E.Generation_Invalid_Request);
         E.Add_Text (Status, "field", "stop_string", E.Param_Identifier);
         return;
      end if;

      if Item.Strings_Used >= Max_String_Slots
        or else Item.Strings_Used >= Item.Bounds.Max_Stop_Strings
      then
         Status := Rejected
           ("stop_string_count",
            Natural'Min (Max_String_Slots, Item.Bounds.Max_Stop_Strings));
         return;
      end if;

      if Text'Length > Item.Bounds.Max_Stop_String_Bytes then
         Status := Rejected
           ("stop_string_length", Item.Bounds.Max_Stop_String_Bytes);
         return;
      end if;

      if Item.Storage = null
        or else Item.Storage_Used + Text'Length > Item.Storage.all'Length
      then
         Status := Rejected
           ("stop_string_storage", Item.Bounds.Max_Stop_Storage_Bytes);
         return;
      end if;

      Item.Storage.all (Item.Storage_Used + 1 .. Item.Storage_Used + Text'Length)
        := Text;
      Item.Strings_Used := Item.Strings_Used + 1;
      Item.Extents (Item.Strings_Used) :=
        (Offset => Item.Storage_Used, Length => Text'Length);
      Item.Storage_Used := Item.Storage_Used + Text'Length;

      if Text'Length > Item.Longest then
         Item.Longest := Text'Length;
      end if;
   end Add_String;

   --------------------
   -- Is_Stop_Token --
   --------------------

   function Is_Stop_Token (Item : Set; Token : Token_Id) return Boolean is
   begin
      for Index in 1 .. Item.Tokens_Used loop
         if Item.Tokens (Index) = Token then
            return True;
         end if;
      end loop;
      return False;
   end Is_Stop_Token;

   ------------------
   -- Token_Count --
   ------------------

   function Token_Count (Item : Set) return Natural is (Item.Tokens_Used);

   -------------------
   -- String_Count --
   -------------------

   function String_Count (Item : Set) return Natural is (Item.Strings_Used);

   ---------------------
   -- Longest_String --
   ---------------------

   function Longest_String (Item : Set) return Natural is (Item.Longest);

   ----------
   -- Scan --
   ----------

   procedure Scan
     (Item   : Set;
      Buffer : String;
      First  : out Natural;
      Length : out Natural) is
   begin
      First := 0;
      Length := 0;

      if Item.Strings_Used = 0 or else Buffer'Length = 0 then
         return;
      end if;

      --  Scan left to right so that the earliest match wins, and at each
      --  position keep the longest match. Both rules are needed for a
      --  deterministic result when stop strings overlap.
      for Position in Buffer'Range loop
         for Index in 1 .. Item.Strings_Used loop
            declare
               Span  : Extent renames Item.Extents (Index);
               Piece : constant String :=
                 Item.Storage.all (Span.Offset + 1 .. Span.Offset + Span.Length);
            begin
               if Span.Length > Length
                 and then Position + Span.Length - 1 <= Buffer'Last
                 and then Buffer (Position .. Position + Span.Length - 1) = Piece
               then
                  First := Position;
                  Length := Span.Length;
               end if;
            end;
         end loop;

         exit when First /= 0;
      end loop;
   end Scan;

end Model_Runner.Stops;
