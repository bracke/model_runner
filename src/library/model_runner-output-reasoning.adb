package body Model_Runner.Output.Reasoning is

   procedure Show (Self : in out Filter; Text : String) is
      Closed : Boolean;
   begin
      if Text'Length > 0 and then not Self.Shut then
         Emit (Self.Target, Text, Closed);
         Self.Shut := Self.Shut or else Closed;
         Self.Shown := True;
      end if;
   end Show;

   --  One character the reply holds, outside any marker being matched.
   procedure Put (Self : in out Filter; C : Character) is
   begin
      if Self.Hidden then
         return;
      end if;
      if Self.Leading then
         if C in ' ' | ASCII.LF | ASCII.CR | ASCII.HT then
            return;
         end if;
         Self.Leading := False;
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
      Self.Hidden := Inside;
      Self.Leading := False;
      Self.Used := 0;
      Self.Shown := False;
   end Start_Reply;

   function Showed_Nothing (Self : Filter) return Boolean is (not Self.Shown);

   overriding procedure Write
     (Self   : in out Filter;
      Item   : String;
      Closed : out Boolean) is
   begin
      for C of Item loop
         Take (Self, C);
      end loop;
      Closed := Self.Shut;
   end Write;

   overriding procedure Flush (Self : in out Filter; Closed : out Boolean) is
   begin
      Flush_Sink (Self.Target, Closed);
      Self.Shut := Self.Shut or else Closed;
      Closed := Self.Shut;
   end Flush;

   overriding function Is_Closed (Self : Filter) return Boolean
   is (Self.Shut
       or else (Self.Target /= null and then Self.Target.Is_Closed));

end Model_Runner.Output.Reasoning;
