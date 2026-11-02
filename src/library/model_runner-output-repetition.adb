with Ada.Strings.Fixed;

package body Model_Runner.Output.Repetition is

   use Ada.Strings.Unbounded;

   --  Where a thought opens and closes: a think block, or harmony's
   --  analysis channel, which ends with its message or goes on to another
   --  channel.
   Openings : constant array (1 .. 2) of Unbounded_String :=
     [To_Unbounded_String ("<think>"), To_Unbounded_String ("<|channel|>analysis")];
   Closings : constant array (1 .. 4) of Unbounded_String :=
     [To_Unbounded_String ("</think>"), To_Unbounded_String ("<|end|>"),
      To_Unbounded_String ("<|channel|>final"), To_Unbounded_String ("<|channel|>commentary")];

   procedure Keep_To (Self : in out Watch; Item : Rule) is
   begin
      Self.Kept := Item;
   end Keep_To;

   procedure Start_Reply (Self : in out Watch; Inside : Boolean) is
   begin
      Self.Inside := Inside;
      Self.Line := Null_Unbounded_String;
      Self.Seen.Clear;
      Self.Round := False;
      Self.Again := Null_Unbounded_String;
      Self.Length := 0;
   end Start_Reply;

   function Looped (Self : Watch) return Boolean is (Self.Round);

   function Repeated (Self : Watch) return String is (To_String (Self.Again));

   --  A whole line: a marker in it moves the thought -- the last one it
   --  holds says where the line leaves it -- and a line with none, in a
   --  thought, is counted.
   procedure Take_Line (Self : in out Watch; Text : String) is
      Last_Open  : Natural := 0;
      Last_Shut  : Natural := 0;
   begin
      for Marker of Openings loop
         Last_Open := Natural'Max
           (Last_Open, Ada.Strings.Fixed.Index (Text, To_String (Marker), Ada.Strings.Backward));
      end loop;
      for Marker of Closings loop
         Last_Shut := Natural'Max
           (Last_Shut, Ada.Strings.Fixed.Index (Text, To_String (Marker), Ada.Strings.Backward));
      end loop;
      if Last_Open > 0 or else Last_Shut > 0 then
         Self.Inside := Last_Open > Last_Shut;
         Self.Seen.Clear;
         Self.Length := 0;
         return;
      end if;
      if not Self.Inside or else not Self.Kept.Watching then
         return;
      end if;
      Self.Length := Self.Length + Text'Length + 1;
      declare
         Kept : constant String := Ada.Strings.Fixed.Trim (Text, Ada.Strings.Both);
         Place : Counts.Cursor;
      begin
         if Kept'Length < Shortest then
            return;
         end if;
         Place := Self.Seen.Find (Kept);
         if Counts.Has_Element (Place) then
            Self.Seen.Replace_Element (Place, Counts.Element (Place) + 1);
            if not Self.Round and then Counts.Element (Place) >= Self.Kept.Limit
              and then Self.Length >= Self.Kept.Free_Length
            then
               Self.Round := True;
               Self.Again := To_Unbounded_String (Kept);
            end if;
         else
            Self.Seen.Insert (Kept, 1);
         end if;
      end;
   end Take_Line;

   overriding procedure Write
     (Self   : in out Watch;
      Item   : String;
      Closed : out Boolean)
   is
      From : Positive := Item'First;
   begin
      Emit (Self.Target, Item, Closed);
      for Index in Item'Range loop
         if Item (Index) = ASCII.LF then
            Append (Self.Line, Item (From .. Index - 1));
            Take_Line (Self, To_String (Self.Line));
            Self.Line := Null_Unbounded_String;
            From := Index + 1;
         end if;
      end loop;
      if From <= Item'Last then
         Append (Self.Line, Item (From .. Item'Last));
      end if;
      Closed := Closed or else Self.Round;
   end Write;

   overriding procedure Flush (Self : in out Watch; Closed : out Boolean) is
   begin
      Flush_Sink (Self.Target, Closed);
      Closed := Closed or else Self.Round;
   end Flush;

   overriding function Is_Closed (Self : Watch) return Boolean
   is (Self.Round
       or else (Model_Runner.Output."/=" (Self.Target, null) and then Self.Target.Is_Closed));

end Model_Runner.Output.Repetition;
