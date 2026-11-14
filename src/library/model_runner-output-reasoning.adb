package body Model_Runner.Output.Reasoning is

   --  What is held to show, written now.
   procedure Release (Self : in out Filter) is
      use Ada.Strings.Unbounded;
      Closed : Boolean;
   begin
      if Length (Self.Pending) > 0 then
         if not Self.Shut then
            Emit (Self.Target, To_String (Self.Pending), Closed);
            Self.Shut := Self.Shut or else Closed;
         end if;
         Self.Pending := Null_Unbounded_String;
      end if;
   end Release;

   procedure Show (Self : in out Filter; Text : String) is
   begin
      if Text'Length > 0 and then not Self.Shut then
         Ada.Strings.Unbounded.Append (Self.Pending, Text);
         Self.Shown := True;
         Self.Last := Text (Text'Last);
      end if;
   end Show;

   --  The reasoning's style ended, where it was begun.
   procedure Unstyle (Self : in out Filter) is
   begin
      if Self.Styled then
         Release (Self);
         Style (Self.Target, Plain);
         Self.Styled := False;
      end if;
   end Unstyle;

   --  One character the reply holds, outside any marker being matched.
   procedure Put (Self : in out Filter; C : Character) is
   begin
      if Self.Hidden then
         if not Self.Showing_Block then
            return;
         end if;
         --  The block shown from its first text: the space after its
         --  marker is none of it.
         if Self.Block_Leading then
            if C in ' ' | ASCII.LF | ASCII.CR | ASCII.HT then
               return;
            end if;
            Self.Block_Leading := False;
         end if;
         if not Self.Styled then
            Release (Self);
            Style (Self.Target, Output.Thought);
            Self.Styled := True;
         end if;
         Self.Thought := True;
         Show (Self, [1 => C]);
         return;
      end if;
      if Self.Leading then
         if C in ' ' | ASCII.LF | ASCII.CR | ASCII.HT then
            return;
         end if;
         Self.Leading := False;
         --  One blank line between reasoning shown and the answer.
         if Self.Thought then
            Show (Self, (if Self.Last = ASCII.LF then [1 => ASCII.LF] else ASCII.LF & ASCII.LF));
            Self.Thought := False;
         end if;
      end if;
      Show (Self, [1 => C]);
   end Put;

   procedure Take (Self : in out Filter; C : Character) is
      Marker : constant String :=
        (if Self.Hidden then Closing else Opening);
   begin
      Self.Used := Self.Used + 1;
      Self.Held (Self.Used) := C;

      if Self.Held (1 .. Self.Used) = Marker (Marker'First .. Marker'First + Self.Used - 1)
      then
         if Self.Used = Marker'Length then
            Self.Used := 0;
            Self.Hidden := not Self.Hidden;
            Self.Leading := not Self.Hidden;
            Self.Block_Leading := Self.Hidden;
            if not Self.Hidden then
               Unstyle (Self);
            end if;
         end if;
         return;
      end if;

      --  Not the marker after all: its first character is text, and the
      --  rest is read again, since a marker may begin inside it.
      declare
         Rest : constant String := Self.Held (2 .. Self.Used);
      begin
         Put (Self, Self.Held (1));
         Self.Used := 0;
         for R of Rest loop
            Take (Self, R);
         end loop;
      end;
   end Take;

   procedure Start_Reply (Self : in out Filter; Inside : Boolean) is
   begin
      Unstyle (Self);
      Self.Hidden := Inside;
      Self.Leading := False;
      Self.Block_Leading := Inside;
      Self.Thought := False;
      Self.Last := ASCII.LF;
      Self.Used := 0;
      Self.Shown := False;
   end Start_Reply;

   function Showed_Nothing (Self : Filter) return Boolean is (not Self.Shown);

   procedure Show_Reasoning (Self : in out Filter; On : Boolean) is
   begin
      Self.Showing_Block := On;
   end Show_Reasoning;

   overriding procedure Write
     (Self   : in out Filter;
      Item   : String;
      Closed : out Boolean) is
   begin
      for C of Item loop
         Take (Self, C);
      end loop;
      Release (Self);
      Closed := Self.Shut;
   end Write;

   overriding procedure Flush (Self : in out Filter; Closed : out Boolean) is
   begin
      --  The reply's end held as a possible marker -- a last <, <t, </th --
      --  is text after all, shown where text is.
      for Index in 1 .. Self.Used loop
         Put (Self, Self.Held (Index));
      end loop;
      Self.Used := 0;
      --  Nothing after this is left in the reasoning's style: a reply
      --  stopped inside the block, or a pause in it, takes it up again
      --  with its next text.
      Release (Self);
      Unstyle (Self);
      Flush_Sink (Self.Target, Closed);
      Self.Shut := Self.Shut or else Closed;
      Closed := Self.Shut;
   end Flush;

   overriding function Is_Closed (Self : Filter) return Boolean
   is (Self.Shut
       or else (Self.Target /= null and then Self.Target.Is_Closed));

end Model_Runner.Output.Reasoning;
