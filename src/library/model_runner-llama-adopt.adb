separate (Model_Runner.Llama)
procedure Adopt
  (Item   : in out Session;
   Source : Model'Class;
   From   : B.Byte_Array;
   Status : out E.Error_Info)
is
   use type Interfaces.Unsigned_32;

   Settings : constant Configuration := Source.Settings;

   KV_Width : constant Element_Count :=
     Element_Count (Settings.KV_Heads * Settings.Head_Size);
   V_Width  : constant Element_Count :=
     Element_Count (Settings.KV_Heads * Settings.Value_Size);

   At_Byte : B.Byte_Count := 0;
   Trouble : Boolean := False;

   procedure Refuse (Code : E.Error_Code; What : String) is
   begin
      if not Trouble then
         Trouble := True;
         Status := E.Make (Code);
         E.Add_Text (Status, "construct", What, E.Param_Text);
      end if;
   end Refuse;

   function Get return Interfaces.Unsigned_64 is
      Ok : Boolean;
      Value : Interfaces.Unsigned_64;
   begin
      if Trouble then
         return 0;
      end if;

      Value := B.Get_U64 (From, At_Byte, Ok);
      if not Ok then
         Refuse (E.Lifecycle_Cache_Unreadable, "truncated");
         return 0;
      end if;

      At_Byte := At_Byte + 8;
      return Value;
   end Get;

   function Get_Bits return Interfaces.Unsigned_32 is
      Ok : Boolean;
      Value : Interfaces.Unsigned_32;
   begin
      if Trouble then
         return 0;
      end if;

      Value := B.Get_U32 (From, At_Byte, Ok);
      if not Ok then
         Refuse (E.Lifecycle_Cache_Unreadable, "truncated");
         return 0;
      end if;

      At_Byte := At_Byte + 4;
      return Value;
   end Get_Bits;

   --  Whether the file holds the caches as halves, two bytes an element,
   --  rather than four: what the precision word says past its sixty-four.
   Narrow : Boolean := False;

   --  One element of a cache, as the four bytes a wide file holds it in:
   --  a narrow file's half widened to the binary32 it stands for, or kept
   --  as its bits where the session holds halves.
   function Get_Element return Interfaces.Unsigned_32 is
      Ok   : Boolean;
      Bits : Interfaces.Unsigned_16;
   begin
      if not Narrow then
         return Get_Bits;
      end if;

      if Trouble then
         return 0;
      end if;

      Bits := B.Get_U16 (From, At_Byte, Ok);
      if not Ok then
         Refuse (E.Lifecycle_Cache_Unreadable, "truncated");
         return 0;
      end if;
      At_Byte := At_Byte + 2;

      return (if Item.Held = Halved
              then Interfaces.Unsigned_32 (Bits)
              else N.Bits (N.To_Real (N.Half (Bits))));
   end Get_Element;

   --  One run of the cache, into whichever storage the session holds. A
   --  byte cache is filled a row at a time rather than an element at a
   --  time, because the scale a row is written with is the largest
   --  magnitude in it and there is no such thing until the row is whole.
   procedure Get_Run
     (Keys : Boolean; First : Element_Count; Count : Element_Count)
   is
      Width : constant Element_Count :=
        (if Keys then KV_Width else V_Width);
   begin
      --  A narrow file into an exact session, a run at once: the halves
      --  read where they lie in the file and widened in one loop. An
      --  element at a time, through the readers above, was most of what
      --  reading a saved session of 0.6 GB took.
      if Narrow and then Item.Held = Exact and then not Trouble then
         if At_Byte + B.Byte_Count (Count) * 2 > From'Length then
            Refuse (E.Lifecycle_Cache_Unreadable, "truncated");
            return;
         end if;

         declare
            Halves : N.Half_Array (0 .. Count - 1)
              with Import, Address => From (From'First + At_Byte)'Address;
            Finite : Boolean := True;

            procedure Widen (Into : in out N.Real_Array) is
            begin
               for Index in 0 .. Count - 1 loop
                  Into (First + Index) := N.To_Real (Halves (Index));
               end loop;
               for Index in 0 .. Count - 1 loop
                  Finite := Finite and then N.Is_Finite (Into (First + Index));
               end loop;
            end Widen;
         begin
            if Keys then
               Widen (Item.Keys.all);
            else
               Widen (Item.Values.all);
            end if;
            if not Finite then
               Refuse (E.Lifecycle_Cache_Unreadable, "not a number");
               return;
            end if;
         end;
         At_Byte := At_Byte + B.Byte_Count (Count) * 2;
         return;
      end if;

      for Index in 0 .. Count - 1 loop
         declare
            Bits : constant Interfaces.Unsigned_32 := Get_Element;
         begin
            exit when Trouble;

            if Item.Held = Exact then
               declare
                  Value : constant Real := N.From_Bits (Bits);
               begin
                  --  A cache of not-a-number would poison every later
                  --  position, and these bytes are untrusted.
                  if not N.Is_Finite (Value) then
                     Refuse (E.Lifecycle_Cache_Unreadable, "not a number");
                     exit;
                  end if;

                  if Keys then
                     Item.Keys.all (First + Index) := Value;
                  else
                     Item.Values.all (First + Index) := Value;
                  end if;
               end;
            elsif Item.Held in Eighth | Fourth then
               declare
                  Value : constant Real := N.From_Bits (Bits);
               begin
                  if not N.Is_Finite (Value) then
                     Refuse (E.Lifecycle_Cache_Unreadable, "not a number");
                     exit;
                  end if;

                  if Keys then
                     Item.Key_Row.all (Index mod Width) := Value;
                  else
                     Item.Value_Row.all (Index mod Width) := Value;
                  end if;

                  if Index mod Width = Width - 1 then
                     if Keys then
                        Pack_Row
                          (Item.Key_Row.all (0 .. Width - 1),
                           Item.Byte_Keys.all, First + Index - Width + 1,
                           Width, Item.Key_Scales.all, Item.Held);
                     else
                        Pack_Row
                          (Item.Value_Row.all (0 .. Width - 1),
                           Item.Byte_Values.all, First + Index - Width + 1,
                           Width, Item.Value_Scales.all, Item.Held_Values);
                     end if;
                  end if;
               end;
            else
               declare
                  Value : constant N.Half :=
                    N.Half (Bits and 16#FFFF#);
               begin
                  if not N.Is_Finite (N.To_Real (Value)) then
                     Refuse (E.Lifecycle_Cache_Unreadable, "not a number");
                     exit;
                  end if;

                  if Keys then
                     Item.Half_Keys.all (First + Index) := Value;
                  else
                     Item.Half_Values.all (First + Index) := Value;
                  end if;
               end;
            end if;
         end;
      end loop;
   end Get_Run;

   Held : Element_Count := 0;
begin
   --  What the host is about to be given is the copy of record,
   --  so whatever the device was owed for is no longer owed: the
   --  positions it wrote are the ones being replaced.
   Item.Owed_Count := 0;

   Status := E.Success;

   if Item.Current not in Ready | Evaluating_Prompt | Generating
     or else Item.Owner = null
   then
      Status := E.Make (E.Lifecycle_Invalid_State);
      return;
   end if;

   --  Nothing of what was there survives, whether or not this succeeds.
   Reset (Item);

   declare
      Magic   : constant Interfaces.Unsigned_64 := Get;
      Version : constant Interfaces.Unsigned_64 := Get;
      Mark    : constant Interfaces.Unsigned_64 := Get;
      Layers  : constant Interfaces.Unsigned_64 := Get;
      KV      : constant Interfaces.Unsigned_64 := Get;
      Wide    : constant Interfaces.Unsigned_64 := Get;
      Deep    : constant Interfaces.Unsigned_64 := Get;
      Room    : constant Interfaces.Unsigned_64 := Get;
      Filled  : constant Interfaces.Unsigned_64 := Get;
      Packed  : constant Interfaces.Unsigned_64 := Get;
   begin
      if not Trouble and then Magic /= Session_Magic then
         Refuse (E.Lifecycle_Cache_Unreadable, "not a saved session");
      end if;

      if not Trouble and then Version /= Session_Version then
         Refuse (E.Lifecycle_Cache_Unreadable, "another version");
      end if;

      if not Trouble and then Mark /= Fingerprint (Source) then
         Refuse (E.Lifecycle_Cache_Mismatched, "another model");
      end if;

      if not Trouble
        and then (Layers /= Interfaces.Unsigned_64 (Settings.Layers)
                  or else KV /= Interfaces.Unsigned_64 (Settings.KV_Heads)
                  or else Wide
                          /= Interfaces.Unsigned_64 (Settings.Head_Size)
                  or else Deep
                          /= Interfaces.Unsigned_64 (Settings.Value_Size))
      then
         Refuse (E.Lifecycle_Cache_Mismatched, "another shape");
      end if;

      if not Trouble
        and then Room /= Interfaces.Unsigned_64 (Item.Context)
      then
         Refuse (E.Lifecycle_Cache_Mismatched, "another context");
      end if;

      Narrow := Packed >= Narrow_Elements;

      if not Trouble
        and then Packed mod Narrow_Elements
                 /= Interfaces.Unsigned_64
                      (Cache_Precision'Pos (Item.Held)
                       + (if Item.Held_Values /= Item.Held
                          then 8 * Cache_Precision'Pos (Item.Held_Values)
                          else 0))
      then
         Refuse (E.Lifecycle_Cache_Mismatched, "another precision");
      end if;

      if not Trouble
        and then Filled > Interfaces.Unsigned_64 (Item.Context)
      then
         Refuse (E.Lifecycle_Cache_Unreadable, "more than the context");
      end if;

      if not Trouble then
         Held := Element_Count (Filled);
      end if;
   end;

   if not Trouble then
      for Index in 0 .. Natural (Held) - 1 loop
         declare
            Value : constant Interfaces.Unsigned_64 := Get;
         begin
            exit when Trouble;

            if Value >= Interfaces.Unsigned_64 (Settings.Vocabulary) then
               Refuse (E.Lifecycle_Cache_Unreadable, "token out of range");
               exit;
            end if;

            Item.History.all (Index) :=
              Model_Runner.Tokenizer.Token_Id (Value);
         end;
      end loop;
   end if;

   --  Where each layer's run begins, and the room the writer had. A
   --  session opened the same way cuts the cache the same way; one that
   --  did not cannot be told where these positions belong, and is
   --  refused rather than filled with them.
   if not Trouble then
      for Layer_Index in 0 .. Settings.Layers - 1 loop
         declare
            Begins : constant Interfaces.Unsigned_64 := Get;
            Room   : constant Interfaces.Unsigned_64 := Get;
         begin
            exit when Trouble;

            if Item.Cells = null
              or else Room
                      /= Interfaces.Unsigned_64 (Item.Cells.all (Layer_Index))
            then
               Refuse (E.Lifecycle_Cache_Mismatched, "another window");
               exit;
            end if;

            if Begins > Interfaces.Unsigned_64 (Held) then
               Refuse (E.Lifecycle_Cache_Unreadable, "a run past the end");
               exit;
            end if;

            Item.Origin.all (Layer_Index) := Element_Count (Begins);
         end;
      end loop;
   end if;

   if not Trouble then
      for Layer_Index in 0 .. Settings.Layers - 1 loop
         Get_Run
           (True, Keys_At (Item, Layer_Index),
            (if Linear (Settings, Layer_Index) then 0
             else (Held - Item.Origin.all (Layer_Index)) * KV_Width));
         exit when Trouble;
      end loop;
   end if;

   if not Trouble then
      for Layer_Index in 0 .. Settings.Layers - 1 loop
         Get_Run
           (False, Values_At (Item, Layer_Index),
            (if Linear (Settings, Layer_Index) then 0
             else (Held - Item.Origin.all (Layer_Index)) * V_Width));
         exit when Trouble;
      end loop;
   end if;

   --  And the linear layers' memories and states, whole, where the
   --  session has them; a snapshot without them is one of another
   --  model's shape and was refused above by its fingerprint.
   --  Into the slot the committed count will read, which is the
   --  newest the ring holds and the only one: what was before it
   --  belongs to a session that is not this one.
   if not Trouble and then Item.Conv_State /= null then
      Fetch_States (Item'Unchecked_Access);
   end if;

   if not Trouble and then Item.Conv_State /= null then
      declare
         Slot : constant Element_Count :=
           State_Slot (Item, Natural (Held));
         Every : constant Element_Count := Conv_Room (Source.Settings);
      begin
         for Value of Item.Conv_State.all
           (Slot * Every .. (Slot + 1) * Every - 1)
         loop
            declare
               Bits : constant Interfaces.Unsigned_32 := Get_Bits;
            begin
               exit when Trouble;
               Value := N.From_Bits (Bits);
            end;
         end loop;
      end;
   end if;
   if not Trouble and then Item.Delta_State /= null then
      declare
         Slot : constant Element_Count :=
           State_Slot (Item, Natural (Held));
         Every : constant Element_Count := State_Room (Source.Settings);
      begin
         for Value of Item.Delta_State.all
           (Slot * Every .. (Slot + 1) * Every - 1)
         loop
            declare
               Bits : constant Interfaces.Unsigned_32 := Get_Bits;
            begin
               exit when Trouble;
               Value := N.From_Bits (Bits);
            end;
         end loop;
      end;
   end if;
   Item.Kept_Newest := Natural (Held);

   --  What was adopted is the host's, whatever the device held.
   Item.State_On_Device := False;
   Item.Check_At := 0;

   --  What each position turns by, where the model has three parts
   --  and the snapshot carries them; a snapshot from before they were
   --  written leaves every position at its index, which is what it
   --  held. A mark past the context is a corrupt one.
   if not Trouble and then Item.Marks /= null then
      Item.Marked := 0;
      if From'Length >= At_Byte + B.Byte_Count (Held) * 4 * 8 then
         for Index in 0 .. Natural (Held) - 1 loop
            declare
               T : constant Interfaces.Unsigned_64 := Get;
               H : constant Interfaces.Unsigned_64 := Get;
               W : constant Interfaces.Unsigned_64 := Get;
               Next : constant Interfaces.Unsigned_64 := Get;
               Bound : constant Interfaces.Unsigned_64 :=
                 Interfaces.Unsigned_64 (Item.Context) * 4;
            begin
               exit when Trouble;
               if T > Bound or else H > Bound or else W > Bound
                 or else Next > Bound
               then
                  Refuse (E.Lifecycle_Cache_Unreadable, "a mark past the context");
                  exit;
               end if;
               Item.Marks.all (Index) :=
                 (Place => (T => Natural (T), H => Natural (H), W => Natural (W)),
                  Next => Natural (Next));
            end;
         end loop;
         if not Trouble then
            Item.Marked := Natural (Held);
         end if;
      end if;
   end if;

   if Trouble then
      --  Nothing half read is left where a conversation would be.
      Reset (Item);
      return;
   end if;

   Item.Committed := Natural (Held);
end Adopt;
