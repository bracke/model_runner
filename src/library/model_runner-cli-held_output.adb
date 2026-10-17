with Model_Runner.Framework;
with Model_Runner.Framework.Execution;
with Ada.Strings.Fixed;

package body Model_Runner.CLI.Held_Output is

   --  A reasoning block's tag at a line's start opens no call: what was
   --  held is written once it is plainly one, and what follows it read
   --  afresh. Held whole, a think block before a call was dropped with it.
   procedure Release_Thought_Tag
     (Self   : in out Watching_Sink;
      Closed : in out Boolean)
   is
      Held : constant String := To_String (Self.Held);

      function Opens (Tag : String) return Boolean is
        (Held'Length >= Tag'Length
         and then Held (Held'First .. Held'First + Tag'Length - 1) = Tag);

      procedure Release (Tag : String) is
      begin
         Self.Holding := False;
         Self.Held := Null_Unbounded_String;
         Pres.Standard_Output_Sink (Self).Write (Tag, Closed);
         Self.At_Line_Start := False;
         if Held'Length > Tag'Length then
            Write (Self, Held (Held'First + Tag'Length .. Held'Last), Closed);
         end if;
      end Release;
   begin
      if Opens ("<think>") then
         Release ("<think>");
      elsif Opens ("</think>") then
         Release ("</think>");
      end if;
   end Release_Thought_Tag;

   overriding procedure Write
     (Self   : in out Watching_Sink;
      Item   : String;
      Closed : out Boolean)
   is
      use type Model_Runner.Cancellation.Token_Reference;
      From : Positive := Item'First;
   begin
      Closed := False;
      if Self.Quiet then
         if Self.Stop /= null and then Model_Runner.Framework.Execution.Work_Withdrawn then
            Self.Stop.Request;
         end if;
         return;
      end if;
      if Self.Holding then
         Append (Self.Held, Item);
         Release_Thought_Tag (Self, Closed);
      else
         for Index in Item'Range loop
            if Self.At_Line_Start and then Item (Index) in '{' | '`' | '<' then
               if Index > From then
                  Pres.Standard_Output_Sink (Self).Write (Item (From .. Index - 1), Closed);
               end if;
               Self.Holding := True;
               Self.Held := To_Unbounded_String (Item (Index .. Item'Last));
               --  A reasoning tag after all: it and what followed it were
               --  written by the release, so none of this piece is left.
               Release_Thought_Tag (Self, Closed);
               From := Item'Last + 1;
               exit;
            end if;
            Self.At_Line_Start :=
              Item (Index) = ASCII.LF or else (Self.At_Line_Start and then Item (Index) in ' ' | ASCII.HT);
         end loop;
         if not Self.Holding and then From <= Item'Last then
            Pres.Standard_Output_Sink (Self).Write (Item (From .. Item'Last), Closed);
         end if;
      end if;
      if Self.Stop /= null and then Model_Runner.Framework.Execution.Work_Withdrawn then
         Self.Stop.Request;
      end if;
   end Write;

   procedure Drop_Held (Self : in out Watching_Sink'Class) is
   begin
      Self.Held := Null_Unbounded_String;
      Self.Holding := False;
      Self.At_Line_Start := True;
   end Drop_Held;

   procedure Release_Held (Self : in out Watching_Sink'Class) is
      Closed : Boolean;
   begin
      if Self.Holding and then Self.Held /= Null_Unbounded_String then
         --  Ended on its own line, as a reply streamed whole would be
         --  before what the harness says next; a line said over and over
         --  -- a model gone round -- shown a few times and then counted.
         declare
            Shown   : Unbounded_String;
            Last    : Unbounded_String;
            Same     : Natural := 0;
            Skipped  : Natural := 0;
            In_Fence : Boolean := False;

            procedure Flush_Skipped is
            begin
               if Skipped > 0 then
                  Append (Shown, "... the same line" & Natural'Image (Skipped) & " times more" & ASCII.LF);
                  Skipped := 0;
               end if;
            end Flush_Skipped;
         begin
            for Said of Model_Runner.Framework.Lines_Of (To_String (Self.Held)) loop
               declare
                  --  The model's line as the screen shows it, its controls
                  --  written out, before the colour is put on: coloured
                  --  first, the colour's own sequences were written out
                  --  with them.
                  Raw : constant String :=
                    Pres.Shown (Pres.Standard_Output_Sink (Self), Said);
                  --  JSON in a fence, or an answer that is JSON whole, coloured
                  --  as JSON where colour shows.
                  Fence : constant Boolean :=
                    Ada.Strings.Fixed.Index (Ada.Strings.Fixed.Trim (Raw, Ada.Strings.Left), "```") = 1;
                  Line  : constant String :=
                    (if not Self.Styled then Raw
                     elsif Fence then Raw
                     elsif In_Fence or else Pres.Looks_Like_JSON (To_String (Self.Held))
                     then Pres.JSON_Coloured (Raw)
                     else Raw);
               begin
                  if Fence then
                     In_Fence := not In_Fence;
                  end if;
                  if Raw = To_String (Last) then
                     Same := Same + 1;
                  else
                     Flush_Skipped;
                     Same := 0;
                     Last := To_Unbounded_String (Raw);
                  end if;
                  if Same < 3 then
                     Append (Shown, Line & ASCII.LF);
                  else
                     Skipped := Skipped + 1;
                  end if;
               end;
            end loop;
            Flush_Skipped;
            Pres.Standard_Output_Sink (Self).Write_Shown (To_String (Shown), Closed);
         end;
      end if;
      Drop_Held (Self);
   end Release_Held;

end Model_Runner.CLI.Held_Output;
